package banks

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/mailq"
)

var ErrBadDomain = errors.New("banks: not a sender domain")

var ErrBadStatus = errors.New("banks: not a bank status")

var ErrBadSlug = errors.New("banks: not a bank slug")

var ErrNoSuchBank = errors.New("banks: no such bank")

const MaxNote = 500

var Statuses = []string{"new", "planned", "in_progress", "supported", "wont_do"}

var states = map[string]string{
	"new":         "requested",
	"planned":     "collecting_samples",
	"in_progress": "template_in_progress",
	"supported":   "supported",
	"wont_do":     "declined",
}

var labels = map[string]string{
	"new":         "Requested",
	"planned":     "Collecting samples",
	"in_progress": "Template in progress",
	"supported":   "Supported",
	"wont_do":     "Declined",
}

func State(status string) string { return states[status] }

func Label(status string) string { return labels[status] }

var (
	domainShape = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`)
	slugShape   = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$`)
)

func SenderDomain(x string) (string, error) {
	d := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(x)), ".")
	if len(d) < 4 || len(d) > 253 || !domainShape.MatchString(d) {
		return "", ErrBadDomain
	}
	return d, nil
}

func Slug(x string) (string, error) {
	s := strings.TrimSpace(x)
	if s == "other" || !slugShape.MatchString(s) {
		return "", ErrBadSlug
	}
	return s, nil
}

type Request struct {
	Bank        string
	Name        string
	State       string
	RequestedAt time.Time
}

func ForUser(ctx context.Context, q Querier, userID uuid.UUID) ([]Request, error) {
	rows, err := q.Query(ctx,
		`SELECT coalesce(r.bank_slug, 'other'), coalesce(b.name, r.other_text), coalesce(b.status, 'new'), r.created_at
		   FROM bank_requests r LEFT JOIN banks b ON b.slug = r.bank_slug
		  WHERE r.user_id = $1
		  ORDER BY r.created_at, r.id`, userID)
	if err != nil {
		return nil, fmt.Errorf("banks: requests: %w", err)
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Request, error) {
		var r Request
		var status string
		err := row.Scan(&r.Bank, &r.Name, &status, &r.RequestedAt)
		r.State = State(status)
		return r, err
	})
}

type Entry struct {
	Slug, Name, State string
}

func List(ctx context.Context, q Querier) ([]Entry, error) {
	rows, err := q.Query(ctx, `SELECT slug, name, status FROM banks ORDER BY name, slug`)
	if err != nil {
		return nil, fmt.Errorf("banks: list: %w", err)
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Entry, error) {
		var e Entry
		var status string
		err := row.Scan(&e.Slug, &e.Name, &status)
		e.State = State(status)
		return e, err
	})
}

func SetStatus(ctx context.Context, tx pgx.Tx, slug, status, note string, now time.Time) (old string, err error) {
	if _, ok := states[status]; !ok {
		return "", ErrBadStatus
	}
	note = strings.TrimSpace(note)
	if len([]rune(note)) > MaxNote {
		return "", ErrBadStatus
	}
	err = tx.QueryRow(ctx, `SELECT status FROM banks WHERE slug = $1 FOR UPDATE`, slug).Scan(&old)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNoSuchBank
	}
	if err != nil {
		return "", fmt.Errorf("banks: status: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`UPDATE banks SET note = $2,
		        status = $3,
		        status_changed_at = CASE WHEN status = $3 THEN status_changed_at ELSE $4 END
		  WHERE slug = $1`, slug, note, status, now); err != nil {
		return "", fmt.Errorf("banks: status: %w", err)
	}
	return old, nil
}

func AddFromKey(ctx context.Context, tx pgx.Tx, slug, name, key string) error {
	slug, err := Slug(slug)
	if err != nil {
		return err
	}
	name, err = Text(name)
	if err != nil {
		return err
	}
	aliases := []string{}
	if key != "" {
		if k, err := Key(key); err != nil || k != key {
			return ErrBadBank
		}
		aliases = append(aliases, key)
	}
	if k, err := Key(name); err == nil && k != key {
		aliases = append(aliases, k)
	}
	tag, err := tx.Exec(ctx,
		`INSERT INTO banks (slug, name, status, aliases) VALUES ($1, $2, 'new', $3) ON CONFLICT (slug) DO NOTHING`,
		slug, name, aliases)
	if err != nil {
		return fmt.Errorf("banks: add: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrBadSlug
	}
	if key == "" {
		return nil
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM bank_requests r WHERE r.other_key = $1 AND EXISTS (
		   SELECT 1 FROM bank_requests s WHERE s.bank_slug = $2
		      AND (s.user_id = r.user_id OR s.waitlist_entry_id = r.waitlist_entry_id))`, key, slug); err != nil {
		return fmt.Errorf("banks: add: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`UPDATE bank_requests SET bank_slug = $2, other_key = NULL, other_text = NULL WHERE other_key = $1`,
		key, slug); err != nil {
		return fmt.Errorf("banks: add: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`UPDATE waitlist_entries SET bank_slug = $2, other_bank = NULL, other_bank_key = NULL WHERE other_bank_key = $1`,
		key, slug); err != nil {
		return fmt.Errorf("banks: add: %w", err)
	}
	return nil
}

func NotifySupported(ctx context.Context, tx pgx.Tx, q *mailq.Queue, slug string, now time.Time) (int, error) {
	rows, err := tx.Query(ctx,
		`SELECT r.id, r.user_id, r.waitlist_entry_id, coalesce(u.email_norm, e.email_norm)
		   FROM bank_requests r
		   LEFT JOIN users u ON u.id = r.user_id
		   LEFT JOIN waitlist_entries e ON e.id = r.waitlist_entry_id AND e.state IN ('confirmed', 'invited')
		  WHERE r.bank_slug = $1 AND r.notified_at IS NULL
		    AND (r.user_id IS NOT NULL OR r.waitlist_entry_id IS NOT NULL)
		  ORDER BY r.id
		  FOR UPDATE OF r`, slug)
	if err != nil {
		return 0, fmt.Errorf("banks: notify: %w", err)
	}
	type target struct {
		id    int64
		user  *uuid.UUID
		entry *uuid.UUID
		to    *string
	}
	targets, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (target, error) {
		var t target
		err := row.Scan(&t.id, &t.user, &t.entry, &t.to)
		return t, err
	})
	if err != nil {
		return 0, fmt.Errorf("banks: notify: %w", err)
	}
	sent := 0
	for _, t := range targets {
		if t.to != nil && *t.to != "" {
			var already bool
			if err := tx.QueryRow(ctx,
				`SELECT EXISTS (SELECT 1 FROM mail_log WHERE kind = 'bank_supported' AND recipient = $1
				                   AND bank_slug = $2 AND status <> 'failed')`, *t.to, slug).Scan(&already); err != nil {
				return 0, fmt.Errorf("banks: notify: %w", err)
			}
			if !already {
				audience := "account"
				lane := mailq.LaneBulk
				if t.user == nil {
					audience, lane = "waitlist", mailq.LaneWaitlist
				}
				s := slug
				if _, err := q.EnqueueTx(ctx, tx, mailq.Enqueue{Kind: "bank_supported", Lane: lane, To: *t.to,
					UserID: t.user, EntryID: t.entry, BankSlug: &s,
					Params: map[string]any{"audience": audience}}); err != nil {
					return 0, err
				}
				sent++
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE bank_requests SET notified_at = $2 WHERE id = $1`, t.id, now); err != nil {
			return 0, fmt.Errorf("banks: notify: %w", err)
		}
	}
	return sent, nil
}
