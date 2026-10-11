package auth

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// The property every test in this file asserts, stated once: disowning a device
// stops its notifications.
//
// In ledgerd it once did not: a device the user had explicitly disowned kept
// receiving a real-time wake for the life of the account. The payload carries
// nothing; the TIMING is a live feed of when that person spends. The table is
// now apns_tokens (spec 02 §5.3), bound to the writer and the session that
// registered it, and every revocation deletes it in its own transaction (spec
// 02 §9.3, F4).
//
// These run in auth rather than in pushv2 because auth owns the revocation
// transactions, and "the sweep committed with the revocation" is the part that
// cannot be checked from the other side.

// registerPushToken plants an APNs token row directly, as WS-4's token route
// will: one per device writer, bound to the registering session.
func registerPushToken(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, writerID, sessionToken, token string) {
	t.Helper()
	sum := sha256.Sum256([]byte(token))
	if _, err := pool.Exec(bgctx,
		`INSERT INTO apns_tokens (user_id, writer_id, session_hash, token_hex, environment, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, 'production', now(), now())`,
		u, writerID, SessionHash(sessionToken), hex.EncodeToString(sum[:])); err != nil {
		t.Fatal(err)
	}
}

func pushTokenCount(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) int {
	t.Helper()
	return countRows(t, pool, `SELECT count(*) FROM apns_tokens WHERE user_id = $1`, u)
}

// Revoking a writer deletes its APNs token in the revocation's transaction:
// TestRevocationPinsTheFinalHeadAndEndsTheDevice (writer_test.go) asserts it
// alongside the rest of what a revocation ends.

// plantWriter enrols a writer directly (these tests are about sessions, not
// enrolment) with fresh keys.
func plantWriter(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) string {
	t.Helper()
	d := authtest.NewDevice(t)
	if _, err := pool.Exec(bgctx,
		`INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at) VALUES ($1, $2, 'ed25519', $3, $4, now())`,
		u, d.WriterID, d.DWKPub(), d.DAKPub()); err != nil {
		t.Fatal(err)
	}
	return d.WriterID
}

// TestRevokingASessionStopsThatDevicesNotifications is the sign-out case, and
// it is NOT the same gesture as revoking a key: a user signing out of a phone
// they are handing on has not retired their device key, they have ended that
// phone's access. 00010's own comment claimed this case was "recoverable by the
// user"; it was not, and this is what makes it true.
func TestRevokingASessionStopsThatDevicesNotifications(t *testing.T) {
	pool := pgtest.New(t)
	c := newClock()
	sessions := newSessions(pool, time.Hour, c)
	u := mustUpsert(t, pool, testIdentity("sub-push-revoke-session"))

	phone, tablet := plantWriter(t, pool, u), plantWriter(t, pool, u)

	phoneSess, err := sessions.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	tabletSess, err := sessions.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	registerPushToken(t, pool, u, phone, phoneSess, "ExponentPushToken[phone000phone000phon]")
	registerPushToken(t, pool, u, tablet, tabletSess, "ExponentPushToken[tablet00tablet00tabl]")

	if err := sessions.Revoke(bgctx, phoneSess); err != nil {
		t.Fatal(err)
	}
	if got := countRows(t, pool,
		`SELECT count(*) FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, u, phone); got != 0 {
		t.Fatalf("the signed-out device still has %d push token(s)", got)
	}
	if got := countRows(t, pool,
		`SELECT count(*) FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, u, tablet); got != 1 {
		t.Fatalf("signing out one device stopped another's notifications (%d left)", got)
	}
	// Idempotent, and the sweep is not gated on the UPDATE having done work:
	// re-revoking must still clear anything that somehow survived, because the
	// failure being closed is "the user believes they stopped it and it did not
	// stop".
	if err := sessions.Revoke(bgctx, phoneSess); err != nil {
		t.Fatalf("re-revoking: %v", err)
	}
}

// TestSignOutEverywhereStopsEveryDevicesNotifications. "Everywhere" has to
// include the notifications, or the one primitive a user reaches for when they
// think they have been compromised leaves the compromised device with a live
// feed of their spending.
func TestSignOutEverywhereStopsEveryDevicesNotifications(t *testing.T) {
	pool := pgtest.New(t)
	c := newClock()
	sessions := newSessions(pool, time.Hour, c)

	a := mustUpsert(t, pool, testIdentity("sub-push-revoke-all-a"))
	b := mustUpsert(t, pool, testIdentity("sub-push-revoke-all-b"))

	for _, u := range []uuid.UUID{a, b} {
		d := plantWriter(t, pool, u)
		sess, err := sessions.Issue(bgctx, u)
		if err != nil {
			t.Fatal(err)
		}
		registerPushToken(t, pool, u, d, sess, "ExponentPushToken["+u.String()[:20]+"]")
	}

	if err := sessions.RevokeAllForUser(bgctx, a); err != nil {
		t.Fatal(err)
	}
	if got := pushTokenCount(t, pool, a); got != 0 {
		t.Fatalf("sign-out-everywhere left %d push token(s) receiving", got)
	}
	if got := pushTokenCount(t, pool, b); got != 1 {
		t.Fatalf("one user's sign-out-everywhere removed another user's push token (%d left)", got)
	}
}

// TestSessionHashIsTheStoredForm. The API stores the HASH of the bearer token
// against a apns_tokens row, never the token, so a leaked row names a session
// without being usable as one — and Revoke can only find the row it should if
// both sides derive the same bytes.
func TestSessionHashIsTheStoredForm(t *testing.T) {
	const tok = "a-session-token"
	if got, want := SessionHash(tok), tokenHash(tok); string(got) != string(want) {
		t.Fatalf("SessionHash disagrees with the form Sessions persists")
	}
	if string(SessionHash(tok)) == tok {
		t.Fatal("SessionHash returned the token itself")
	}
}
