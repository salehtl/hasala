package api

import (
	"errors"
	"net/http"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

func linkGmailAddress(k *keyed, address string) *http.Response {
	k.h.t.Helper()
	c := goodClaims(linkChallenge(k.h, k.token))
	c.Email = address
	return link(k, k.token, fakeToken(c)).Result()
}

func linkCount(t *testing.T, h *harness, k *keyed) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM mailbox_links WHERE user_id = $1`, k.user).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestAMailboxBelongsToOneAccount(t *testing.T) {
	h := newHarness(t).passkeys()
	_, g := withGmail(h, nil)
	a, b := h.onboard(true), h.onboard(true)

	if r := linkGmailAddress(a, testMailbox); r.StatusCode != http.StatusOK {
		t.Fatalf("first link: %d", r.StatusCode)
	}
	for _, variant := range []string{testMailbox, "  someone.else@gmail.com "} {
		c := goodClaims(linkChallenge(h, b.token))
		c.Email = variant
		w := link(b, b.token, fakeToken(c))
		if w.Code != http.StatusConflict || decodeJSON[errorBody](t, w).Error != "mailbox_in_use" {
			t.Fatalf("second account, %q: %d %s", variant, w.Code, w.Body)
		}
	}
	if linkCount(t, h, b) != 0 {
		t.Fatal("the refused account holds a link")
	}
	var events int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'mailbox_linked'`,
		b.user).Scan(&events); err != nil || events != 0 {
		t.Fatalf("a refused link recorded %d mailbox_linked events, %v", events, err)
	}
	var holder string
	if err := h.pool.QueryRow(bg, `SELECT holder_writer_id FROM mailbox_links WHERE address_hmac = $1`,
		g.RouteKey.AddressHMAC(testMailbox)).Scan(&holder); err != nil || holder != a.device.WriterID {
		t.Fatalf("the first account lost its link: %q, %v", holder, err)
	}
	assertNoAddress(t, h, testMailbox)

	if r := linkGmailAddress(a, testMailbox); r.StatusCode != http.StatusOK {
		t.Fatalf("the same account linking its own mailbox again: %d", r.StatusCode)
	}
	if r := linkGmailAddress(b, "another.mailbox@gmail.com"); r.StatusCode != http.StatusOK {
		t.Fatalf("the second account's own mailbox: %d", r.StatusCode)
	}

	wantStatus(t, h.req("DELETE", "/api/v1/mailbox/link", a.token,
		UnlinkRequest{StepUp: a.stepUp(a.token, keyproto.ActionMailboxUnlink)}), http.StatusNoContent)
	if r := linkGmailAddress(b, testMailbox); r.StatusCode != http.StatusOK {
		t.Fatalf("after the first account unlinked: %d", r.StatusCode)
	}
	if linkCount(t, h, b) != 1 {
		t.Fatal("the second account holds more than one link")
	}
	if r := linkGmailAddress(a, testMailbox); r.StatusCode != http.StatusConflict {
		t.Fatalf("the first account taking it back: %d", r.StatusCode)
	}
}

func TestTheMailboxIndexRefusesASecondAccount(t *testing.T) {
	h := newHarness(t).passkeys()
	_, g := withGmail(h, nil)
	a, b := h.onboard(true), h.onboard(true)
	insert := func(k *keyed) error {
		_, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id,
		    holder_writer_id, created_at, updated_at) VALUES ($1, 'gmail', $2, $3, $4, now(), now())`,
			k.user, g.RouteKey.AddressHMAC(testMailbox), g.RouteKey.KeyID(), k.device.WriterID)
		return err
	}
	if err := insert(a); err != nil {
		t.Fatal(err)
	}
	var pgErr *pgconn.PgError
	if err := insert(b); !errors.As(err, &pgErr) || pgErr.ConstraintName != "mailbox_links_one_account_per_mailbox" {
		t.Fatalf("a second account's row: %v", err)
	}
}

func TestOneAddressOnTwoProvidersIsTwoMailboxes(t *testing.T) {
	h := newHarness(t).passkeys()
	withGmail(h, nil)
	withOutlook(h, nil)
	a, b := h.onboard(true), h.onboard(true)
	if r := linkGmailAddress(a, testOutlookMailbox); r.StatusCode != http.StatusOK {
		t.Fatalf("gmail: %d", r.StatusCode)
	}
	c := goodMSClaims(linkChallenge(h, b.token))
	wantStatus(t, linkAs(b, b.token, "outlook", fakeMSToken(c)), http.StatusOK)
}
