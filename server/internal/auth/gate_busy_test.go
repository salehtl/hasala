package auth

import (
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// busyGate is a PBKDF2 gate whose one slot is held and whose line is empty:
// every caller is refused at once until release runs.
func busyGate(t *testing.T) (*authkeys.Gate, func()) {
	t.Helper()
	g := authkeys.NewGate(1, 0, 10*time.Millisecond)
	release, err := g.Acquire(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(release)
	return g, release
}

// AT-AUTH-2, review should-fix 2: a busy gate answers 503 and leaves the
// signup unclaimed, so the retry succeeds with the same code.
func TestABusyGateLeavesThePasswordSignupUnclaimed(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	s := f.provenSignup(addr, "Maya")
	m := &member{f: f, addr: addr, pw: "a password of some length"}
	m.s = f.stretch(addr, m.pw)
	m.acct, m.device = authtest.NewAccount(t, s.UserID), authtest.NewDevice(t)
	b := f.passwordBootstrap(m, s)

	g, release := busyGate(t)
	f.acct.Gate = g
	hashes := f.keys.HashCount()
	if _, err := f.acct.PasswordSignup(bgctx, s.SignupID, m.s, b); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("a busy gate: %v", err)
	}
	if f.keys.HashCount() != hashes {
		t.Fatal("a refused signup ran a PBKDF2")
	}
	if f.count(`SELECT count(*) FROM signup_ceremonies WHERE id = $1 AND claimed_at IS NULL`, s.SignupID) != 1 {
		t.Fatal("a busy gate spent the signup")
	}
	release()
	if _, err := f.acct.PasswordSignup(bgctx, s.SignupID, m.s, b); err != nil {
		t.Fatalf("the retry: %v", err)
	}
	if f.count(`SELECT count(*) FROM signup_ceremonies WHERE id = $1 AND claimed_at IS NOT NULL`, s.SignupID) != 1 {
		t.Fatal("the signup was not claimed")
	}
}

// Review should-fix 3: a busy gate does not spend a verified C4 ceremony.
func TestABusyGateLeavesTheRecoveryCeremonyUnclaimed(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	rk := cryptoref.RK(m.acct.E)
	f.fake.Reset()
	b, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E))
	if err != nil {
		t.Fatal(err)
	}
	v, err := f.acct.RecoverVerify(bgctx, b.CeremonyID, f.lastCode(m.addr), "password")
	if err != nil {
		t.Fatal(err)
	}
	d := authtest.NewDevice(t)
	newS := f.stretch(m.addr, "recovered password here")
	msg, _ := keyproto.RecoverySigninPassword(v.Nonce, newS)
	req := RecoverFinishRequest{CeremonyID: b.CeremonyID, Kind: "password", Verifier: newS, RKSig: ed25519.Sign(rk, msg),
		Writer: Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
			Sig: m.acct.Registration(t, d, v.Nonce)}}

	g, release := busyGate(t)
	f.acct.Gate = g
	if _, err := f.acct.RecoverFinish(bgctx, req); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("a busy gate: %v", err)
	}
	if f.count(`SELECT count(*) FROM recovery_ceremonies WHERE id = $1 AND claimed_at IS NULL`, b.CeremonyID) != 1 {
		t.Fatal("a busy gate spent the recovery")
	}
	release()
	out, err := f.acct.RecoverFinish(bgctx, req)
	if err != nil {
		t.Fatalf("the retry: %v", err)
	}
	if out.WriterID != d.WriterID {
		t.Fatal("the recover session is not bound to the new writer")
	}
}

// Spec 02 §10.8 steps 4 and 5: the gate comes before the ceremony is spent,
// so a 503 leaves the password-login ceremony usable.
func TestABusyGateLeavesThePasswordLoginCeremonyUsable(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	b, err := f.acct.PasswordLoginBegin(bgctx, m.addr)
	if err != nil {
		t.Fatal(err)
	}
	g, release := busyGate(t)
	f.acct.Gate = g
	hashes := f.keys.HashCount()
	if _, err := f.acct.PasswordLoginFinish(bgctx, b.CeremonyID, m.s, nil); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("a busy gate: %v", err)
	}
	if f.keys.HashCount() != hashes {
		t.Fatal("a refused sign-in ran a PBKDF2")
	}
	release()
	if _, err := f.acct.PasswordLoginFinish(bgctx, b.CeremonyID, m.s, nil); err != nil {
		t.Fatalf("the retry on the same ceremony: %v", err)
	}
}
