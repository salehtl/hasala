package api

import (
	"crypto/ed25519"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestRemovingTheReadingIPhoneUnlinksTheMailboxAndIgnoresItsNotices(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, g := withPushAndGmail(h)
	ledger := filepath.Join(t.TempDir(), "purged")
	h.srv.PurgeLedger = ledger
	h.srv.Writers.Record = h.srv.recordRestore
	k := h.onboard(true)
	reader := authtest.NewDevice(t)
	readerTok := k.enrol(reader)
	wantStatus(t, link(k, readerTok, fakeToken(goodClaims(linkChallenge(h, readerTok)))), http.StatusOK)
	if n := countIn(t, h, `SELECT count(*) FROM mailbox_links WHERE user_id = $1 AND holder_writer_id = $2`, k.user, reader.WriterID); n != 1 {
		t.Fatalf("%d links held by the reading iPhone, want 1", n)
	}
	pushToken := "Bearer " + fakeToken(fakeClaims{Aud: testAudience, Email: testSA, EmailVerified: true})
	notice := pubsubBody(t, testSub, map[string]any{"emailAddress": testMailbox, "historyId": 77})
	wantStatus(t, h.hook(pushToken, notice), http.StatusNoContent)
	if ws := wk.take(); len(ws) == 0 {
		t.Fatal("the linked mailbox's notice woke nobody")
	}

	su := k.stepUp(k.token, keyproto.ActionWriterRevoke, []byte(reader.WriterID))
	n := k.nonce(k.token)
	rm, _ := keyproto.RevocationMessage(n, reader.WriterID, 0, make([]byte, 32))
	wantStatus(t, h.req("POST", "/api/v1/writers/revoke", k.token, RevokeRequest{WriterID: reader.WriterID,
		SignerWriterID: k.device.WriterID, Nonce: b64(n), FinalCounter: "0", FinalHead: b64(make([]byte, 32)),
		Sig: b64(ed25519.Sign(k.device.DWK, rm)), StepUp: su}), http.StatusNoContent)
	if n := countIn(t, h, `SELECT count(*) FROM mailbox_links WHERE user_id = $1`, k.user); n != 0 {
		t.Fatal("the mailbox link outlived the iPhone that read it")
	}
	if n := countIn(t, h, `SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'mailbox_unlinked'`, k.user); n != 1 {
		t.Fatalf("%d mailbox_unlinked events, want 1", n)
	}
	wk.take()

	unknown := g.Push.Counters.Unknown.Load()
	wantStatus(t, h.hook(pushToken, notice), http.StatusNoContent)
	if ws := wk.take(); len(ws) != 0 {
		t.Fatalf("a notice for the removed link woke %+v", ws)
	}
	if g.Push.Counters.Unknown.Load() != unknown+1 {
		t.Fatal("the notice for the removed link was not a counted no-op")
	}
	if n := countIn(t, h, `SELECT count(*) FROM mailbox_links`); n != 0 {
		t.Fatal("the notice stored a link")
	}
	assertNoAddress(t, h, testMailbox)

	entries, err := purgeledger.Read(ledger)
	if err != nil || len(entries) != 1 || entries[0].Kind != purgeledger.KindDevice || entries[0].Device.WriterID != reader.WriterID {
		t.Fatalf("ledger %+v %v, want the device removal", entries, err)
	}
}

func countIn(t *testing.T, h *harness, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(bg, sql, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
