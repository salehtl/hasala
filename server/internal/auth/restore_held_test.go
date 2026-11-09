package auth

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func stoppedBeforeAppend(purgeledger.Entry) {}

func heldLines(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM restore_ledger_held`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func flushed(t *testing.T, pool *pgxpool.Pool) []purgeledger.Entry {
	t.Helper()
	path := filepath.Join(t.TempDir(), "purged")
	if _, err := purgeledger.Flush(bgctx, pool, path); err != nil {
		t.Fatal(err)
	}
	return readLedger(t, path)
}

func TestAFreezeSurvivesAStopBetweenItsCommitAndItsLine(t *testing.T) {
	f := newAcctFixture(t)
	f.acct.Hold, f.acct.Record = purgeledger.HoldTx, stoppedBeforeAppend
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	frozeAt := f.clock.now()
	if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); err != nil {
		t.Fatal(err)
	}

	entries := flushed(t, f.pool)
	if len(entries) != 1 || entries[0].Kind != purgeledger.KindFreeze || entries[0].ID != m.user.UserID ||
		!entries[0].At.Equal(frozeAt.Truncate(time.Second)) {
		t.Fatalf("ledger after the restart %+v, want the freeze", entries)
	}
	if n := heldLines(t, f.pool); n != 0 {
		t.Fatalf("%d lines still held", n)
	}

	if _, err := f.pool.Exec(bgctx, `UPDATE users SET frozen_at = NULL, freeze_trigger_at = NULL, frozen_by = NULL WHERE id = $1`,
		m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Freezes != 1 {
		t.Fatalf("reapply %+v %v, want the freeze applied again", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, m.user.UserID); n != 1 {
		t.Fatal("a restore undid the freeze")
	}
}

func TestEachAccountChangeHoldsItsLineWithTheChange(t *testing.T) {
	f := newAcctFixture(t)
	f.acct.Hold, f.acct.Record = purgeledger.HoldTx, stoppedBeforeAppend
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)

	newS := f.stretch(m.addr, "a different long password")
	if _, err := f.acct.ChangePassword(bgctx, m.info(), newS, m.deviceStepUp(keyproto.ActionPasswordChange, m.s, sumBytes(newS))); err != nil {
		t.Fatal(err)
	}
	m.s = newS
	f.clock.advance(time.Hour)
	if _, err := f.acct.LogoutAll(bgctx, m.info(), m.deviceStepUp(keyproto.ActionSessionLogoutAll, m.s)); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	nonce, _, err := f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
	if err != nil {
		t.Fatal(err)
	}
	msg, _ := keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
	if _, err := f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, m.device.SignDAK(t, msg), nil); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	in, err := m.loginPassword(m.s, m.device)
	if err != nil {
		t.Fatal(err)
	}
	m.token = in.Session.Token
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET password_set_at = $2 WHERE id = $1`, m.user.UserID, f.clock.now().Add(-4*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); err != nil {
		t.Fatal(err)
	}

	entries := flushed(t, f.pool)
	var kinds []purgeledger.Kind
	for _, e := range entries {
		kinds = append(kinds, e.Kind)
	}
	want := []purgeledger.Kind{purgeledger.KindPassword, purgeledger.KindSessions, purgeledger.KindFreeze, purgeledger.KindUnfreeze}
	if len(kinds) != len(want) {
		t.Fatalf("ledger kinds %v, want %v", kinds, want)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Fatalf("ledger kinds %v, want %v", kinds, want)
		}
	}
}

func TestAPasskeyRemovalHoldsItsLine(t *testing.T) {
	f := newKeyFixture(t).guarded()
	f.passkeys.Hold, f.passkeys.Record = purgeledger.HoldTx, stoppedBeforeAppend
	second, _, err := f.addOver(f.token, f.device, true)
	if err != nil {
		t.Fatal(err)
	}
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyDelete, second.CredID)
	if _, err := f.passkeys.DeletePasskey(bgctx, f.info(f.token), second.CredID, su); err != nil {
		t.Fatal(err)
	}
	if entries := flushed(t, f.pool); len(entries) != 1 || entries[0].Kind != purgeledger.KindPasskey || entries[0].ID != f.user {
		t.Fatalf("ledger %+v, want the passkey removal", entries)
	}
}

func TestADeviceRemovalHoldsItsLine(t *testing.T) {
	f := newKeyFixture(t)
	f.writers.Hold, f.writers.Record = purgeledger.HoldTx, stoppedBeforeAppend
	other := authtest.NewDevice(t)
	f.enrol(other)
	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	if _, err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, make([]byte, 32), su)); err != nil {
		t.Fatal(err)
	}
	if entries := flushed(t, f.pool); len(entries) != 1 || entries[0].Kind != purgeledger.KindDevice || entries[0].Device.WriterID != other.WriterID {
		t.Fatalf("ledger %+v, want the device removal", entries)
	}
}

func TestAFailedRevocationHoldsNoLine(t *testing.T) {
	f := newKeyFixture(t)
	f.writers.Hold, f.writers.Record = purgeledger.HoldTx, stoppedBeforeAppend
	other := authtest.NewDevice(t)
	f.enrol(other)
	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	if _, err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 3, make([]byte, 32), su)); !errors.Is(err, ErrHeadMoved) {
		t.Fatalf("a wrong head: %v", err)
	}
	if n := heldLines(t, f.pool); n != 0 {
		t.Fatalf("a refused revocation held %d lines", n)
	}
}

func TestAChangeThatCannotHoldItsLineDoesNotCommit(t *testing.T) {
	f := newAcctFixture(t)
	refused := errors.New("the outbox refused")
	f.acct.Hold = func(context.Context, pgx.Tx, purgeledger.Entry) error { return refused }
	m := f.passwordMember("Maya")
	if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); !errors.Is(err, refused) {
		t.Fatalf("a freeze whose line could not be held: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, m.user.UserID); n != 0 {
		t.Fatal("the freeze committed with no line")
	}
}

func TestALineWrittenTwiceDoesNotChangeTheReplay(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	frozeAt := f.clock.now().Truncate(time.Second)
	f.clock.advance(time.Hour)
	unfrozeAt := f.clock.now().Truncate(time.Second)
	freeze := freezeEntry(m.user.UserID, frozeAt, frozeAt)
	entries := []purgeledger.Entry{freeze, UnfreezeEntry(m.user.UserID, unfrozeAt), freeze}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Freezes != 0 {
		t.Fatalf("reapply %+v %v, want no freeze applied", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, m.user.UserID); n != 0 {
		t.Fatal("a freeze line written again after its unfreeze froze the account")
	}

	other := f.passwordMember("Pat")
	twice := freezeEntry(other.user.UserID, frozeAt, frozeAt)
	if rep, err := Reapply(bgctx, f.pool, []purgeledger.Entry{twice, twice}, f.clock.now()); err != nil || rep.Freezes != 1 {
		t.Fatalf("reapply %+v %v, want the freeze applied once", rep, err)
	}
}
