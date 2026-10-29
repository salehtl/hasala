package auth

import (
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestOnlyTheOperatorLiftsAFreezeDatedToAPhraseRecovery(t *testing.T) {
	f := newAcctFixture(t)
	path, rec := ledgerRecorder(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)

	recovered := f.clock.now()
	id, v := f.verifiedRecovery(m, "password")
	newS := f.stretch(m.addr, "a recovered password")
	d := authtest.NewDevice(t)
	msg, _ := keyproto.RecoverySigninPassword(v.Nonce, newS)
	req := RecoverFinishRequest{CeremonyID: id, Kind: "password", Verifier: newS,
		RKSig: ed25519.Sign(cryptoref.RK(m.acct.E), msg),
		Writer: Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
			Sig: m.acct.Registration(t, d, v.Nonce)}}
	if _, err := f.acct.RecoverFinish(bgctx, req); err != nil {
		t.Fatal(err)
	}
	f.acct.Record = rec
	tok := f.freezeToken(m.addr)
	f.clock.advance(time.Minute)
	frozeAt := f.clock.now()
	if _, err := f.acct.FreezeByLink(bgctx, tok); err != nil {
		t.Fatal(err)
	}
	if f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_by = 'holder' AND freeze_trigger_at = $2`,
		m.user.UserID, recovered) != 1 {
		t.Fatal("the freeze link did not date the freeze to the recovery")
	}

	in, err := m.loginPassword(newS, d)
	if err != nil || !in.Restricted {
		t.Fatalf("a sign-in into the frozen account: %+v %v", in, err)
	}
	m.token, m.device, m.s = in.Session.Token, d, newS
	if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, newS)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("the holder's unfreeze with the factors of the recovery: %v", err)
	}
	if _, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E)); !errors.Is(err, ErrNoSuchAccount) {
		t.Fatalf("a recovery of the frozen account: %v", err)
	}
	if f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, m.user.UserID) != 1 {
		t.Fatal("the account is no longer frozen")
	}

	f.clock.advance(time.Minute)
	at := f.clock.now()
	tx, err := f.pool.Begin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	unfrozen, err := OperatorUnfreeze(bgctx, tx, m.user.UserID, ScopeAny, at, f.mailer)
	if err != nil || !unfrozen {
		_ = tx.Rollback(bgctx)
		t.Fatalf("the operator's unfreeze: %v %v", unfrozen, err)
	}
	if err := tx.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	rec(UnfreezeEntry(m.user.UserID, at))
	if f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NULL`, m.user.UserID) != 1 {
		t.Fatal("the operator's unfreeze left the account frozen")
	}
	if _, err := f.sessions.Resolve(bgctx, m.token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("the restricted session survived the operator's unfreeze: %v", err)
	}
	if _, err := m.loginPassword(newS, d); err != nil {
		t.Fatalf("a sign-in after the operator's unfreeze: %v", err)
	}

	entries := readLedger(t, path)
	if len(entries) != 2 || entries[0].Kind != purgeledger.KindFreeze || entries[1].Kind != purgeledger.KindUnfreeze ||
		entries[1].ID != m.user.UserID || !entries[1].At.Equal(at) {
		t.Fatalf("ledger %+v, want the freeze and the operator's unfreeze", entries)
	}
	if _, err := f.pool.Exec(bgctx,
		`UPDATE users SET frozen_at = $2, freeze_trigger_at = $3, frozen_by = 'holder', holder_also_froze = false WHERE id = $1`,
		m.user.UserID, frozeAt, recovered); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(bgctx, `DELETE FROM auth_events WHERE user_id = $1 AND kind = 'account_unfrozen'`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Freezes != 0 || rep.Unfreezes != 1 {
		t.Fatalf("reapply %+v %v, want the operator's unfreeze applied again", rep, err)
	}
	if f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NULL`, m.user.UserID) != 1 {
		t.Fatal("a restore brought back the freeze the operator lifted")
	}
	rep, err = Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Freezes != 0 || rep.Unfreezes != 0 {
		t.Fatalf("a second reapply %+v %v, want nothing", rep, err)
	}
}
