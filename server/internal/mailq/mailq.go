// Package mailq is the email outbox and the email log (spec 07 §2.8, §6): one
// mail_log row per email, enqueued inside the transaction that causes it,
// rendered at send time by a per-kind Renderer that mints whatever secret the
// email carries (and stores only its hash), sent by a worker in `serve`, and
// kept for 30 days without a subject, a body, a link or a secret.
//
// This is the only package that calls mail.Sender.Send (spec 07 F7-5).
package mailq

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"slices"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// Lane orders and rate-limits rows (spec 07 §6.5).
type Lane string

// The lanes.
const (
	LaneTransactional Lane = "transactional"
	LaneWaitlist      Lane = "waitlist"
	LaneBulk          Lane = "bulk"
)

// Status is a row's state (spec 07 §3.5).
type Status string

// The statuses.
const (
	StatusQueued     Status = "queued"
	StatusSending    Status = "sending"
	StatusSent       Status = "sent"
	StatusFailed     Status = "failed"
	StatusBounced    Status = "bounced"
	StatusSuppressed Status = "suppressed"
)

// Tagger computes email_tag (spec 01 §4.11) under the server's auth key.
type Tagger interface {
	EmailTag(emailNorm string) []byte
}

// paramsAllowed is spec 07 §6.3's per-kind allow-list. An unknown key is a
// programming error and is refused at enqueue.
var paramsAllowed = map[string][]string{
	"waitlist":             nil,
	"waitlist_already":     {"variant"},
	"waitlist_has_account": nil,
	"invite":               nil,
	"bank_supported":       {"audience"},
	"code":                 {"purpose"},
	"reset_code":           {"purpose"},
	"recovery_code":        {"purpose"},
	"alert":                {"event_at"},
	"deleted":              {"deleted_at"},
	"test":                 nil,
}

// retryWindow is how long a transient failure may keep retrying (spec 07
// §6.2): a code is dead after 10 minutes, anything else gets a day.
func retryWindow(kind string) time.Duration {
	switch kind {
	case "code", "reset_code", "recovery_code":
		return 10 * time.Minute
	}
	return 24 * time.Hour
}

var backoff = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour, 6 * time.Hour, 12 * time.Hour}

// Lease and send bounds.
const (
	leaseFor     = 2 * time.Minute
	sendTimeout  = 20 * time.Second
	renderFor    = 30 * time.Second
	pollEvery    = 30 * time.Second
	maxAttempts  = 10
	hintMax      = 80
	notifyChan   = "hasala_mail"
	errorMaxLen  = 200
	workerCount  = 2
	tagBatchSize = 50
)

// Enqueue describes one email to queue.
type Enqueue struct {
	Kind, Subkind string
	Lane          Lane
	To            string // email_norm
	Tag           []byte // email_tag(To); computed by the queue's Tagger when nil
	UserID        *uuid.UUID
	EntryID       *uuid.UUID
	InviteID      *uuid.UUID
	BankSlug      *string
	Params        map[string]any
}

// Row is a leased row, as a Renderer sees it.
type Row struct {
	ID           int64
	Kind         string
	Subkind      string
	Lane         Lane
	Recipient    string
	RecipientTag []byte
	UserID       *uuid.UUID
	EntryID      *uuid.UUID
	InviteID     *uuid.UUID
	BankSlug     *string
	Params       map[string]any
	Attempts     int
	CreatedAt    time.Time
}

// Renderer builds a row's message at send time, inside its own transaction,
// minting any secret the kind carries and storing only its hash.
type Renderer interface {
	Render(ctx context.Context, tx pgx.Tx, row Row) (mail.Message, error)
}

// RenderFunc adapts a function to Renderer.
type RenderFunc func(ctx context.Context, tx pgx.Tx, row Row) (mail.Message, error)

// Render calls f.
func (f RenderFunc) Render(ctx context.Context, tx pgx.Tx, row Row) (mail.Message, error) {
	return f(ctx, tx, row)
}

// ErrNoRenderer is a row whose kind has no registered renderer.
var ErrNoRenderer = errors.New("mailq: no renderer for this kind")

var errRenderRetry = errors.New("mailq: render failed; retrying")

func transientRender(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) ||
		errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || pgconn.Timeout(err) || pgconn.SafeToRetry(err) {
		return true
	}
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		switch pe.Code[:2] {
		case "08", "40", "53", "57", "58":
			return true
		}
		return false
	}
	var ce *pgconn.ConnectError
	var ne net.Error
	return errors.As(err, &ce) || errors.As(err, &ne)
}

// Queue is the outbox. Build it with New.
type Queue struct {
	Pool   *pgxpool.Pool
	Sender mail.Sender
	Tagger Tagger
	// Rates are rows per hour per lane; a missing or zero entry is uncapped
	// (the transactional lane).
	Rates     map[Lane]int
	Retention time.Duration
	// Bounced, when set, runs in the finalizing transaction of a bounced row
	// that names an account (spec 02 §14.7: the account's address is marked
	// undeliverable). It makes no network call.
	Bounced func(ctx context.Context, tx pgx.Tx, row Row) error
	Unsent  func(ctx context.Context, tx pgx.Tx, row Row) (func(), error)

	renderers map[string]Renderer
	stopped   atomic.Bool
	wake      chan struct{}
}

// New builds a queue with spec 07 §14.1's default rates and retention.
func New(pool *pgxpool.Pool, s mail.Sender, tagger Tagger) *Queue {
	return &Queue{Pool: pool, Sender: s, Tagger: tagger,
		Rates:     map[Lane]int{LaneWaitlist: 60, LaneBulk: 120},
		Retention: 30 * 24 * time.Hour,
		renderers: map[string]Renderer{}, wake: make(chan struct{}, 1)}
}

// Register installs kind's renderer.
func (q *Queue) Register(kind string, r Renderer) {
	if q.renderers == nil {
		q.renderers = map[string]Renderer{}
	}
	q.renderers[kind] = r
}

// Stopped reports whether an auth failure stopped the worker (until restart).
func (q *Queue) Stopped() bool { return q.stopped.Load() }

// Hint is spec 07 §4.5's masked address: m•••@example.com.
func Hint(addr string) string {
	at := strings.LastIndexByte(addr, '@')
	if at < 0 {
		return "•••"
	}
	local, domain := addr[:at], addr[at+1:]
	prefix := "•••@"
	if r, n := utf8.DecodeRuneInString(local); n > 0 && n < len(local) && r != utf8.RuneError {
		prefix = local[:n] + prefix
	}
	if room := hintMax - utf8.RuneCountInString(prefix); utf8.RuneCountInString(domain) > room {
		d := []rune(domain)
		domain = "…" + string(d[len(d)-(room-1):])
	}
	return prefix + domain
}

func checkParams(kind string, p map[string]any) error {
	allowed, ok := paramsAllowed[kind]
	if !ok {
		return fmt.Errorf("mailq: unknown kind %q", kind)
	}
	for k := range p {
		if !slices.Contains(allowed, k) {
			return fmt.Errorf("mailq: param %q is not allowed for kind %q", k, kind)
		}
	}
	return nil
}

func (q *Queue) prepare(e *Enqueue) (tag, params []byte, err error) {
	if err := checkParams(e.Kind, e.Params); err != nil {
		return nil, nil, err
	}
	if e.Lane == "" {
		e.Lane = LaneTransactional
	}
	tag = e.Tag
	if tag == nil && q.Tagger != nil {
		tag = q.Tagger.EmailTag(e.To)
	}
	p := e.Params
	if p == nil {
		p = map[string]any{}
	}
	params, err = json.Marshal(p)
	return tag, params, err
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// EnqueueTx writes a queued row inside the caller's transaction and notifies
// the worker at commit.
func (q *Queue) EnqueueTx(ctx context.Context, tx pgx.Tx, e Enqueue) (int64, error) {
	tag, params, err := q.prepare(&e)
	if err != nil {
		return 0, err
	}
	var id int64
	err = tx.QueryRow(ctx,
		`INSERT INTO mail_log (kind, subkind, lane, recipient, recipient_tag, recipient_hint, user_id,
		                       waitlist_entry_id, invite_id, bank_slug, params, status, next_attempt_at, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'queued', now(), now()) RETURNING id`,
		e.Kind, nilIfEmpty(e.Subkind), string(e.Lane), e.To, tag, Hint(e.To), e.UserID, e.EntryID, e.InviteID,
		e.BankSlug, params).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("mailq: enqueue %s: %w", e.Kind, err)
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify($1, '')`, notifyChan); err != nil {
		return 0, fmt.Errorf("mailq: notify: %w", err)
	}
	return id, nil
}

// SendNow sends an email whose secret the caller minted and which must never
// touch the database (spec 02's codes): the row is written as sending, render
// is called, the message is sent and the row finalized. One attempt.
func (q *Queue) SendNow(ctx context.Context, e Enqueue, render func() (mail.Message, error)) error {
	tag, params, err := q.prepare(&e)
	if err != nil {
		return err
	}
	if len(tag) != 32 {
		return errors.New("mailq: SendNow needs the recipient's email_tag")
	}
	var (
		id    int64
		lease time.Time
	)
	err = q.Pool.QueryRow(ctx,
		`INSERT INTO mail_log (kind, subkind, lane, recipient, recipient_tag, recipient_hint, user_id,
		                       waitlist_entry_id, invite_id, bank_slug, params, status, attempts, lease_until, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'sending', 1, now() + interval '2 minutes', now())
		 RETURNING id, lease_until`,
		e.Kind, nilIfEmpty(e.Subkind), string(e.Lane), e.To, tag, Hint(e.To), e.UserID, e.EntryID, e.InviteID,
		e.BankSlug, params).Scan(&id, &lease)
	if err != nil {
		return fmt.Errorf("mailq: record %s: %w", e.Kind, err)
	}
	row := &Row{ID: id, Kind: e.Kind, Subkind: e.Subkind, Lane: e.Lane, Recipient: e.To, RecipientTag: tag,
		UserID: e.UserID, EntryID: e.EntryID, InviteID: e.InviteID, BankSlug: e.BankSlug, Params: e.Params, Attempts: 1}
	if q.Stopped() || q.Sender == nil {
		q.finalize(ctx, row, lease, "", errors.New("mailq: sending is stopped"), true)
		return errors.New("mailq: sending is stopped")
	}
	msg, err := render()
	if err != nil {
		q.finalize(ctx, row, lease, "", fmt.Errorf("%w: render", mail.ErrPermanent), true)
		return err
	}
	msg.To = e.To
	sctx, cancel := context.WithTimeout(ctx, sendTimeout)
	pid, sendErr := q.Sender.Send(sctx, msg)
	cancel()
	msg = mail.Message{} // the rendered secret is never kept
	q.finalize(ctx, row, lease, pid, sendErr, true)
	return sendErr
}

// Kick wakes an idle worker (EnqueueTx's NOTIFY does the same across
// processes).
func (q *Queue) Kick() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

// Run starts the listener and the workers until ctx is done.
func (q *Queue) Run(ctx context.Context) <-chan struct{} {
	done := make(chan struct{})
	finished := make(chan struct{}, workerCount+1)
	go func() {
		defer func() { finished <- struct{}{} }()
		q.listen(ctx)
	}()
	for range workerCount {
		go func() {
			defer func() { finished <- struct{}{} }()
			tick := time.NewTicker(pollEvery)
			defer tick.Stop()
			for {
				if _, err := q.Drain(context.WithoutCancel(ctx)); err != nil {
					slog.Warn("mailq: worker", "err", err.Error())
				}
				select {
				case <-ctx.Done():
					return
				case <-tick.C:
				case <-q.wake:
				}
			}
		}()
	}
	go func() {
		for range workerCount + 1 {
			<-finished
		}
		close(done)
	}()
	return done
}

// listen holds one connection on LISTEN hasala_mail and kicks the workers on
// every notification; it reconnects after a failure.
func (q *Queue) listen(ctx context.Context) {
	for ctx.Err() == nil {
		conn, err := q.Pool.Acquire(ctx)
		if err != nil {
			sleep(ctx, 5*time.Second)
			continue
		}
		if _, err := conn.Exec(ctx, "LISTEN "+notifyChan); err != nil {
			conn.Release()
			sleep(ctx, 5*time.Second)
			continue
		}
		for ctx.Err() == nil {
			if _, err := conn.Conn().WaitForNotification(ctx); err != nil {
				break
			}
			q.Kick()
			q.Kick()
		}
		// The connection may be mid-wait; never hand it back to the pool.
		_ = conn.Conn().Close(context.WithoutCancel(ctx))
		conn.Release()
	}
}

func sleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

// Drain sends due rows until none is left (or the worker is stopped). It
// returns how many rows it processed.
func (q *Queue) Drain(ctx context.Context) (int, error) {
	n := 0
	for !q.Stopped() {
		did, err := q.ProcessOne(ctx)
		if err != nil {
			return n, err
		}
		if !did {
			return n, nil
		}
		n++
	}
	return n, nil
}

// fillTags computes the missing recipient tags of due queued rows (rows the
// console or the CLI wrote, which cannot compute one), and for a CLI invite
// the invite's own tag (spec 07 §6.2 "Tags first").
func (q *Queue) fillTags(ctx context.Context) error {
	if q.Tagger == nil {
		return nil
	}
	tx, err := pgtx.BeginReadCommitted(ctx, q.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	rows, err := tx.Query(ctx,
		`SELECT id, recipient, invite_id FROM mail_log
		  WHERE status = 'queued' AND recipient_tag IS NULL AND recipient IS NOT NULL
		  ORDER BY id FOR UPDATE SKIP LOCKED LIMIT $1`, tagBatchSize)
	if err != nil {
		return err
	}
	type untagged struct {
		id     int64
		to     string
		invite *uuid.UUID
	}
	todo, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (untagged, error) {
		var u untagged
		return u, r.Scan(&u.id, &u.to, &u.invite)
	})
	if err != nil {
		return err
	}
	for _, u := range todo {
		tag := q.Tagger.EmailTag(u.to)
		if _, err := tx.Exec(ctx, `UPDATE mail_log SET recipient_tag = $2 WHERE id = $1`, u.id, tag); err != nil {
			return err
		}
		if u.invite != nil {
			if _, err := tx.Exec(ctx,
				`UPDATE invite_codes SET email_tag = $2 WHERE id = $1 AND email_tag IS NULL AND origin = 'cli'
				    AND closed_at IS NULL`, *u.invite, tag); err != nil {
				return err
			}
		}
	}
	return tx.Commit(ctx)
}

// lanesAtRate lists the lanes that have used their hourly rate.
func (q *Queue) lanesAtRate(ctx context.Context) ([]string, error) {
	out := []string{}
	for lane, rate := range q.Rates {
		if rate <= 0 {
			continue
		}
		var n int
		if err := q.Pool.QueryRow(ctx,
			`SELECT count(*) FROM mail_log WHERE lane = $1
			    AND ((status = 'sent' AND sent_at > now() - interval '1 hour') OR status = 'sending')`,
			string(lane)).Scan(&n); err != nil {
			return nil, err
		}
		if n >= rate {
			out = append(out, string(lane))
		}
	}
	return out, nil
}

// ProcessOne leases, renders, sends and finalizes at most one due row.
func (q *Queue) ProcessOne(ctx context.Context) (bool, error) {
	if q.Stopped() {
		return false, nil
	}
	if err := q.fillTags(ctx); err != nil {
		return false, fmt.Errorf("mailq: tags: %w", err)
	}
	if _, err := q.Pool.Exec(ctx,
		`UPDATE mail_log SET status = 'queued', lease_until = NULL, next_attempt_at = now()
		  WHERE status = 'sending' AND lease_until < now() AND attempts < $1`, maxAttempts); err != nil {
		return false, fmt.Errorf("mailq: expired leases: %w", err)
	}
	if err := q.failExhausted(ctx); err != nil {
		return false, fmt.Errorf("mailq: exhausted rows: %w", err)
	}
	full, err := q.lanesAtRate(ctx)
	if err != nil {
		return false, fmt.Errorf("mailq: lane rates: %w", err)
	}
	var (
		row    Row
		params []byte
		subk   *string
		lane   string
		lease  time.Time
	)
	err = q.Pool.QueryRow(ctx,
		`UPDATE mail_log SET status = 'sending', lease_until = now() + interval '2 minutes',
		        attempts = attempts + 1, next_attempt_at = NULL
		  WHERE id = (SELECT id FROM mail_log
		               WHERE status = 'queued' AND next_attempt_at <= now() AND recipient_tag IS NOT NULL
		                 AND lane <> ALL($1::text[]) AND attempts < $2
		               ORDER BY CASE lane WHEN 'transactional' THEN 0 WHEN 'waitlist' THEN 1 ELSE 2 END, next_attempt_at
		               FOR UPDATE SKIP LOCKED LIMIT 1)
		 RETURNING id, kind, subkind, lane, recipient, recipient_tag, user_id, waitlist_entry_id, invite_id,
		           bank_slug, params, attempts, created_at, lease_until`, full, maxAttempts).
		Scan(&row.ID, &row.Kind, &subk, &lane, &row.Recipient, &row.RecipientTag, &row.UserID, &row.EntryID,
			&row.InviteID, &row.BankSlug, &params, &row.Attempts, &row.CreatedAt, &lease)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("mailq: lease: %w", err)
	}
	row.Lane = Lane(lane)
	if subk != nil {
		row.Subkind = *subk
	}
	_ = json.Unmarshal(params, &row.Params)

	msg, err := q.render(ctx, row)
	if err != nil {
		slog.Warn("mailq: render failed", "mail_kind", row.Kind, "mail_attempt", row.Attempts, "err", err.Error())
		failure := fmt.Errorf("%w: render", mail.ErrPermanent)
		if transientRender(err) {
			failure = errRenderRetry
		}
		q.finalize(ctx, &row, lease, "", failure, false)
		return true, nil
	}
	msg.To = row.Recipient
	if q.Sender == nil {
		q.finalize(ctx, &row, lease, "", errors.New("mailq: no sender"), false)
		return true, nil
	}
	sctx, cancel := context.WithTimeout(ctx, sendTimeout)
	pid, sendErr := q.Sender.Send(sctx, msg)
	cancel()
	msg = mail.Message{} // the rendered message is never kept
	q.finalize(ctx, &row, lease, pid, sendErr, false)
	return true, nil
}

func (q *Queue) render(ctx context.Context, row Row) (mail.Message, error) {
	r, ok := q.renderers[row.Kind]
	if !ok {
		return mail.Message{}, fmt.Errorf("%w %q", ErrNoRenderer, row.Kind)
	}
	ctx, cancel := context.WithTimeout(ctx, renderFor)
	defer cancel()
	tx, err := pgtx.BeginReadCommitted(ctx, q.Pool)
	if err != nil {
		return mail.Message{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	msg, err := r.Render(ctx, tx, row)
	if err != nil {
		return mail.Message{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return mail.Message{}, err
	}
	return msg, nil
}

func clip(s string) string {
	if len(s) > errorMaxLen {
		return s[:errorMaxLen]
	}
	return s
}

// finalize records a send's outcome. The UPDATE is conditional on the row's
// own lease, so a row a purge suppressed meanwhile stays suppressed. A row
// that has become final loses its address at once when it is a `deleted`
// email (O-17).
func (q *Queue) finalize(ctx context.Context, row *Row, lease time.Time, pid string, sendErr error, oneShot bool) {
	ctx = context.WithoutCancel(ctx)
	kind := row.Kind
	var (
		sql  string
		args = []any{row.ID, lease}
	)
	unsent := false
	redact := "recipient"
	if kind == "deleted" {
		redact = "NULL"
	}
	switch {
	case sendErr == nil:
		sql = `UPDATE mail_log SET status = 'sent', sent_at = now(), final_at = now(), lease_until = NULL,
		        provider_message_id = $3, recipient = ` + redact + ` WHERE id = $1 AND status = 'sending' AND lease_until = $2`
		args = append(args, nilIfEmpty(pid))
	case errors.Is(sendErr, mail.ErrBounced):
		sql = `UPDATE mail_log SET status = 'bounced', final_at = now(), lease_until = NULL, error = $3,
		        recipient = ` + redact + ` WHERE id = $1 AND status = 'sending' AND lease_until = $2`
		args = append(args, clip("bounced"))
		unsent = true
	case errors.Is(sendErr, mail.ErrAuth) && !oneShot:
		q.stopped.Store(true)
		slog.Error("mailq: the email provider refused the credentials; sending stopped on every lane until restart")
		sql = `UPDATE mail_log SET status = 'queued', next_attempt_at = now(), lease_until = NULL, error = $3,
		        attempts = greatest(attempts - 1, 0)
		        WHERE id = $1 AND status = 'sending' AND lease_until = $2`
		args = append(args, clip("auth: "+sendErr.Error()))
	default:
		retry := !oneShot && !errors.Is(sendErr, mail.ErrPermanent) && !errors.Is(sendErr, mail.ErrAuth) &&
			row.Attempts < maxAttempts
		if retry {
			wait := backoff[min(row.Attempts, len(backoff))-1]
			if time.Since(row.CreatedAt)+wait > retryWindow(kind) {
				retry = false
			} else {
				sql = `UPDATE mail_log SET status = 'queued', next_attempt_at = now() + $3::interval, lease_until = NULL,
				        error = $4 WHERE id = $1 AND status = 'sending' AND lease_until = $2`
				args = append(args, fmt.Sprintf("%d seconds", int(wait/time.Second)), clip(sendErr.Error()))
			}
		}
		if !retry {
			sql = `UPDATE mail_log SET status = 'failed', final_at = now(), lease_until = NULL, error = $3,
			        recipient = ` + redact + ` WHERE id = $1 AND status = 'sending' AND lease_until = $2`
			args = append(args, clip(sendErr.Error()))
			unsent = true
		}
		if errors.Is(sendErr, mail.ErrAuth) {
			q.stopped.Store(true)
		}
	}
	bounced := errors.Is(sendErr, mail.ErrBounced) && row.UserID != nil && q.Bounced != nil
	if err := q.finalizeTx(ctx, sql, args, func(tx pgx.Tx) (func(), error) {
		if bounced {
			if err := q.Bounced(ctx, tx, *row); err != nil {
				return nil, err
			}
		}
		if unsent && q.Unsent != nil {
			return q.Unsent(ctx, tx, *row)
		}
		return nil, nil
	}); err != nil {
		slog.Error("mailq: finalize", "mail_kind", kind, "err", err.Error())
	}
	if sendErr != nil {
		slog.Warn("mailq: send failed", "mail_kind", kind, "err", clip(sendErr.Error()))
	}
}

func (q *Queue) failExhausted(ctx context.Context) error {
	tx, err := pgtx.BeginReadCommitted(ctx, q.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	rows, err := tx.Query(ctx,
		`UPDATE mail_log SET status = 'failed', final_at = now(), lease_until = NULL, next_attempt_at = NULL,
		        error = 'attempts exhausted', recipient = CASE WHEN kind = 'deleted' THEN NULL ELSE recipient END
		  WHERE attempts >= $1 AND recipient_tag IS NOT NULL
		    AND (status = 'queued' OR (status = 'sending' AND lease_until < now()))
		 RETURNING id, kind, user_id, waitlist_entry_id, invite_id`, maxAttempts)
	if err != nil {
		return err
	}
	failed, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Row, error) {
		var row Row
		return row, r.Scan(&row.ID, &row.Kind, &row.UserID, &row.EntryID, &row.InviteID)
	})
	if err != nil {
		return err
	}
	var after []func()
	if q.Unsent != nil {
		for _, row := range failed {
			done, err := q.Unsent(ctx, tx, row)
			if err != nil {
				return err
			}
			after = appendDone(after, done)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	runDone(after)
	return nil
}

func appendDone(after []func(), done func()) []func() {
	if done == nil {
		return after
	}
	return append(after, done)
}

func runDone(after []func()) {
	for _, done := range after {
		done()
	}
}

// finalizeTx runs the finalizing UPDATE and, when it changed the row, then.
func (q *Queue) finalizeTx(ctx context.Context, sql string, args []any, then func(pgx.Tx) (func(), error)) error {
	tx, err := pgtx.BeginReadCommitted(ctx, q.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	tag, err := tx.Exec(ctx, sql, args...)
	if err != nil {
		return err
	}
	var done func()
	if tag.RowsAffected() == 1 {
		if done, err = then(tx); err != nil {
			return err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	runDone(appendDone(nil, done))
	return nil
}

// Sweep is spec 07 §2.11's mail rows: retention, redaction of subject-less
// rows 7 days after they became final, and the 24-hour bound on `deleted`.
func (q *Queue) Sweep(ctx context.Context) (string, error) {
	ret := q.Retention
	if ret <= 0 {
		ret = 30 * 24 * time.Hour
	}
	tx, err := pgtx.BeginReadCommitted(ctx, q.Pool)
	if err != nil {
		return "", err
	}
	defer pgtx.Rollback(ctx, tx)
	rows, err := tx.Query(ctx,
		`DELETE FROM mail_log WHERE created_at < now() - $1::interval AND status <> 'sending'
		 RETURNING id, kind, status, user_id, waitlist_entry_id, invite_id`,
		fmt.Sprintf("%d seconds", int64(ret/time.Second)))
	if err != nil {
		return "", fmt.Errorf("mailq: retention: %w", err)
	}
	type gone struct {
		row    Row
		status string
	}
	deleted, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (gone, error) {
		var g gone
		return g, r.Scan(&g.row.ID, &g.row.Kind, &g.status, &g.row.UserID, &g.row.EntryID, &g.row.InviteID)
	})
	if err != nil {
		return "", fmt.Errorf("mailq: retention: %w", err)
	}
	var after []func()
	if q.Unsent != nil {
		for _, g := range deleted {
			if g.status != string(StatusQueued) {
				continue
			}
			done, err := q.Unsent(ctx, tx, g.row)
			if err != nil {
				return "", fmt.Errorf("mailq: retention: %w", err)
			}
			after = appendDone(after, done)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return "", fmt.Errorf("mailq: retention: %w", err)
	}
	runDone(after)
	red, err := q.Pool.Exec(ctx,
		`UPDATE mail_log SET recipient = NULL WHERE recipient IS NOT NULL AND user_id IS NULL
		    AND waitlist_entry_id IS NULL AND final_at < now() - interval '7 days'`)
	if err != nil {
		return "", fmt.Errorf("mailq: redact: %w", err)
	}
	bound, err := q.Pool.Exec(ctx,
		`UPDATE mail_log SET status = 'failed', next_attempt_at = NULL, final_at = now(), recipient = NULL,
		        error = 'bound: 24 h (O-17)'
		  WHERE kind = 'deleted' AND status = 'queued' AND created_at < now() - interval '24 hours'`)
	if err != nil {
		return "", fmt.Errorf("mailq: deleted bound: %w", err)
	}
	del := int64(len(deleted))
	if del+red.RowsAffected()+bound.RowsAffected() == 0 {
		return "", nil
	}
	return fmt.Sprintf("%d deleted, %d redacted, %d bounded", del, red.RowsAffected(),
		bound.RowsAffected()), nil
}
