package auth

import (
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/banks"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

func TestAnAccountMovingIntoAnAddressJoinsItsWaitlistEntry(t *testing.T) {
	for _, state := range []string{"pending", "confirmed", "invited"} {
		t.Run(state, func(t *testing.T) {
			f := newAcctFixture(t)
			m := f.passwordMember("Maya")
			next := newAddr()
			tag := f.acct.Keys.EmailTag(next)
			var entry uuid.UUID
			if err := f.pool.QueryRow(bgctx, `INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, source,
				created_at, updated_at, confirmed_at, invited_at)
				VALUES ($1, $2, $3::text, 'fab', 'web', now(), now(),
				        CASE WHEN $3::text = 'pending' THEN NULL ELSE now() END,
				        CASE WHEN $3::text = 'invited' THEN now() END) RETURNING id`, tag, next, state).Scan(&entry); err != nil {
				t.Fatal(err)
			}
			if _, err := f.pool.Exec(bgctx, `INSERT INTO bank_requests (bank_slug, source, waitlist_entry_id, created_at)
				VALUES ('fab', 'web_waitlist', $1, now())`, entry); err != nil {
				t.Fatal(err)
			}
			var invite uuid.UUID
			if err := f.pool.QueryRow(bgctx, `INSERT INTO invite_codes (email_tag, waitlist_entry_id, origin, state, created_at)
				VALUES ($1, $2, 'admin', 'queued', now()) RETURNING id`, tag, entry).Scan(&invite); err != nil {
				t.Fatal(err)
			}
			entryState := func() (string, *string) {
				t.Helper()
				var (
					got  string
					addr *string
				)
				if err := f.pool.QueryRow(bgctx, `SELECT state, email_norm FROM waitlist_entries WHERE id = $1`, entry).
					Scan(&got, &addr); err != nil {
					t.Fatal(err)
				}
				return got, addr
			}

			sNew := f.stretch(next, m.pw)
			su := m.deviceStepUp(keyproto.ActionEmailChange, m.s, sha([]byte(next)), sumBytes(sNew))
			begun, err := f.acct.EmailChangeBegin(bgctx, m.info(), next, sNew, su)
			if err != nil {
				t.Fatal(err)
			}
			oldCode, newCode := f.lastCode(m.addr), f.lastCode(next)
			wrong := "000000"
			if newCode == wrong {
				wrong = "111111"
			}
			if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, wrong, &oldCode, nil); !errors.Is(err, ErrCodeRejected) {
				t.Fatalf("a wrong code: %v", err)
			}
			if got, addr := entryState(); got != state || addr == nil {
				t.Fatalf("after a refused change the entry is %s %v, want it unchanged", got, addr)
			}
			if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, newCode, &oldCode, nil); err != nil {
				t.Fatal(err)
			}

			if got, addr := entryState(); got != "joined" || addr != nil {
				t.Fatalf("the entry is %s %v, want joined with no address", got, addr)
			}
			var inviteState string
			if err := f.pool.QueryRow(bgctx, `SELECT state FROM invite_codes WHERE id = $1`, invite).Scan(&inviteState); err != nil || inviteState != "revoked" {
				t.Fatalf("the entry's invite is %q (%v), want revoked", inviteState, err)
			}
			var moved int
			if err := f.pool.QueryRow(bgctx, `SELECT count(*) FROM bank_requests WHERE user_id = $1 AND bank_slug = 'fab' AND waitlist_entry_id IS NULL`,
				m.user.UserID).Scan(&moved); err != nil || moved != 1 {
				t.Fatalf("%d bank requests moved to the account (%v), want 1", moved, err)
			}
			s := waitlist.New(f.pool, f.acct.Keys, "https://hasala.app")
			if got, err := s.Submit(bgctx, next, banks.Choice{Slug: "fab"}); err != nil || got != "joined" {
				t.Fatalf("a new submission of the address: %q %v, want the account's answer", got, err)
			}
		})
	}
}
