package auth

import (
	"context"
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
	cfg := f.pool.Config().Copy()
	cfg.MaxConns, cfg.MinConns = 1, 0
	one, err := pgxpool.NewWithConfig(bgctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(one.Close)
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
