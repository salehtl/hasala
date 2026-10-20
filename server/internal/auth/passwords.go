package auth

// The server's side of a password (spec 01 §4.10, spec 02 §10.15): it sees
// only S, the device-stretched value, and stores PBKDF2(HMAC(K_pepper, S),
// pw_salt, 100000) with a fresh 16-byte salt each time a password is set. It
// derives no key from S and wraps nothing under it (PO B): no route here
// touches account_keys, wraps or writers. Every limiter runs before the
// PBKDF2, and every PBKDF2 runs through the gate.

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authkeys"
)

// Password limits (spec 02 §10.8, §16.2).
const (
	passwordEmailWindow   = 15 * time.Minute
	passwordEmailLimit    = 20
	passwordWriterWindow  = time.Hour
	passwordWriterFailMax = 5
	passwordPauseAfter    = 5
	passwordPauseFirst    = time.Minute
	passwordPauseMax      = time.Hour
)

// dummySalt is the salt a password sign-in hashes with when there is no
// account, no password, or a paused unbound attempt, so every outcome costs
// one PBKDF2.
var dummySalt = make([]byte, authkeys.PasswordSaltSize)

// writerCounterKey is the password-writer counter's key:
// SHA256(uuid_raw(user_id) ‖ utf8(writer_id)).
func writerCounterKey(userID uuid.UUID, writerID string) []byte {
	h := sha256.New()
	h.Write(userID[:])
	h.Write([]byte(writerID))
	return h.Sum(nil)
}

// newPasswordHash makes a fresh (hash, salt) for S under the current pepper
// generation, through the gate.
func newPasswordHash(ctx context.Context, keys *authkeys.Keys, gate *authkeys.Gate, s []byte) (hash, salt []byte, err error) {
	if len(s) != authkeys.VerifierSize {
		return nil, nil, fmt.Errorf("%w: a verifier is %d bytes", ErrBadRequest, authkeys.VerifierSize)
	}
	if salt, err = randBytes(authkeys.PasswordSaltSize); err != nil {
		return nil, nil, err
	}
	hash, err = keys.HashGated(ctx, gate, s, salt, keys.Current())
	if err != nil {
		return nil, nil, gateErr(err)
	}
	return hash, salt, nil
}

// passwordMatches runs the one PBKDF2 of a password proof against st's hash,
// or against a dummy when st has none, and answers whether it matched.
func passwordMatches(ctx context.Context, keys *authkeys.Keys, gate *authkeys.Gate, st accountState, s []byte, compare bool) (bool, error) {
	salt, gen := dummySalt, keys.Current()
	if compare && st.hasPassword() {
		salt = st.PasswordSalt
		if st.PasswordVersion != nil {
			gen = int(*st.PasswordVersion)
		}
	}
	if len(s) != authkeys.VerifierSize {
		s = make([]byte, authkeys.VerifierSize) // still one PBKDF2; it can never match
		compare = false
	}
	h, err := keys.HashGated(ctx, gate, s, salt, gen)
	if err != nil {
		return false, gateErr(err)
	}
	return compare && st.hasPassword() && subtle.ConstantTimeCompare(h, st.PasswordHash) == 1, nil
}

// passwordPause is the pause after the n-th consecutive failure: none below
// five, then one minute doubling to at most an hour.
func passwordPause(n int) time.Duration {
	if n < passwordPauseAfter {
		return 0
	}
	d := passwordPauseFirst
	for i := passwordPauseAfter; i < n && d < passwordPauseMax; i++ {
		d *= 2
	}
	if d > passwordPauseMax {
		d = passwordPauseMax
	}
	return d
}

// recordPasswordFailure is a wrong S against a real password, committed alone:
// password_failures rises (and with it the unbound pause).
func recordPasswordFailure(ctx context.Context, q queryExecer, userID uuid.UUID, now time.Time) error {
	var n int
	if err := q.QueryRow(ctx,
		`UPDATE users SET password_failures = password_failures + 1 WHERE id = $1 RETURNING password_failures`, userID).Scan(&n); err != nil {
		return fmt.Errorf("auth: count a password failure: %w", err)
	}
	if d := passwordPause(n); d > 0 {
		if _, err := q.Exec(ctx, `UPDATE users SET password_paused_until = $2 WHERE id = $1`, userID, now.Add(d)); err != nil {
			return fmt.Errorf("auth: pause passwords: %w", err)
		}
	}
	return nil
}

func writerPasswordAttempt(ctx context.Context, q queryExecer, userID uuid.UUID, writerID string, now time.Time) error {
	n, err := bumpCounter(ctx, q, "password-writer", writerCounterKey(userID, writerID), passwordWriterWindow, now)
	if err != nil {
		return err
	}
	if n > passwordWriterFailMax {
		return fmt.Errorf("%w: this device's password attempts", ErrRateLimited)
	}
	return nil
}

func refundWriterPasswordAttempt(ctx context.Context, q queryExecer, userID uuid.UUID, writerID string, now time.Time) error {
	if _, err := q.Exec(ctx,
		`UPDATE rate_counters SET count = count - 1 WHERE scope = 'password-writer' AND key = $1 AND window_start = $2 AND count > 0`,
		writerCounterKey(userID, writerID), now.UTC().Truncate(passwordWriterWindow)); err != nil {
		return fmt.Errorf("auth: rate counter password-writer: %w", err)
	}
	return nil
}

// setPasswordTx writes a fresh verifier, resetting the failure counter and
// the pause.
func setPasswordTx(ctx context.Context, q queryExecer, userID uuid.UUID, hash, salt []byte, generation int, now time.Time) error {
	if _, err := q.Exec(ctx,
		`UPDATE users SET password_hash = $2, password_salt = $3, password_version = $4, password_set_at = $5,
		        password_failures = 0, password_paused_until = NULL
		  WHERE id = $1`, userID, hash, salt, generation, now); err != nil {
		return fmt.Errorf("auth: set password: %w", err)
	}
	return nil
}
