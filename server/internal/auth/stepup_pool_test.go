package auth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

// A guarded request holds one connection for its whole step-up: StepUp.Run's
// transaction locks the nonce row, and everything the proof and the action
// read or write goes through that transaction. If any of it went to the pool
// instead, N concurrent guarded requests on an N-connection pool would each
// hold one connection and wait for a second, for ever. On a one-connection
// pool that wait is immediate, so this test is the deadlock's detector: a
// passkey step-up (the credential lookup, the handle check and the counter
// update) and passkey.add's begin (the account's credentials and the
// ceremony row) must both complete with a single connection.
func TestAGuardedRequestNeedsOneConnection(t *testing.T) {
	f := newKeyFixture(t)
	one := onePool(t, f.pool)
	pk := newPasskeys(t, one)
	pk.Now = f.clock.now
	su := &StepUp{Pool: one, Passkeys: pk, Now: f.clock.now}
	pk.StepUp = su

	ctx, cancel := context.WithTimeout(bgctx, 10*time.Second)
	defer cancel()
	info := f.info(f.token)

	// A passkey-proved step-up whose action uses only its transaction.
	ph, _ := keyproto.ParamsHash(keyproto.ActionSessionLogoutAll)
	g := Guarded{UserID: f.user, SessionHash: info.Hash, BoundWriter: info.WriterID,
		Action: keyproto.ActionSessionLogoutAll, ParamsHash: ph,
		StepUp: f.stepUpPasskey(f.token, keyproto.ActionSessionLogoutAll)}
	ran := false
	if err := su.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		ran = len(p.CredentialID) > 0
		_, err := tx.Exec(ctx, `SELECT 1`)
		return err
	}); err != nil {
		t.Fatalf("a passkey step-up on a one-connection pool: %v (a read or write left its transaction)", err)
	}
	if !ran {
		t.Fatal("the action did not run with the asserting credential")
	}
	var used bool
	if err := f.pool.QueryRow(bgctx, `SELECT used_at IS NOT NULL FROM step_up_challenges WHERE nonce = $1`,
		g.StepUp.Nonce).Scan(&used); err != nil || !used {
		t.Fatalf("the nonce was not spent: %v %v", used, err)
	}

	// passkey.add's begin, inside its own step-up.
	id, opts, err := pk.AddBegin(ctx, info, f.stepUpPasskey(f.token, keyproto.ActionPasskeyAdd))
	if err != nil || id == "" || opts == nil {
		t.Fatalf("passkey.add begin on a one-connection pool: %q %v", id, err)
	}
	if n := len(opts.Response.CredentialExcludeList); n != 1 {
		t.Fatalf("the add ceremony excludes %d credentials, want the account's one", n)
	}
}

func onePool(t *testing.T, pool *pgxpool.Pool) *pgxpool.Pool {
	t.Helper()
	cfg := pool.Config().Copy()
	cfg.MaxConns, cfg.MinConns = 1, 0
	one, err := pgxpool.NewWithConfig(bgctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(one.Close)
	return one
}

func TestADeviceGuardedRequestNeedsOneConnection(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	one := onePool(t, f.pool)
	su := &StepUp{Pool: one, Keys: f.keys, Now: f.clock.now}
	ctx, cancel := context.WithTimeout(bgctx, 10*time.Second)
	defer cancel()
	ph, _ := keyproto.ParamsHash(keyproto.ActionSessionLogoutAll)
	guarded := func(o *StepUpObject) Guarded {
		i := m.info()
		return Guarded{UserID: i.UserID, SessionHash: i.Hash, BoundWriter: i.WriterID,
			Action: keyproto.ActionSessionLogoutAll, ParamsHash: ph, StepUp: o}
	}
	inTx := func(ctx context.Context, tx pgx.Tx, p Proven) error {
		_, err := tx.Exec(ctx, `SELECT 1`)
		return err
	}
	attempts := func() int {
		return f.count(`SELECT coalesce(sum(count), 0) FROM rate_counters WHERE scope = 'password-writer'`)
	}

	if err := su.Run(ctx, guarded(m.deviceStepUp(keyproto.ActionSessionLogoutAll, m.s)), inTx); err != nil {
		t.Fatalf("a device step-up on a one-connection pool: %v", err)
	}
	if n := attempts(); n != 0 {
		t.Fatalf("a right password left %d writer attempts", n)
	}
	wrong := f.stretch(m.addr, "not the password at all")
	if err := su.Run(ctx, guarded(m.deviceStepUp(keyproto.ActionSessionLogoutAll, wrong)), inTx); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a wrong password on a one-connection pool: %v", err)
	}
	if n := attempts(); n != 1 {
		t.Fatalf("a wrong password left %d writer attempts, want 1", n)
	}
	refused := errors.New("refused")
	if err := su.Run(ctx, guarded(m.deviceStepUp(keyproto.ActionSessionLogoutAll, m.s)),
		func(context.Context, pgx.Tx, Proven) error { return refused }); !errors.Is(err, refused) {
		t.Fatalf("a failing action: %v", err)
	}
	if n := attempts(); n != 1 {
		t.Fatalf("a right password whose action failed left %d writer attempts, want 1", n)
	}

	newS := f.stretch(m.addr, "an entirely new password")
	rph, _ := keyproto.ParamsHash(keyproto.ActionPasswordReset, sumBytes(newS))
	i := m.info()
	b, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordReset, rph[:], keyproto.ProofDeviceCode)
	if err != nil {
		t.Fatal(err)
	}
	msg, _ := keyproto.DeviceStepUpMessage(b.Challenge, m.device.WriterID)
	code := &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "device_code", WriterID: m.device.WriterID,
		Sig: m.device.SignDAK(t, msg), Code: f.lastCode(m.addr)}}
	g := Guarded{UserID: i.UserID, SessionHash: i.Hash, BoundWriter: i.WriterID,
		Action: keyproto.ActionPasswordReset, ParamsHash: rph, StepUp: code}
	right := code.Proof.Code
	code.Proof.Code = "000000"
	if right == code.Proof.Code {
		code.Proof.Code = "111111"
	}
	if err := su.Run(ctx, g, inTx); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a wrong code on a one-connection pool: %v", err)
	}
	code.Proof.Code = right
	if err := su.Run(ctx, g, inTx); err != nil {
		t.Fatalf("a device_code step-up on a one-connection pool: %v", err)
	}
	if n := f.count(`SELECT attempts FROM email_codes WHERE ceremony_kind = 'step_up'`); n != 2 {
		t.Fatalf("the code counted %d attempts, want 2", n)
	}
}
