package invites

// email.go is the emailed invite (spec 07 §3.2, §4.4, §6.4.2): an invite in
// state queued gets its code and link key minted by the mail worker at send
// time, inside the render transaction, so neither is ever stored or logged;
// only their hashes are.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

// ErrNotApprovable is an entry that is not confirmed (or has no address).
var ErrNotApprovable = errors.New("invites: only a confirmed waitlist entry can be approved")

// EnqueueEmailed is `hasalad invite mint --email <address>` (spec 07 §14.3):
// a queued CLI invite and its invite email, both without email_tag (the CLI
// holds no auth key; the worker fills both tags). It returns the invite id;
// the code is minted at send and never shown to the operator.
func EnqueueEmailed(ctx context.Context, tx pgx.Tx, q *mailq.Queue, address, note string, ttl time.Duration) (uuid.UUID, error) {
	email, err := keyproto.EmailNorm(address)
	if err != nil {
		return uuid.Nil, fmt.Errorf("invites: %q is not an email address", address)
	}
	if err := CheckTTL(ttl); err != nil {
		return uuid.Nil, err
	}
	if err := CheckNote(note); err != nil {
		return uuid.Nil, err
	}
	var id uuid.UUID
	if err := tx.QueryRow(ctx,
		`INSERT INTO invite_codes (origin, state, note, ttl, created_at) VALUES ('cli', 'queued', $1, $2::interval, now())
		 RETURNING id`, nullable(note), pgInterval(ttl)).Scan(&id); err != nil {
		return uuid.Nil, fmt.Errorf("invites: queue: %w", err)
	}
	if _, err := q.EnqueueTx(ctx, tx, mailq.Enqueue{Kind: "invite", Lane: mailq.LaneTransactional, To: email,
		InviteID: &id}); err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

// ApproveEntry is the console's approve (C5, TestFlight by hand): a confirmed
// entry gets an admin invite addressed to its tag, queued for the worker, and
// moves to invited.
func ApproveEntry(ctx context.Context, tx pgx.Tx, q *mailq.Queue, entry uuid.UUID, note string, ttl time.Duration) (uuid.UUID, error) {
	if err := CheckTTL(ttl); err != nil {
		return uuid.Nil, err
	}
	if err := CheckNote(note); err != nil {
		return uuid.Nil, err
	}
	var (
		tag   []byte
		email *string
		state string
	)
	err := tx.QueryRow(ctx, `SELECT email_tag, email_norm, state FROM waitlist_entries WHERE id = $1 FOR UPDATE`, entry).
		Scan(&tag, &email, &state)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (state != "confirmed" || email == nil)) {
		return uuid.Nil, ErrNotApprovable
	}
	if err != nil {
		return uuid.Nil, err
	}
	var id uuid.UUID
	if err := tx.QueryRow(ctx,
		`INSERT INTO invite_codes (email_tag, waitlist_entry_id, origin, state, note, ttl, created_at)
		 VALUES ($1, $2, 'admin', 'queued', $3, $4::interval, now()) RETURNING id`,
		tag, entry, nullable(note), pgInterval(ttl)).Scan(&id); err != nil {
		return uuid.Nil, fmt.Errorf("invites: approve: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`UPDATE waitlist_entries SET state = 'invited', invited_at = now(), updated_at = now() WHERE id = $1`, entry); err != nil {
		return uuid.Nil, err
	}
	if _, err := q.EnqueueTx(ctx, tx, mailq.Enqueue{Kind: "invite", Lane: mailq.LaneTransactional, To: *email,
		Tag: tag, EntryID: &entry, InviteID: &id}); err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

// Renderer is the `invite` kind's renderer.
type Renderer struct {
	WebBase string
	// ManualTestFlight selects the email's "we'll add you ourselves" step:
	// true until the App Store Connect automation exists (spec 07 §7).
	ManualTestFlight bool
	Minter           Minter
}

type Minter interface {
	InviteSecrets(inviteID uuid.UUID, mailID int64) (code, link []byte)
}

var ErrAddressGone = errors.New("invites: the invite's email address is no longer kept; revoke it and mint a new invite")

// ErrStale is a queued invite email whose invite is no longer sendable, or
// that a newer email for the invite has replaced.
var ErrStale = errors.New("invites: the invite is closed")

// Render mints the code and link key, stores their hashes, and renders the
// email. A resend (an active invite) re-mints: the earlier code dies.
func (r Renderer) Render(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
	if row.InviteID == nil {
		return mail.Message{}, ErrStale
	}
	var (
		tag, codeHash, linkHash []byte
		entry                   *uuid.UUID
		state                   string
		expires                 *time.Time
	)
	err := tx.QueryRow(ctx,
		`SELECT email_tag, waitlist_entry_id, state, code_hash, link_key_hash, expires_at
		   FROM invite_codes WHERE id = $1 FOR UPDATE`, *row.InviteID).
		Scan(&tag, &entry, &state, &codeHash, &linkHash, &expires)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && state != "queued" && state != "active") {
		return mail.Message{}, ErrStale
	}
	if err != nil {
		return mail.Message{}, err
	}
	if len(tag) != 32 {
		return mail.Message{}, errors.New("invites: the invite has no email_tag yet")
	}
	var superseded bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM mail_log WHERE invite_id = $1 AND id > $2)`,
		*row.InviteID, row.ID).Scan(&superseded); err != nil {
		return mail.Message{}, err
	}
	if superseded {
		return mail.Message{}, ErrStale
	}
	code, linkKey, newLinkHash, err := r.secrets(*row.InviteID, row.ID)
	if err != nil {
		return mail.Message{}, err
	}
	reuse := r.Minter != nil && state == "active" && expires != nil &&
		bytes.Equal(codeHash, CodeHash(code)) && bytes.Equal(linkHash, newLinkHash)
	if !reuse {
		if err := tx.QueryRow(ctx,
			`UPDATE invite_codes SET state = 'active', code_hash = $2, link_key_hash = $3, minted_at = now(),
			        expires_at = now() + ttl, mint_count = mint_count + 1
			  WHERE id = $1 RETURNING expires_at`, *row.InviteID, CodeHash(code), newLinkHash).Scan(&expires); err != nil {
			return mail.Message{}, fmt.Errorf("invites: mint for email: %w", err)
		}
	}
	c := mailq.Content{Email: row.Recipient, Code: Display(code), InviteURL: Link(r.WebBase, code, linkKey),
		FallbackText: FallbackText(r.WebBase, code), Until: mailq.Date(*expires), ManualTestFlight: r.ManualTestFlight}
	var leave waitlist.Leave
	if entry != nil {
		var err error
		if leave, err = waitlist.LeaveLinks(ctx, tx, r.WebBase, *entry); err != nil {
			return mail.Message{}, err
		}
		c.LeaveURL = leave.Page
		c.Why = "You're getting this because " + row.Recipient + " is on the Hasala waitlist."
	} else {
		c.Why = "You're getting this because the Hasala team invited " + row.Recipient + "."
	}
	out, err := mailq.RenderTemplate("invite", c)
	if err != nil {
		return mail.Message{}, err
	}
	return mail.Message{To: row.Recipient, Subject: out.Subject, Text: out.Text, HTML: out.HTML,
		Unsubscribe: leave.OneClick}, nil
}

func (r Renderer) secrets(inviteID uuid.UUID, mailID int64) (code, linkKey string, linkHash []byte, err error) {
	if r.Minter == nil {
		if code, err = NewCode(); err != nil {
			return "", "", nil, err
		}
		_, linkKey, linkHash, err = NewLinkKey()
		return code, linkKey, linkHash, err
	}
	rawCode, rawLink := r.Minter.InviteSecrets(inviteID, mailID)
	if len(rawCode) != codeBytes || len(rawLink) != LinkKeyBytes {
		return "", "", nil, errors.New("invites: the minter returned the wrong sizes")
	}
	sum := sha256.Sum256(rawLink)
	return alphabet.EncodeToString(rawCode), base64.RawURLEncoding.EncodeToString(rawLink), sum[:], nil
}

// Resend re-queues an active or queued invite's email (C9): the worker
// re-mints, so the code the person had stops working.
func Resend(ctx context.Context, tx pgx.Tx, q *mailq.Queue, id uuid.UUID) error {
	var (
		entry *uuid.UUID
		tag   []byte
		state string
		to    *string
	)
	err := tx.QueryRow(ctx,
		`SELECT i.waitlist_entry_id, i.email_tag, i.state,
		        coalesce(e.email_norm, (SELECT recipient FROM mail_log m WHERE m.invite_id = i.id AND m.recipient IS NOT NULL
		                                ORDER BY m.id DESC LIMIT 1))
		   FROM invite_codes i LEFT JOIN waitlist_entries e ON e.id = i.waitlist_entry_id
		  WHERE i.id = $1 FOR UPDATE OF i`, id).Scan(&entry, &tag, &state, &to)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && state != "active" && state != "queued") {
		return ErrNoSuchInvite
	}
	if err != nil {
		return err
	}
	if to == nil {
		return ErrAddressGone
	}
	_, err = q.EnqueueTx(ctx, tx, mailq.Enqueue{Kind: "invite", Lane: mailq.LaneTransactional, To: *to, Tag: tag,
		EntryID: entry, InviteID: &id})
	return err
}

// ShortID is an invite id's first 8 hex characters, as `invite list` shows it.
func ShortID(id uuid.UUID) string { return strings.ReplaceAll(id.String(), "-", "")[:8] }
