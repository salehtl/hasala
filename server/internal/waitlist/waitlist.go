// Package waitlist is the beta waitlist (spec 07 §2.3, §2.4, §3.1, §5.3–§5.5,
// §6.4): a double opt-in by link, a leave link, the join hook that runs when
// an invite is redeemed, the sweeps, and the renderers of its three emails.
//
// The submit path answers the same for every valid address (spec 07 §5.3):
// what changes is only which email is queued, by waitlist_submit in one round
// trip, and the worker sends it later.
package waitlist

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/banks"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// Errors the routes map to spec 07 §5.8's codes.
var (
	ErrBadEmail    = errors.New("waitlist: not an email address")
	ErrBadRequest  = errors.New("waitlist: malformed submission")
	ErrFull        = errors.New("waitlist: the list is full")
	ErrLinkExpired = errors.New("waitlist: the link is unknown or expired")
)

// Token lifetimes (spec 07 §4.2).
const (
	ConfirmTTL = 7 * 24 * time.Hour
	LeaveTTL   = 90 * 24 * time.Hour
	TokenLen   = 43 // b64url of 32 bytes
)

// Service is the waitlist. Build it with New.
type Service struct {
	Pool    *pgxpool.Pool
	Tagger  mailq.Tagger
	WebBase string // https://hasala.app
	// MaxOpen and MaxPending are the ceilings of spec 07 §5.3 step 7.
	MaxOpen, MaxPending int
	// ConfirmedRetention is HASALA_WAITLIST_RETENTION (180 days).
	ConfirmedRetention time.Duration
	// OnConfirmed, when set, runs after a confirmation commits: the entry is
	// then on the console's list to approve. It gets nothing about the entry.
	OnConfirmed func()

	mu        sync.Mutex
	countsAt  time.Time
	open, pen int
}

// New builds the service with spec 07 §14.1's defaults.
func New(pool *pgxpool.Pool, tagger mailq.Tagger, webBase string) *Service {
	return &Service{Pool: pool, Tagger: tagger, WebBase: strings.TrimSuffix(webBase, "/"),
		MaxOpen: 10_000, MaxPending: 2_000, ConfirmedRetention: 180 * 24 * time.Hour}
}

// Submission is a validated P1 body.
type Submission struct {
	Email, Bank, OtherBank, Source string
}

// full reports the ceilings, from counts cached for at most 60 s.
func (s *Service) full(ctx context.Context) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.countsAt) > time.Minute {
		if err := s.Pool.QueryRow(ctx,
			`SELECT count(*) FILTER (WHERE state IN ('pending','confirmed','invited')),
			        count(*) FILTER (WHERE state = 'pending') FROM waitlist_entries`).Scan(&s.open, &s.pen); err != nil {
			return false, err
		}
		s.countsAt = time.Now()
	}
	return s.open >= s.MaxOpen || s.pen >= s.MaxPending, nil
}

// Validate is spec 07 §5.3 step 5 (and the bank half of §4.3), without
// touching the database beyond the catalog.
func (s *Service) Validate(ctx context.Context, sub Submission) (string, banks.Choice, error) {
	email, err := keyproto.EmailNorm(sub.Email)
	if err != nil || sub.Email == "" {
		return "", banks.Choice{}, ErrBadEmail
	}
	if sub.Source != "web" {
		return "", banks.Choice{}, ErrBadRequest
	}
	if sub.Bank == "" {
		return "", banks.Choice{}, banks.ErrBadBank
	}
	choice, err := banks.Resolve(ctx, s.Pool, sub.Bank, sub.OtherBank)
	if err != nil {
		return "", banks.Choice{}, err
	}
	return email, choice, nil
}

// Submit runs steps 7–9 of spec 07 §5.3 for an already validated submission
// and returns the outcome word (for the metric only; the caller's answer is
// the same whatever it is).
func (s *Service) Submit(ctx context.Context, email string, c banks.Choice) (string, error) {
	if s.Tagger == nil {
		return "", errors.New("waitlist: no auth key: email_tag cannot be computed")
	}
	full, err := s.full(ctx)
	if err != nil {
		return "", err
	}
	if full {
		return "", ErrFull
	}
	tag := s.Tagger.EmailTag(email)
	var outcome string
	err = s.Pool.QueryRow(ctx, `SELECT waitlist_submit($1, $2, $3, $4, $5, $6, 'web')`,
		tag, email, mailq.Hint(email), nullable(c.Slug), nullable(c.OtherText), nullable(c.OtherKey)).Scan(&outcome)
	if err != nil {
		return "", fmt.Errorf("waitlist: submit: %w", err)
	}
	return outcome, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// DecodeToken checks a link token's shape and returns its stored hash.
func DecodeToken(token string) ([]byte, bool) {
	if len(token) != TokenLen {
		return nil, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) != 32 {
		return nil, false
	}
	sum := sha256.Sum256(raw)
	return sum[:], true
}

// Confirm is P2 (spec 07 §5.4): "confirmed", "already_confirmed", or
// ErrLinkExpired.
func (s *Service) Confirm(ctx context.Context, token string) (string, error) {
	hash, ok := DecodeToken(token)
	if !ok {
		return "", ErrBadRequest
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return "", err
	}
	defer pgtx.Rollback(ctx, tx)
	var (
		entry uuid.UUID
		state string
	)
	err = tx.QueryRow(ctx,
		`SELECT e.id, e.state FROM waitlist_tokens t JOIN waitlist_entries e ON e.id = t.entry_id
		  WHERE t.token_hash = $1 AND t.purpose = 'confirm' AND t.expires_at > now()
		  FOR UPDATE OF e`, hash).Scan(&entry, &state)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrLinkExpired
	}
	if err != nil {
		return "", fmt.Errorf("waitlist: confirm: %w", err)
	}
	if state != "pending" {
		return "already_confirmed", nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE waitlist_entries SET state = 'confirmed', confirmed_at = now(), updated_at = now() WHERE id = $1`,
		entry); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE waitlist_tokens SET used_at = now() WHERE token_hash = $1`, hash); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM waitlist_tokens WHERE entry_id = $1 AND purpose = 'confirm' AND used_at IS NULL`, entry); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `SELECT waitlist_derive_request($1)`, entry); err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	if s.OnConfirmed != nil {
		s.OnConfirmed()
	}
	return "confirmed", nil
}

// Leave is P3 (spec 07 §5.5): a valid, unexpired leave token deletes the entry
// (tokens, mail rows and bank requests cascade) and revokes its open invite.
// Every well-formed token gets the same answer, so Leave reports only errors
// that are not about the token.
func (s *Service) Leave(ctx context.Context, token string) error {
	hash, ok := DecodeToken(token)
	if !ok {
		return ErrBadRequest
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	var entry uuid.UUID
	err = tx.QueryRow(ctx,
		`SELECT entry_id FROM waitlist_tokens WHERE token_hash = $1 AND purpose = 'leave' AND expires_at > now()`,
		hash).Scan(&entry)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("waitlist: leave: %w", err)
	}
	if err := DeleteEntryTx(ctx, tx, entry); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// DeleteEntryTx deletes an entry as P3 and C8 do: an open invite is revoked
// first, then the entry goes with its tokens, mail rows and bank requests.
func DeleteEntryTx(ctx context.Context, tx pgx.Tx, entry uuid.UUID) error {
	if _, err := tx.Exec(ctx,
		`UPDATE invite_codes SET state = 'revoked', closed_at = now()
		  WHERE waitlist_entry_id = $1 AND state IN ('awaiting_testflight','queued','active')`, entry); err != nil {
		return fmt.Errorf("waitlist: revoke the entry's invite: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM waitlist_entries WHERE id = $1`, entry); err != nil {
		return fmt.Errorf("waitlist: delete entry: %w", err)
	}
	return nil
}

// OnInviteRedeemedTx is the join hook (spec 07 §3.1), run by the account
// transaction after the invite's UPDATE: the invite's entry joins and loses its
// address, its bank requests move to the account, and so does every other
// entry with the account's email_tag (accountTag; nil when the caller cannot
// compute it). TestFlight enrolments (step 3) do not exist yet.
func OnInviteRedeemedTx(ctx context.Context, tx pgx.Tx, inviteID, userID uuid.UUID, accountTag []byte) error {
	rows, err := tx.Query(ctx,
		`SELECT waitlist_entry_id FROM invite_codes WHERE id = $1 AND waitlist_entry_id IS NOT NULL
		 UNION
		 SELECT id FROM waitlist_entries WHERE $2::bytea IS NOT NULL AND email_tag = $2 AND state <> 'joined'`,
		inviteID, accountTag)
	if err != nil {
		return fmt.Errorf("waitlist: join hook: %w", err)
	}
	entries, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return fmt.Errorf("waitlist: join hook: %w", err)
	}
	for _, e := range entries {
		if _, err := tx.Exec(ctx,
			`UPDATE waitlist_entries SET state = 'joined', joined_at = now(), email_norm = NULL, updated_at = now(),
			        invited_at = coalesce(invited_at, now()), confirmed_at = coalesce(confirmed_at, now())
			  WHERE id = $1`, e); err != nil {
			return fmt.Errorf("waitlist: join: %w", err)
		}
		// A request identical to one the account already made is dropped first.
		if _, err := tx.Exec(ctx,
			`DELETE FROM bank_requests r WHERE r.waitlist_entry_id = $1 AND EXISTS (
			   SELECT 1 FROM bank_requests u WHERE u.user_id = $2
			      AND coalesce(u.bank_slug, 'other:' || u.other_key) = coalesce(r.bank_slug, 'other:' || r.other_key))`,
			e, userID); err != nil {
			return fmt.Errorf("waitlist: join requests: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`UPDATE bank_requests SET user_id = $2, waitlist_entry_id = NULL WHERE waitlist_entry_id = $1`,
			e, userID); err != nil {
			return fmt.Errorf("waitlist: join requests: %w", err)
		}
	}
	return nil
}

// MintToken creates one confirm or leave token for an entry inside tx and
// returns its link form (spec 07 §4.2); only the hash is stored.
func MintToken(ctx context.Context, tx pgx.Tx, entry uuid.UUID, purpose string) (string, error) {
	ttl := ConfirmTTL
	if purpose == "leave" {
		ttl = LeaveTTL
	} else if purpose != "confirm" {
		return "", fmt.Errorf("waitlist: token purpose %q", purpose)
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	if _, err := tx.Exec(ctx,
		`INSERT INTO waitlist_tokens (token_hash, entry_id, purpose, created_at, expires_at)
		 VALUES ($1, $2, $3, now(), now() + $4::interval)`,
		sum[:], entry, purpose, fmt.Sprintf("%d seconds", int64(ttl/time.Second))); err != nil {
		return "", fmt.Errorf("waitlist: mint %s token: %w", purpose, err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

// LeaveURL mints a leave token and returns its link.
func LeaveURL(ctx context.Context, tx pgx.Tx, webBase string, entry uuid.UUID) (string, error) {
	tok, err := MintToken(ctx, tx, entry, "leave")
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(webBase, "/") + "/waitlist/leave#" + tok, nil
}

// Sweep is spec 07 §2.11's waitlist sweeps.
func (s *Service) Sweep(ctx context.Context) (string, error) {
	var total int64
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`DELETE FROM waitlist_entries WHERE state = 'pending'
		    AND coalesce(last_confirm_sent_at, created_at) < now() - interval '7 days'`, nil},
		{`DELETE FROM waitlist_entries WHERE state = 'confirmed' AND confirmed_at < now() - $1::interval`,
			[]any{fmt.Sprintf("%d seconds", int64(s.ConfirmedRetention/time.Second))}},
		{`DELETE FROM waitlist_entries WHERE state = 'joined' AND joined_at < now() - interval '30 days'`, nil},
		{`DELETE FROM waitlist_tokens WHERE expires_at < now() OR used_at < now() - interval '1 day'`, nil},
	} {
		tag, err := s.Pool.Exec(ctx, q.sql, q.args...)
		if err != nil {
			return "", fmt.Errorf("waitlist: sweep: %w", err)
		}
		total += tag.RowsAffected()
	}
	if total == 0 {
		return "", nil
	}
	return fmt.Sprintf("%d waitlist rows swept", total), nil
}

// entryView is what the renderers read about an entry.
type entryView struct {
	email                         *string
	state                         string
	bankName                      *string
	confirmedAt, invitedAt, until *time.Time
}

func readEntry(ctx context.Context, tx pgx.Tx, id uuid.UUID) (entryView, error) {
	var v entryView
	err := tx.QueryRow(ctx,
		`SELECT e.email_norm, e.state, b.name, e.confirmed_at, e.invited_at,
		        (SELECT max(expires_at) FROM invite_codes i WHERE i.waitlist_entry_id = e.id AND i.state = 'active')
		   FROM waitlist_entries e LEFT JOIN banks b ON b.slug = e.bank_slug
		  WHERE e.id = $1 FOR UPDATE OF e`, id).
		Scan(&v.email, &v.state, &v.bankName, &v.confirmedAt, &v.invitedAt, &v.until)
	return v, err
}

// ErrStale is a queued email whose subject changed state before it was sent.
var ErrStale = errors.New("waitlist: the entry no longer needs this email")

func toMessage(row mailq.Row, r mailq.Rendered) mail.Message {
	return mail.Message{To: row.Recipient, Subject: r.Subject, Text: r.Text, HTML: r.HTML}
}

func dateOf(t *time.Time) string {
	if t == nil {
		return ""
	}
	return mailq.Date(*t)
}

// Register installs the waitlist's three renderers on q.
func (s *Service) Register(q *mailq.Queue) {
	why := "You're getting this because someone asked for a Hasala invite for this address at hasala.app."
	q.Register("waitlist", mailq.RenderFunc(func(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
		if row.EntryID == nil {
			return mail.Message{}, ErrStale
		}
		v, err := readEntry(ctx, tx, *row.EntryID)
		if err != nil || v.state != "pending" {
			return mail.Message{}, ErrStale
		}
		confirm, err := MintToken(ctx, tx, *row.EntryID, "confirm")
		if err != nil {
			return mail.Message{}, err
		}
		leave, err := LeaveURL(ctx, tx, s.WebBase, *row.EntryID)
		if err != nil {
			return mail.Message{}, err
		}
		bank := "Another bank"
		if v.bankName != nil {
			bank = *v.bankName
		}
		r, err := mailq.RenderTemplate("waitlist", mailq.Content{Email: row.Recipient, BankName: bank,
			ConfirmURL: s.WebBase + "/waitlist/confirm#" + confirm, LeaveURL: leave, Why: why})
		return toMessage(row, r), err
	}))
	q.Register("waitlist_already", mailq.RenderFunc(func(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
		if row.EntryID == nil {
			return mail.Message{}, ErrStale
		}
		v, err := readEntry(ctx, tx, *row.EntryID)
		if err != nil || (v.state != "confirmed" && v.state != "invited") {
			return mail.Message{}, ErrStale
		}
		leave, err := LeaveURL(ctx, tx, s.WebBase, *row.EntryID)
		if err != nil {
			return mail.Message{}, err
		}
		r, err := mailq.RenderTemplate("waitlist_already", mailq.Content{Email: row.Recipient, LeaveURL: leave,
			Invited: v.state == "invited", ConfirmedOn: dateOf(v.confirmedAt), InvitedOn: dateOf(v.invitedAt),
			Until: dateOf(v.until), Why: why})
		return toMessage(row, r), err
	}))
	q.Register("waitlist_has_account", mailq.RenderFunc(func(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
		// Greeted by name only when an account has verified this very address
		// (spec 07 §6.2, review 2 F-18); the column arrives with the signup work.
		var name *string
		err := tx.QueryRow(ctx, `SELECT to_jsonb(u) ->> 'display_name' FROM users u WHERE email_norm = $1`,
			row.Recipient).Scan(&name)
		greeting := "Hi,"
		if err == nil && name != nil {
			greeting = mailq.Greeting(*name)
		}
		r, err := mailq.RenderTemplate("waitlist_has_account", mailq.Content{Greeting: greeting, Email: row.Recipient,
			Why: why})
		return toMessage(row, r), err
	}))
}
