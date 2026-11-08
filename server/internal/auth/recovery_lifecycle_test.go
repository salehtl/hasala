package auth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
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

const injectFailure = `CREATE FUNCTION injected_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected'; END $$;`

func TestAServerFaultAfterTheClaimHandsTheRecoveryBack(t *testing.T) {
	for _, c := range []struct {
		name, kind, breakIt, fixIt string
	}{
		{"reading the account", "password",
			`ALTER TABLE users RENAME COLUMN display_name TO display_name_gone`,
			`ALTER TABLE users RENAME COLUMN display_name_gone TO display_name`},
		{"reading the keys", "password",
			`ALTER TABLE account_keys RENAME COLUMN authority_pubkey TO authority_pubkey_gone`,
			`ALTER TABLE account_keys RENAME COLUMN authority_pubkey_gone TO authority_pubkey`},
		{"reading the passkey handle", "passkey",
			`ALTER TABLE users RENAME COLUMN user_handle TO user_handle_gone`,
			`ALTER TABLE users RENAME COLUMN user_handle_gone TO user_handle`},
		{"storing the passkey", "passkey",
			injectFailure + `CREATE TRIGGER injected BEFORE INSERT ON webauthn_credentials FOR EACH ROW EXECUTE FUNCTION injected_failure();`,
			`DROP TRIGGER injected ON webauthn_credentials`},
		{"storing the device", "password",
			injectFailure + `CREATE TRIGGER injected BEFORE INSERT ON writers FOR EACH ROW EXECUTE FUNCTION injected_failure();`,
			`DROP TRIGGER injected ON writers`},
		{"the commit", "password",
			injectFailure + `CREATE CONSTRAINT TRIGGER injected AFTER INSERT ON writers DEFERRABLE INITIALLY DEFERRED
			   FOR EACH ROW EXECUTE FUNCTION injected_failure();`,
			`DROP TRIGGER injected ON writers`},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newAcctFixture(t)
			m := f.passwordMember("Maya")
			id, v := f.verifiedRecovery(m, c.kind)
			var req RecoverFinishRequest
			if c.kind == "passkey" {
				req, _ = f.passkeyRecoveryRequest(m, id, v)
			} else {
				req = f.passwordRecoveryRequest(m, id, v, f.stretch(m.addr, "a recovered password"))
			}
			if _, err := f.owner.Exec(bgctx, c.breakIt); err != nil {
				t.Fatal(err)
			}
			if _, err := f.acct.RecoverFinish(bgctx, req); err == nil || errors.Is(err, ErrRecoveryRefused) {
				t.Fatalf("a server fault: %v, want an error that is not a refusal", err)
			}
			if f.count(`SELECT count(*) FROM recovery_ceremonies WHERE id = $1 AND claimed_at IS NULL`, id) != 1 {
				t.Fatal("a server fault spent the recovery")
			}
			if _, err := f.owner.Exec(bgctx, c.fixIt); err != nil {
				t.Fatal(err)
			}
			if _, err := f.acct.RecoverFinish(bgctx, req); err != nil {
				t.Fatalf("the retry: %v", err)
			}
		})
	}
}

func TestALockTimeoutOnTheAccountHandsTheRecoveryBack(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id, v := f.verifiedRecovery(m, "password")
	req := f.passwordRecoveryRequest(m, id, v, f.stretch(m.addr, "a recovered password"))

	cfg := f.pool.Config()
	cfg.ConnConfig.RuntimeParams["lock_timeout"] = "100ms"
	impatient, err := pgxpool.NewWithConfig(bgctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(impatient.Close)
	f.acct.Pool = impatient

	holder, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, holder)
	if _, err := holder.Exec(bgctx, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.RecoverFinish(bgctx, req); err == nil || errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a lock timeout: %v, want an error that is not a refusal", err)
	}
	if f.count(`SELECT count(*) FROM recovery_ceremonies WHERE id = $1 AND claimed_at IS NULL`, id) != 1 {
		t.Fatal("a lock timeout spent the recovery")
	}
	pgtx.Rollback(bgctx, holder)
	if _, err := f.acct.RecoverFinish(bgctx, req); err != nil {
		t.Fatalf("the retry: %v", err)
	}
}

func TestACancelledRequestHandsTheRecoveryBack(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id, v := f.verifiedRecovery(m, "password")
	req := f.passwordRecoveryRequest(m, id, v, f.stretch(m.addr, "a recovered password"))

	gate := authkeys.NewGate(1, 1, time.Minute)
	free, err := gate.Acquire(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(free)
	f.acct.Gate = gate
	ctx, cancel := context.WithCancel(bgctx)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := f.acct.RecoverFinish(ctx, req)
		done <- err
	}()
	deadline := time.Now().Add(10 * time.Second)
	for f.count(`SELECT count(*) FROM recovery_ceremonies WHERE id = $1 AND claimed_at IS NOT NULL`, id) != 1 {
		if time.Now().After(deadline) {
			t.Fatal("the recovery never claimed its ceremony")
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	if err := <-done; err == nil || errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a cancelled request: %v, want an error that is not a refusal", err)
	}
	if f.count(`SELECT count(*) FROM recovery_ceremonies WHERE id = $1 AND claimed_at IS NULL`, id) != 1 {
		t.Fatal("a cancelled request spent the recovery")
	}
	free()
	if _, err := f.acct.RecoverFinish(bgctx, req); err != nil {
		t.Fatalf("the retry: %v", err)
	}
}

func TestARecoveryRefusedForItsOwnDeviceStaysSpent(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id, v := f.verifiedRecovery(m, "password")
	req := f.passwordRecoveryRequest(m, id, v, f.stretch(m.addr, "a recovered password"))
	req.Writer = Registration{WriterID: m.device.WriterID, Alg: AlgEd25519, PubKey: m.device.DWKPub(), DAKPubkey: m.device.DAKPub(),
		Sig: m.acct.Registration(t, m.device, v.Nonce)}
	if _, err := f.acct.RecoverFinish(bgctx, req); !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a device already enrolled: %v", err)
	}
	if f.count(`SELECT count(*) FROM recovery_ceremonies WHERE id = $1 AND claimed_at IS NOT NULL`, id) != 1 {
		t.Fatal("a refused attempt handed the recovery back")
	}
}
