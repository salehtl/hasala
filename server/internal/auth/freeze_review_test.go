package auth

import (
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestADeviceFreezeFindsTheWriterThatSigned(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	other := f.passwordMember("Pat")
	twin := authtest.NewDevice(t)
	if _, err := f.pool.Exec(bgctx, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at)
	        VALUES ($1, $2, 'ed25519', $3, $4, now())`, other.user.UserID, m.device.WriterID, twin.DWKPub(), twin.DAKPub()); err != nil {
		t.Fatal(err)
	}
	var admitted []uuid.UUID
	admit := func(u uuid.UUID) bool {
		admitted = append(admitted, u)
		return len(admitted) < 2
	}
	freeze := func() error {
		nonce, _, err := f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
		if err != nil {
			t.Fatal(err)
		}
		msg, _ := keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
		bad := m.device.SignDAK(t, msg)
		bad[40] ^= 1
		if _, err := f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, bad, admit); !errors.Is(err, ErrFreezeRefused) {
			t.Fatalf("a bad signature: %v", err)
		}
		nonce, _, _ = f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
		msg, _ = keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
		_, err = f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, m.device.SignDAK(t, msg), admit)
		return err
	}
	if err := freeze(); err != nil {
		t.Fatalf("a freeze by a writer id another account also holds: %v", err)
	}
	if len(admitted) != 1 || admitted[0] != m.user.UserID {
		t.Fatalf("the limiter was asked for %v, want only the signing account", admitted)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, m.user.UserID); n != 1 {
		t.Fatal("the signing account is not frozen")
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, other.user.UserID); n != 0 {
		t.Fatal("the other account was frozen")
	}
	if err := freeze(); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a freeze over the limit: %v", err)
	}
}
