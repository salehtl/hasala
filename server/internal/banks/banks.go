// Package banks is the bank catalog and bank requests (spec 07 §2.2, §2.6,
// §4.3, §5.6): normalizing a typed bank name without a Unicode library, mapping
// it onto the catalog, and counting requests.
package banks

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ErrBadBank is a bank or otherBank that fails spec 07 §4.3.
var ErrBadBank = errors.New("banks: not a bank name")

// ErrListFull is a new free-text name when 1,000 distinct ones exist.
var ErrListFull = errors.New("banks: the list of other bank names is full")

// MaxOtherKeys bounds the distinct free-text names (spec 07 §5.6).
const MaxOtherKeys = 1000

// Querier is a pool or a transaction.
type Querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// Text is bank_text(x): trimmed, whitespace collapsed, 1–64 runes, each a
// letter, mark, decimal digit, space or one of & . ' - ( ) /.
func Text(x string) (string, error) {
	fields := strings.Fields(x)
	s := strings.Join(fields, " ")
	n := 0
	for _, r := range s {
		n++
		switch {
		case unicode.IsLetter(r), unicode.IsMark(r), unicode.Is(unicode.Nd, r), r == ' ':
		case strings.ContainsRune("&.'-()/", r):
		default:
			return "", ErrBadBank
		}
	}
	if n < 1 || n > 64 {
		return "", ErrBadBank
	}
	return s, nil
}

// Key is bank_key(x): bank_text lowered, the punctuation . ' - ( ) / turned
// into spaces, spaces collapsed.
func Key(x string) (string, error) {
	t, err := Text(x)
	if err != nil {
		return "", err
	}
	t = strings.ToLower(t)
	t = strings.Map(func(r rune) rune {
		if strings.ContainsRune(".'-()/", r) {
			return ' '
		}
		return r
	}, t)
	k := strings.Join(strings.Fields(t), " ")
	if k == "" {
		return "", ErrBadBank
	}
	return k, nil
}

// Choice is a resolved bank: a catalog slug, or a free-text name and its key,
// or neither ("Another bank", no name given).
type Choice struct {
	Slug      string
	OtherText string
	OtherKey  string
	Supported bool
	Name      string // the catalog name, for emails
}

// Catalog reports whether slug is a catalog bank and its name and status.
func Catalog(ctx context.Context, q Querier, slug string) (name string, supported, ok bool, err error) {
	var status string
	err = q.QueryRow(ctx, `SELECT name, status FROM banks WHERE slug = $1`, slug).Scan(&name, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, false, nil
	}
	if err != nil {
		return "", false, false, err
	}
	return name, status == "supported", true, nil
}

// Resolve applies spec 07 §4.3 to the form's bank and otherBank: a catalog
// slug, or "other" with an optional name that may itself resolve onto the
// catalog through a slug or an alias.
func Resolve(ctx context.Context, q Querier, bank, otherBank string) (Choice, error) {
	if bank != "other" {
		if otherBank != "" {
			return Choice{}, ErrBadBank
		}
		name, sup, ok, err := Catalog(ctx, q, bank)
		if err != nil {
			return Choice{}, err
		}
		if !ok {
			return Choice{}, ErrBadBank
		}
		return Choice{Slug: bank, Supported: sup, Name: name}, nil
	}
	if otherBank == "" {
		return Choice{Name: "Another bank"}, nil
	}
	text, err := Text(otherBank)
	if err != nil {
		return Choice{}, err
	}
	key, err := Key(otherBank)
	if err != nil {
		return Choice{}, err
	}
	var (
		slug, name, status string
	)
	err = q.QueryRow(ctx, `SELECT slug, name, status FROM banks WHERE slug = $1 OR $1 = ANY(aliases) LIMIT 1`, key).
		Scan(&slug, &name, &status)
	if err == nil {
		return Choice{Slug: slug, Supported: status == "supported", Name: name}, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Choice{}, err
	}
	return Choice{OtherText: text, OtherKey: key, Name: "Another bank"}, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// Record counts one P4 request: anonymous (source web, userID nil) or from a
// signed-in account (source app, once per bank per account). A supported
// catalog bank is not stored. A new free-text key past MaxOtherKeys is
// ErrListFull.
func Record(ctx context.Context, q Querier, c Choice, userID *uuid.UUID, senderDomain string, now time.Time) error {
	if c.Slug == "" && c.OtherKey == "" {
		return ErrBadBank // a vote needs a name
	}
	if senderDomain != "" && userID == nil {
		return ErrBadDomain
	}
	if c.Supported {
		return nil
	}
	if c.OtherKey != "" {
		var known bool
		var distinct int
		if err := q.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM bank_requests WHERE other_key = $1),
			        (SELECT count(DISTINCT other_key) FROM bank_requests WHERE other_key IS NOT NULL)`,
			c.OtherKey).Scan(&known, &distinct); err != nil {
			return fmt.Errorf("banks: count names: %w", err)
		}
		if !known && distinct >= MaxOtherKeys {
			return ErrListFull
		}
	}
	source := "web"
	if userID != nil {
		source = "app"
	}
	conflict := `ON CONFLICT DO NOTHING`
	if senderDomain != "" {
		conflict = `ON CONFLICT (user_id, (coalesce(bank_slug, 'other:' || other_key))) WHERE user_id IS NOT NULL
		 DO UPDATE SET sender_domain = coalesce(bank_requests.sender_domain, EXCLUDED.sender_domain)`
	}
	_, err := q.Exec(ctx,
		`INSERT INTO bank_requests (bank_slug, other_key, other_text, source, user_id, sender_domain, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7) `+conflict,
		nullable(c.Slug), nullable(c.OtherKey), nullable(c.OtherText), source, userID, nullable(senderDomain), now)
	if err != nil {
		return fmt.Errorf("banks: record: %w", err)
	}
	return nil
}
