// Package mailq is the email outbox and log (spec 07 §2.8, §3.5, §6): every
// email hasalad sends has a mail_log row, written before the send, finalized
// after it, and never holding a subject, a body, a code or a token.
//
// Two ways in:
//   - EnqueueTx writes a queued row inside the caller's transaction (alerts,
//     enqueued with the event that causes them, so a rollback sends nothing
//     and a restart loses nothing). The worker (RunOnce, Run) leases it,
//     renders it with the kind's Renderer in its own transaction (which may
//     mint a secret and store only its hash), sends, and finalizes.
//   - SendNow is for an email whose secret the caller already minted and must
//     never reach the database (spec 02's code emails, D-12): it writes the
//     row as sending, renders from memory, sends once and finalizes.
//
// This is the part of spec 07's mailq that spec 02's flows need: the
// transactional lane, the per-kind params allow-list, retry windows and
// backoff, the auth stop, the deleted-row redaction and the bounce hook. The
// waitlist and bulk lanes' caps and hourly rates arrive with WS-19.
package mailq

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mail"
)

// Lane is a mail_log lane.
type Lane string

// Lanes.
const (
	LaneTransactional Lane = "transactional"
	LaneWaitlist      Lane = "waitlist"
	LaneBulk          Lane = "bulk"
)

// Lease is how long a worker holds a row it is sending.
const Lease = 2 * time.Minute

// backoff is the retry schedule after a transient failure (spec 07 §3.5).
var backoff = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour, 6 * time.Hour, 12 * time.Hour}

// allowedParams is spec 07 §6.3's per-kind params allow-list. A key outside it
// is a programming error, refused at enqueue.
var allowedParams = map[string][]string{
	"waitlist": {}, "waitlist_already": {"variant"}, "waitlist_has_account": {}, "invite": {},
	"bank_supported": {"audience"},
	"code":           {"purpose"}, "reset_code": {"purpose"}, "recovery_code": {"purpose"},
	"alert": {"event_at"}, "deleted": {"deleted_at"}, "test": {},
}

// retryWindow is how long after created_at a row may still be retried.
func retryWindow(kind string) time.Duration {
	switch kind {
	case "code", "reset_code", "recovery_code":
		return 10 * time.Minute
	}
	return 24 * time.Hour
}

// Enqueue is one email to log.
type Enqueue struct {
	Kind, Subkind string
	Lane          Lane
	To            string // email_norm
	Tag           []byte // email_tag(To); nil only for rows the worker tags
	UserID        *uuid.UUID
	Params        map[string]any
}

// Row is a leased mail_log row, as a Renderer sees it.
type Row struct {
	ID        int64
	Kind      string
	Subkind   string
	Lane      Lane
	Recipient string
	Tag       []byte
	UserID    *uuid.UUID
	Params    map[string]any
	Attempts  int
	CreatedAt time.Time
}

// Renderer builds a queued row's message at send time, inside tx. It may mint
// a secret and store its hash there; tx commits before the send.
type Renderer interface {
	Render(ctx context.Context, tx pgx.Tx, row Row) (mail.Message, error)
}

// RendererFunc adapts a function.
type RendererFunc func(ctx context.Context, tx pgx.Tx, row Row) (mail.Message, error)

// Render calls f.
func (f RendererFunc) Render(ctx context.Context, tx pgx.Tx, row Row) (mail.Message, error) {
	return f(ctx, tx, row)
}

// Queue owns mail_log.
type Queue struct {
	Pool      *pgxpool.Pool
	Sender    mail.Sender
	Renderers map[string]Renderer // by kind
	// Bounced runs in the finalizing transaction of a bounced row that has a
	// user_id (spec 02 §14.7). It makes no network call.
	Bounced func(ctx context.Context, tx pgx.Tx, row Row) error
	// Tagger computes email_tag for rows enqueued without one (console, CLI).
	Tagger func(emailNorm string) []byte
	Now    func() time.Time
	Logf   func(format string, args ...any)

	kick   chan struct{}
	paused atomic.Bool
}

func (q *Queue) now() time.Time {
	if q.Now != nil {
		return q.Now()
	}
	return time.Now()
}

func (q *Queue) logf(format string, args ...any) {
	if q.Logf != nil {
		q.Logf(format, args...)
		return
	}
	log.Printf(format, args...)
}

// Paused reports whether an auth failure stopped the worker on every lane.
func (q *Queue) Paused() bool { return q.paused.Load() }

// Hint is spec 07 §4.5's masked recipient: the first character of the local
// part, "•••", "@" and the whole domain; a one-character local part loses it.
func Hint(addr string) string {
	at := strings.LastIndexByte(addr, '@')
	if at < 0 {
		return "•••"
	}
	local, domain := addr[:at], addr[at+1:]
	if len(local) <= 1 {
		return "•••@" + domain
	}
	return local[:1] + "•••@" + domain
}

func (e Enqueue) check() error {
	allowed, ok := allowedParams[e.Kind]
	if !ok {
		return fmt.Errorf("mailq: unknown kind %q", e.Kind)
	}
	for k := range e.Params {
		found := false
		for _, a := range allowed {
			found = found || a == k
		}
		if !found {
			return fmt.Errorf("mailq: params key %q is not allowed for kind %s", k, e.Kind)
		}
	}
	if e.To == "" {
		return errors.New("mailq: no recipient")
	}
	if e.Lane == "" {
		return errors.New("mailq: no lane")
	}
	return nil
}

func (e Enqueue) paramsJSON() ([]byte, error) {
	if e.Params == nil {
		return []byte("{}"), nil
	}
	return json.Marshal(e.Params)
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// EnqueueTx writes a queued row inside tx and returns its id. Callers Kick the
// worker after their transaction commits.
func (q *Queue) EnqueueTx(ctx context.Context, tx pgx.Tx, e Enqueue) (int64, error) {
	if err := e.check(); err != nil {
		return 0, err
	}
	params, err := e.paramsJSON()
	if err != nil {
		return 0, err
	}
	var tag any
	if len(e.Tag) > 0 {
		tag = e.Tag
	}
	now := q.now()
	var id int64
	err = tx.QueryRow(ctx,
		`INSERT INTO mail_log (kind, subkind, lane, recipient, recipient_tag, recipient_hint, user_id, params,
		   status, next_attempt_at, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'queued', $9, $9) RETURNING id`,
		e.Kind, nullable(e.Subkind), string(e.Lane), e.To, tag, Hint(e.To), e.UserID, params, now).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("mailq: enqueue %s: %w", e.Kind, err)
	}
	return id, nil
}

// Kick wakes the worker (after the transaction that enqueued commits).
func (q *Queue) Kick() {
	if q.kick == nil {
		return
	}
	select {
	case q.kick <- struct{}{}:
	default:
	}
}

// SendNow logs and sends one email whose secret lives only in render's
// closure: the row is written as sending, render runs, Send is called once,
// and the row is finalized. A failure is final (one attempt: the person asks
// for a new code).
func (q *Queue) SendNow(ctx context.Context, e Enqueue, render func() (mail.Message, error)) error {
	if err := e.check(); err != nil {
		return err
	}
	if len(e.Tag) != 32 {
		return errors.New("mailq: SendNow needs the recipient's tag")
	}
	params, err := e.paramsJSON()
	if err != nil {
		return err
	}
	now := q.now()
	lease := now.Add(Lease)
	var id int64
	if err := q.Pool.QueryRow(ctx,
		`INSERT INTO mail_log (kind, subkind, lane, recipient, recipient_tag, recipient_hint, user_id, params,
		   status, attempts, lease_until, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'sending', 1, $9, $10) RETURNING id`,
		e.Kind, nullable(e.Subkind), string(e.Lane), e.To, e.Tag, Hint(e.To), e.UserID, params, lease, now).Scan(&id); err != nil {
		return fmt.Errorf("mailq: log %s: %w", e.Kind, err)
	}
	row := Row{ID: id, Kind: e.Kind, Subkind: e.Subkind, Lane: e.Lane, Recipient: e.To, Tag: e.Tag,
		UserID: e.UserID, Params: e.Params, Attempts: 1, CreatedAt: now}
	if q.paused.Load() {
		return q.finalize(ctx, row, lease, "", &mail.SendError{Class: mail.ErrAuth}, true)
	}
	m, err := render()
	if err != nil {
		_ = q.finalize(ctx, row, lease, "", fmt.Errorf("%w: render: %v", mail.ErrPermanent, err), true)
		return err
	}
	m.To = e.To
	pid, sendErr := q.Sender.Send(ctx, m)
	return q.finalize(ctx, row, lease, pid, sendErr, true)
}

// finalize records a send's outcome, conditional on the row still being ours
// (a purge may have suppressed it meanwhile). once means no retry.
func (q *Queue) finalize(ctx context.Context, row Row, lease time.Time, providerID string, sendErr error, once bool) error {
	now := q.now()
	tx, err := q.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("mailq: finalize: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	redact := row.Kind == "deleted"
	var tag int64
	switch {
	case sendErr == nil:
		tag, err = execTag(ctx, tx,
			`UPDATE mail_log SET status = 'sent', sent_at = $3, final_at = $3, lease_until = NULL,
			   provider_message_id = $4, recipient = CASE WHEN $5 THEN NULL ELSE recipient END
			 WHERE id = $1 AND status = 'sending' AND lease_until = $2`,
			row.ID, lease, now, nullable(truncate(providerID, 128)), redact)
	case errors.Is(sendErr, mail.ErrBounced):
		tag, err = execTag(ctx, tx,
			`UPDATE mail_log SET status = 'bounced', final_at = $3, lease_until = NULL, error = $4,
			   recipient = CASE WHEN $5 THEN NULL ELSE recipient END
			 WHERE id = $1 AND status = 'sending' AND lease_until = $2`,
			row.ID, lease, now, truncate(sendErr.Error(), 200), redact)
		if err == nil && tag == 1 && row.UserID != nil && q.Bounced != nil {
			err = q.Bounced(ctx, tx, row)
		}
	case errors.Is(sendErr, mail.ErrAuth) && !once:
		q.paused.Store(true)
		q.logf("mailq: the provider refused the credentials; every lane is paused until restart")
		tag, err = execTag(ctx, tx,
			`UPDATE mail_log SET status = 'queued', lease_until = NULL, next_attempt_at = $3, attempts = greatest(attempts - 1, 0)
			 WHERE id = $1 AND status = 'sending' AND lease_until = $2`, row.ID, lease, now)
	default:
		retryAt := now.Add(backoff[min(max(row.Attempts-1, 0), len(backoff)-1)])
		permanent := errors.Is(sendErr, mail.ErrPermanent) || errors.Is(sendErr, mail.ErrAuth)
		if once || permanent || row.Attempts >= 10 || retryAt.After(row.CreatedAt.Add(retryWindow(row.Kind))) {
			tag, err = execTag(ctx, tx,
				`UPDATE mail_log SET status = 'failed', final_at = $3, lease_until = NULL, error = $4,
				   recipient = CASE WHEN $5 THEN NULL ELSE recipient END
				 WHERE id = $1 AND status = 'sending' AND lease_until = $2`,
				row.ID, lease, now, truncate(sendErr.Error(), 200), redact)
			if errors.Is(sendErr, mail.ErrAuth) {
				q.paused.Store(true)
			}
		} else {
			tag, err = execTag(ctx, tx,
				`UPDATE mail_log SET status = 'queued', lease_until = NULL, next_attempt_at = $3, error = $4
				 WHERE id = $1 AND status = 'sending' AND lease_until = $2`,
				row.ID, lease, retryAt, truncate(sendErr.Error(), 200))
		}
	}
	if err != nil {
		return fmt.Errorf("mailq: finalize %d: %w", row.ID, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("mailq: finalize %d: commit: %w", row.ID, err)
	}
	if sendErr != nil {
		q.logf("mailq: %s attempt %d: %v", row.Kind, row.Attempts, sendErr)
		return sendErr
	}
	return nil
}

func execTag(ctx context.Context, tx pgx.Tx, sql string, args ...any) (int64, error) {
	t, err := tx.Exec(ctx, sql, args...)
	if err != nil {
		return 0, err
	}
	return t.RowsAffected(), nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// RunOnce returns expired leases to the queue, tags untagged rows, then sends
// every due row once. It answers how many rows it sent.
func (q *Queue) RunOnce(ctx context.Context) (int, error) {
	if q.paused.Load() {
		return 0, nil
	}
	now := q.now()
	if _, err := q.Pool.Exec(ctx,
		`UPDATE mail_log SET status = 'queued', lease_until = NULL, next_attempt_at = $1
		  WHERE status = 'sending' AND lease_until < $1`, now); err != nil {
		return 0, fmt.Errorf("mailq: return expired leases: %w", err)
	}
	if q.Tagger != nil {
		if err := q.tagRows(ctx, now); err != nil {
			return 0, err
		}
	}
	sent := 0
	for ctx.Err() == nil && !q.paused.Load() {
		row, lease, ok, err := q.lease(ctx)
		if err != nil {
			return sent, err
		}
		if !ok {
			break
		}
		if err := q.sendLeased(ctx, row, lease); err == nil {
			sent++
		}
	}
	return sent, nil
}

func (q *Queue) tagRows(ctx context.Context, now time.Time) error {
	rows, err := q.Pool.Query(ctx,
		`SELECT id, recipient FROM mail_log WHERE status = 'queued' AND recipient_tag IS NULL
		  AND next_attempt_at <= $1 LIMIT 100`, now)
	if err != nil {
		return fmt.Errorf("mailq: untagged rows: %w", err)
	}
	type pending struct {
		id   int64
		addr string
	}
	var todo []pending
	for rows.Next() {
		var p pending
		if err := rows.Scan(&p.id, &p.addr); err != nil {
			rows.Close()
			return err
		}
		todo = append(todo, p)
	}
	rows.Close()
	for _, p := range todo {
		if _, err := q.Pool.Exec(ctx, `UPDATE mail_log SET recipient_tag = $2 WHERE id = $1 AND recipient_tag IS NULL`,
			p.id, q.Tagger(p.addr)); err != nil {
			return fmt.Errorf("mailq: tag row %d: %w", p.id, err)
		}
	}
	return nil
}

func (q *Queue) lease(ctx context.Context) (Row, time.Time, bool, error) {
	now := q.now()
	lease := now.Add(Lease)
	var (
		r      Row
		params []byte
		lane   string
		sub    *string
	)
	err := q.Pool.QueryRow(ctx,
		`UPDATE mail_log SET status = 'sending', lease_until = $2, attempts = attempts + 1, next_attempt_at = NULL
		  WHERE id = (SELECT id FROM mail_log WHERE status = 'queued' AND next_attempt_at <= $1 AND recipient_tag IS NOT NULL
		               ORDER BY CASE lane WHEN 'transactional' THEN 0 WHEN 'waitlist' THEN 1 ELSE 2 END, next_attempt_at
		               FOR UPDATE SKIP LOCKED LIMIT 1)
		 RETURNING id, kind, subkind, lane, recipient, recipient_tag, user_id, params, attempts, created_at`,
		now, lease).Scan(&r.ID, &r.Kind, &sub, &lane, &r.Recipient, &r.Tag, &r.UserID, &params, &r.Attempts, &r.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Row{}, time.Time{}, false, nil
	}
	if err != nil {
		return Row{}, time.Time{}, false, fmt.Errorf("mailq: lease: %w", err)
	}
	r.Lane = Lane(lane)
	if sub != nil {
		r.Subkind = *sub
	}
	_ = json.Unmarshal(params, &r.Params)
	return r, lease, true, nil
}

func (q *Queue) sendLeased(ctx context.Context, row Row, lease time.Time) error {
	rd, ok := q.Renderers[row.Kind]
	if !ok {
		return q.finalize(ctx, row, lease, "", fmt.Errorf("%w: no renderer for %s", mail.ErrPermanent, row.Kind), true)
	}
	tx, err := q.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	m, err := rd.Render(ctx, tx, row)
	if err != nil {
		_ = tx.Rollback(ctx)
		return q.finalize(ctx, row, lease, "", fmt.Errorf("%w: render: %v", mail.ErrPermanent, err), true)
	}
	if err := tx.Commit(ctx); err != nil {
		return q.finalize(ctx, row, lease, "", fmt.Errorf("render commit: %v", err), false)
	}
	m.To = row.Recipient
	pid, sendErr := q.Sender.Send(ctx, m)
	return q.finalize(ctx, row, lease, pid, sendErr, false)
}

// Run sends until ctx ends: on every Kick and at least every poll interval.
func (q *Queue) Run(ctx context.Context, poll time.Duration) {
	if q.kick == nil {
		q.kick = make(chan struct{}, 1)
	}
	if poll <= 0 {
		poll = 30 * time.Second
	}
	t := time.NewTicker(poll)
	defer t.Stop()
	for {
		if _, err := q.RunOnce(ctx); err != nil && ctx.Err() == nil {
			q.logf("mailq: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-q.kick:
		}
	}
}

// EnableKick makes Kick wake Run; call it before starting Run concurrently.
func (q *Queue) EnableKick() {
	if q.kick == nil {
		q.kick = make(chan struct{}, 1)
	}
}
