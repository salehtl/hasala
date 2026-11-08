package auth

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestANonceShownByAnotherSessionOrAccountStaysUsableByItsOwner(t *testing.T) {
	f := newKeyFixture(t)
	owner := f.newSession()
	su := f.stepUpPasskey(owner, keyproto.ActionPasskeyDelete, f.credID)
	ran := 0
	run := func(session SessionInfo) error {
		g, err := guardFor(session, keyproto.ActionPasskeyDelete, su, f.credID)
		if err != nil {
			t.Fatal(err)
		}
		return f.stepUp.Run(bgctx, g, func(context.Context, pgx.Tx, Proven) error {
			ran++
			return nil
		})
	}
	open := func() int {
		return f.count(`SELECT count(*) FROM step_up_challenges WHERE nonce = $1 AND used_at IS NULL`, su.Nonce)
	}

	if err := run(f.info(f.token)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("another session's nonce: %v", err)
	}
	if open() != 1 {
		t.Fatal("another session closed the nonce")
	}

	otherAccount := f.info(owner)
	otherAccount.UserID = uuid.New()
	if err := run(otherAccount); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("another account's nonce: %v", err)
	}
	if open() != 1 {
		t.Fatal("another account closed the nonce")
	}
	if ran != 0 {
		t.Fatal("the action ran for a presenter that does not own the nonce")
	}

	if err := run(f.info(owner)); err != nil {
		t.Fatalf("the owner's step-up after the foreign attempts: %v", err)
	}
	if open() != 0 || ran != 1 {
		t.Fatalf("after the owner's step-up: open %d, ran %d", open(), ran)
	}
}

func TestAWrongProofFromTheOwningSessionStillBurnsTheNonce(t *testing.T) {
	f := newKeyFixture(t)
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyDelete, f.credID)
	g, err := guardFor(f.info(f.token), keyproto.ActionPasskeyDelete, su, []byte("not the credential it was begun for"))
	if err != nil {
		t.Fatal(err)
	}
	if err := f.stepUp.Run(bgctx, g, func(context.Context, pgx.Tx, Proven) error { return nil }); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a request that does not match the challenge: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM step_up_challenges WHERE nonce = $1 AND used_at IS NOT NULL`, su.Nonce); n != 1 {
		t.Fatal("the owning session's failed proof left the nonce open")
	}
}
