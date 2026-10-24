package pushv2

// wake.go is the Waker (spec 02 §12.1, §12.4, §12.5): who is woken, through a
// bounded queue that never blocks a request, under the throttle, and what
// happens to a token after APNs answers.

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Reason says why a device is woken. It is internal only: every reason sends
// the same bytes (spec 02 §12.5), so nothing on the wire tells a mail wake
// from a security one.
type Reason uint8

// The reasons (spec 02 §12.1).
const (
	ReasonMail Reason = iota + 1
	ReasonSync
	ReasonSecurity
	ReasonNudge
	ReasonAccountGone
)

func (r Reason) String() string {
	switch r {
	case ReasonMail:
		return "mail"
	case ReasonSync:
		return "sync"
	case ReasonSecurity:
		return "security"
	case ReasonNudge:
		return "nudge"
	case ReasonAccountGone:
		return "account_gone"
	}
	return "unknown"
}

// Target is one APNs token and the gateway it belongs to.
type Target struct {
	TokenHex    string
	Environment string
}

// Waker wakes devices. Its calls never block a request.
type Waker interface {
	WakeWriter(ctx context.Context, userID uuid.UUID, writerID string, r Reason)
	WakeOthers(ctx context.Context, userID uuid.UUID, exceptWriterID string, r Reason) // "" = all
	WakeTokens(ctx context.Context, tokens []Target, r Reason)                         // pre-collected
}

// NopWaker is the Waker while apns.enabled is false (spec 02 §18.2: the token
// routes stay mounted, nothing is sent).
type NopWaker struct{}

func (NopWaker) WakeWriter(context.Context, uuid.UUID, string, Reason) {}
func (NopWaker) WakeOthers(context.Context, uuid.UUID, string, Reason) {}
func (NopWaker) WakeTokens(context.Context, []Target, Reason)          {}

// Sender is what the dispatcher sends through: *Client in production, a fake
// in tests.
type Sender interface {
	Send(ctx context.Context, t Target) Result
}

// Queue sizing (spec 02 §12.1).
const (
	queueCapacity = 1024
	senderCount   = 4
	configPause   = 5 * time.Minute
	tickEvery     = time.Second
)

type job struct {
	user    uuid.UUID
	writer  string
	others  bool
	tokens  []Target
	r       Reason
	resolve bool // false: tokens are already final (a trailing wake)
}

// Stats are the dispatcher's counters (spec 02 §20.1's apns_* metrics).
type Stats struct {
	Sent, Gone, Cooled, ConfigErrors, Transient atomic.Int64
	Dropped                                     [ReasonAccountGone + 1]atomic.Int64
}

// Dispatcher is the production Waker.
type Dispatcher struct {
	Pool   *pgxpool.Pool
	Sender Sender
	Now    func() time.Time
	Stats  Stats

	queue    chan job
	mu       sync.Mutex // guards th, pause and envPause
	th       *throttle
	pause    time.Time
	envPause map[string]time.Time
	wg       sync.WaitGroup
}

// NewDispatcher builds a dispatcher; call Start to run it.
func NewDispatcher(pool *pgxpool.Pool, s Sender) *Dispatcher {
	return &Dispatcher{Pool: pool, Sender: s, queue: make(chan job, queueCapacity), th: newThrottle()}
}

func (d *Dispatcher) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

// Start runs the senders and the trailing-edge ticker until ctx is done; the
// returned channel closes when every goroutine has stopped.
func (d *Dispatcher) Start(ctx context.Context) <-chan struct{} {
	for range senderCount {
		d.wg.Add(1)
		go func() {
			defer d.wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				case j := <-d.queue:
					d.run(context.WithoutCancel(ctx), j)
				}
			}
		}()
	}
	d.wg.Add(1)
	go func() {
		defer d.wg.Done()
		tick := time.NewTicker(tickEvery)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				d.Flush(context.WithoutCancel(ctx))
			}
		}
	}()
	done := make(chan struct{})
	go func() { d.wg.Wait(); close(done) }()
	return done
}

func (d *Dispatcher) enqueue(j job) bool {
	select {
	case d.queue <- j:
		return true
	default:
		d.Stats.Dropped[j.r].Add(1)
		slog.Warn("pushv2: wake queue full, wake dropped", "reason", j.r.String())
		return false
	}
}

// WakeWriter wakes one writer's device.
func (d *Dispatcher) WakeWriter(ctx context.Context, userID uuid.UUID, writerID string, r Reason) {
	d.TryWakeWriter(ctx, userID, writerID, r)
}

// TryWakeWriter is WakeWriter that reports whether the wake was queued.
func (d *Dispatcher) TryWakeWriter(_ context.Context, userID uuid.UUID, writerID string, r Reason) bool {
	if writerID == "" {
		return false
	}
	return d.enqueue(job{user: userID, writer: writerID, r: r, resolve: true})
}

// WakeOthers wakes every device of userID except exceptWriterID ("" = all).
func (d *Dispatcher) WakeOthers(_ context.Context, userID uuid.UUID, exceptWriterID string, r Reason) {
	d.enqueue(job{user: userID, writer: exceptWriterID, others: true, r: r, resolve: true})
}

// WakeTokens wakes tokens collected before their rows went away (logout-all,
// revoke, purge).
func (d *Dispatcher) WakeTokens(_ context.Context, tokens []Target, r Reason) {
	if len(tokens) == 0 {
		return
	}
	d.enqueue(job{tokens: append([]Target(nil), tokens...), r: r})
}

// Notify implements Notifier: a sync wake to every device of the account.
func (d *Dispatcher) Notify(ctx context.Context, userID uuid.UUID) error {
	d.WakeOthers(ctx, userID, "", ReasonSync)
	return nil
}

// targets resolves a job's tokens from apns_tokens.
func (d *Dispatcher) targets(ctx context.Context, j job) ([]Target, error) {
	switch {
	case !j.resolve:
		return j.tokens, nil
	case j.others:
		return CollectTokens(ctx, d.Pool, j.user, j.writer)
	default:
		return WriterTokens(ctx, d.Pool, j.user, j.writer)
	}
}

func (d *Dispatcher) run(ctx context.Context, j job) {
	ts, err := d.targets(ctx, j)
	if err != nil {
		slog.Warn("pushv2: resolve wake targets", "reason", j.r.String(), "err", err.Error())
		return
	}
	for _, t := range ts {
		d.mu.Lock()
		paused := d.pausedFor(t)
		var dec decision
		if !paused {
			dec = d.th.admit(t, j.r, d.now(), j.user)
		}
		d.mu.Unlock()
		if paused {
			d.Stats.Dropped[j.r].Add(1)
			continue
		}
		switch dec {
		case sendNow:
			d.send(ctx, t)
		case dropCap, dropCool:
			d.Stats.Dropped[j.r].Add(1)
		}
	}
}

// Flush sends every trailing wake whose window has closed. The ticker calls it
// every second; tests call it with a fake clock. A trailing wake goes out only
// if the token's row still exists for the account it was owed to: a token
// revoked, logged out or moved to another account since is not woken.
func (d *Dispatcher) Flush(ctx context.Context) {
	d.mu.Lock()
	owed, dropped := d.th.due(d.now())
	paused := make([]bool, len(owed))
	for i, w := range owed {
		paused[i] = d.pausedFor(w.t)
	}
	d.mu.Unlock()
	for _, r := range dropped {
		d.Stats.Dropped[r].Add(1)
	}
	for i, w := range owed {
		if paused[i] || !d.stillRegistered(ctx, w) {
			d.Stats.Dropped[w.r].Add(1)
			continue
		}
		d.send(ctx, w.t)
	}
}

func (d *Dispatcher) pausedFor(t Target) bool {
	now := d.now()
	return now.Before(d.pause) || now.Before(d.envPause[t.Environment])
}

func (d *Dispatcher) stillRegistered(ctx context.Context, w trailing) bool {
	if d.Pool == nil {
		return true
	}
	var owner *uuid.UUID
	if w.owner != uuid.Nil {
		owner = &w.owner
	}
	var ok bool
	err := d.Pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM apns_tokens
		  WHERE token_hex = $1 AND environment = $2 AND ($3::uuid IS NULL OR user_id = $3))`,
		w.t.TokenHex, w.t.Environment, owner).Scan(&ok)
	if err != nil {
		slog.Warn("pushv2: check trailing wake token", "reason", w.r.String(), "err", err.Error())
		return false
	}
	return ok
}

func (d *Dispatcher) send(ctx context.Context, t Target) {
	if d.Sender == nil {
		return
	}
	res := d.Sender.Send(ctx, t)
	switch res {
	case ResultSent:
		d.Stats.Sent.Add(1)
	case ResultGone:
		d.Stats.Gone.Add(1)
		d.mu.Lock()
		d.th.forget(t)
		d.mu.Unlock()
		if d.Pool != nil {
			if _, err := d.Pool.Exec(ctx, `DELETE FROM apns_tokens WHERE token_hex = $1`, t.TokenHex); err != nil &&
				!errors.Is(err, context.Canceled) {
				slog.Warn("pushv2: delete unregistered token", "err", err.Error())
			}
		}
	case ResultCooldown:
		d.Stats.Cooled.Add(1)
		d.mu.Lock()
		d.th.cool(t, d.now())
		d.mu.Unlock()
	case ResultConfig:
		d.Stats.ConfigErrors.Add(1)
		d.mu.Lock()
		d.pause = d.now().Add(configPause)
		d.mu.Unlock()
		slog.Error("pushv2: APNs refused the provider token or topic; sending paused for 5 minutes")
	case ResultEnvironment:
		d.Stats.ConfigErrors.Add(1)
		d.mu.Lock()
		if d.envPause == nil {
			d.envPause = map[string]time.Time{}
		}
		d.envPause[t.Environment] = d.now().Add(configPause)
		d.mu.Unlock()
		slog.Error("pushv2: APNs refused the provider token for one environment; that environment is paused for 5 minutes",
			"environment", t.Environment)
	default:
		d.Stats.Transient.Add(1)
		slog.Warn("pushv2: APNs send failed", "result", res.String())
	}
}

// Querier is what the token readers need: a pool or a transaction.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// CollectTokens reads every token of userID (except exceptWriterID, "" = none
// excepted) through q, for a caller about to delete the rows that hold them
// (logout-all, writer revoke, purge; spec 02 §12.5).
func CollectTokens(ctx context.Context, q Querier, userID uuid.UUID, exceptWriterID string) ([]Target, error) {
	rows, err := q.Query(ctx,
		`SELECT token_hex, environment FROM apns_tokens WHERE user_id = $1 AND writer_id <> $2`, userID, exceptWriterID)
	if err != nil {
		return nil, err
	}
	return collectTargets(rows)
}

// WriterTokens reads one writer's tokens, for a revoke: the revoked writer is
// woken too (spec 02 §12.5, §9.5), and its token row goes with it.
func WriterTokens(ctx context.Context, q Querier, userID uuid.UUID, writerID string) ([]Target, error) {
	rows, err := q.Query(ctx,
		`SELECT token_hex, environment FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, userID, writerID)
	if err != nil {
		return nil, err
	}
	return collectTargets(rows)
}

func collectTargets(rows pgx.Rows) ([]Target, error) {
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Target, error) {
		var t Target
		err := r.Scan(&t.TokenHex, &t.Environment)
		return t, err
	})
}
