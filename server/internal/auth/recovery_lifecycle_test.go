package auth

import (
	"errors"
	"testing"

	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

func TestAFinishedRecoveryEndsEveryOtherRecoveryCeremony(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	firstID, firstV := f.verifiedRecovery(m, "passkey")
	secondID, secondV := f.verifiedRecovery(m, "password")
	if _, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E)); err != nil {
		t.Fatal(err)
	}
	first, fresh := f.passkeyRecoveryRequest(m, firstID, firstV)
	out, err := f.acct.RecoverFinish(bgctx, first)
	if err != nil {
		t.Fatal(err)
	}
	second := f.passwordRecoveryRequest(m, secondID, secondV, f.stretch(m.addr, "a second recovered password"))
	if _, err := f.acct.RecoverFinish(bgctx, second); !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a second recovery after the first finished: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, out.Session.Token); err != nil {
		t.Fatalf("the first recovery's session: %v", err)
	}
	if f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`, m.user.UserID, fresh.CredID) != 1 {
		t.Fatal("the first recovery's passkey is gone")
	}
	if f.count(`SELECT count(*) FROM users WHERE id = $1 AND password_hash IS NULL`, m.user.UserID) != 1 {
		t.Fatal("the second recovery set a password")
	}
	if n := f.count(`SELECT count(*) FROM recovery_ceremonies WHERE user_id = $1`, m.user.UserID); n != 0 {
		t.Fatalf("%d recovery ceremonies survived a finished recovery", n)
	}
}

func TestARecoveryEndedWhileItWaitedForTheAccountIsRefused(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id, v := f.verifiedRecovery(m, "password")
	req := f.passwordRecoveryRequest(m, id, v, f.stretch(m.addr, "a recovered password"))

	holder, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, holder)
	if _, err := holder.Exec(bgctx, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := f.acct.RecoverFinish(bgctx, req)
		done <- err
	}()
	waitForLockWait(t, f.count)
	if _, err := holder.Exec(bgctx, `DELETE FROM recovery_ceremonies WHERE user_id = $1`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if err := holder.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a recovery another one ended: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM sessions WHERE user_id = $1 AND minted_by = 'recover'`, m.user.UserID); n != 0 {
		t.Fatalf("%d recovery sessions minted for an ended ceremony", n)
	}
	if n := f.count(`SELECT count(*) FROM writers WHERE user_id = $1 AND writer_id = $2`, m.user.UserID, req.Writer.WriterID); n != 0 {
		t.Fatal("an ended ceremony registered a device")
	}
}
