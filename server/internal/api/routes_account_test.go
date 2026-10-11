package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purge"
)

// deletableWriter is the writer every deletable account enrols.
const deletableWriter = "ios-00000000-0000-4000-8000-000000000206"

// deletable is an account set up the way a real one is: a passkey, a session,
// an enrolled device writer, and some history worth losing.
type deletable struct {
	u    uuid.UUID
	tok  string
	priv ed25519.PrivateKey
	// pk is the authenticator holding this account's only credential.
	pk *authtest.Authenticator
	// counter is where its signature counter has got to. It only ever goes up,
	// because a counter that does not is the cloned-authenticator signal.
	counter uint32
}

func (h *harness) deletable(t *testing.T, note string) *deletable {
	t.Helper()
	pk, out := h.register(h.invite(note))
	u, err := uuid.Parse(out.UserID)
	if err != nil {
		t.Fatal(err)
	}
	priv := h.writer(u, deletableWriter)
	h.seed(u, 2)
	return &deletable{u: u, tok: out.SessionToken, priv: priv, pk: pk, counter: 1}
}

// stepUp begins an account.delete step-up on token's session, with params
// naming account target, and proves it with authenticator a. It answers the
// step-up and its nonce.
func (d *deletable) stepUp(t *testing.T, h *harness, token string, target uuid.UUID, a *authtest.Authenticator) (*StepUpWire, []byte) {
	t.Helper()
	ph, _ := keyproto.ParamsHash(keyproto.ActionAccountDelete, []byte(target.String()))
	w := h.req("POST", "/api/v1/auth/step-up/begin", token, StepUpBeginRequest{
		Action: string(keyproto.ActionAccountDelete), ParamsHash: hex.EncodeToString(ph[:]), ProofKind: "passkey"})
	wantStatus(t, w, http.StatusOK)
	b := decodeJSON[StepUpBeginResponse](t, w)
	nonce, _ := base64.RawURLEncoding.DecodeString(b.Nonce)
	c, _ := keyproto.StepUpChallenge(nonce, keyproto.ActionAccountDelete, ph)
	d.counter++
	return &StepUpWire{Nonce: b.Nonce, Proof: StepUpProofWire{Kind: "passkey",
		Assertion: a.AssertChallenge(t, authtest.RPID, c[:], d.counter)}}, nonce
}

// sign is the writer's signature over DeletionMessage(nonce, d.u).
func (d *deletable) sign(t *testing.T, priv ed25519.PrivateKey, nonce []byte) string {
	t.Helper()
	msg, err := keyproto.DeletionMessage(nonce, d.u)
	if err != nil {
		t.Fatal(err)
	}
	return b64(ed25519.Sign(priv, msg))
}

// body is a complete, valid #41 request. Every refusal test takes this and
// breaks exactly one thing, so a test that stops proving what it says can only
// be one that stopped breaking anything.
func (d *deletable) body(t *testing.T, h *harness) DeleteAccountRequest {
	t.Helper()
	su, nonce := d.stepUp(t, h, d.tok, d.u, d.pk)
	return DeleteAccountRequest{StepUp: su, WriterID: deletableWriter, Sig: d.sign(t, d.priv, nonce)}
}

func (h *harness) countUsers(t *testing.T) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM users`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func (h *harness) accountExists(t *testing.T, u uuid.UUID) bool {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM users WHERE id = $1`, u).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}

// ---------------------------------------------------------------------------
// The three factors
// ---------------------------------------------------------------------------

// A stolen session token must not be able to destroy a life's financial
// history: without a step-up the answer is step_up_required, and nothing moves.
func TestDeleteAccountRefusesASessionTokenAlone(t *testing.T) {
	h := newHarness(t).passkeys()
	acc := h.deletable(t, "alice")

	for _, body := range []any{map[string]any{}, DeleteAccountRequest{WriterID: deletableWriter, Sig: b64(make([]byte, 64))}} {
		w := h.req("DELETE", "/api/v1/account", acc.tok, body)
		wantStatus(t, w, http.StatusForbidden)
		wantError(t, w, "step_up_required")
	}
	if !h.accountExists(t, acc.u) {
		t.Fatal("a session token alone deleted the account")
	}
	var n int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM op_log WHERE user_id = $1`, acc.u).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("op_log holds %d rows, want the 2 that were seeded", n)
	}
}

// ledgerd's form is gone (spec 02 §2.4): its challenge route answers 404, and
// a body that still carries its fields is malformed.
func TestLedgerdsDeletionFormIsGone(t *testing.T) {
	h := newHarness(t).passkeys()
	acc := h.deletable(t, "alice")
	wantStatus(t, h.req("POST", "/api/v1/account/challenge", acc.tok, struct{}{}), http.StatusNotFound)
	for _, body := range []map[string]any{
		{"nonce": b64(make([]byte, 32)), "sig": b64(make([]byte, 64))},
		{"assertion": map[string]any{}, "nonce": b64(make([]byte, 32)), "sig": b64(make([]byte, 64))},
	} {
		wantStatus(t, h.req("DELETE", "/api/v1/account", acc.tok, body), http.StatusBadRequest)
	}
	if !h.accountExists(t, acc.u) {
		t.Fatal("ledgerd's form deleted the account")
	}
}

// Every way of getting one factor wrong is the step-up's one refusal, so a
// caller cannot learn which factor it is missing, and the account stays.
func TestEveryDeletionRefusalIsTheSameAnswer(t *testing.T) {
	// A harness per case, because the per-user attempt limiter is real.
	for _, tc := range []struct {
		name  string
		build func(t *testing.T, h *harness, acc, mallory *deletable) DeleteAccountRequest
	}{
		{"a signature over another nonce", func(t *testing.T, h *harness, acc, _ *deletable) DeleteAccountRequest {
			b := acc.body(t, h)
			b.Sig = acc.sign(t, acc.priv, make([]byte, 32))
			return b
		}},
		{"a signature by an unenrolled key", func(t *testing.T, h *harness, acc, _ *deletable) DeleteAccountRequest {
			_, stranger, _ := ed25519.GenerateKey(nil)
			su, nonce := acc.stepUp(t, h, acc.tok, acc.u, acc.pk)
			return DeleteAccountRequest{StepUp: su, WriterID: deletableWriter, Sig: acc.sign(t, stranger, nonce)}
		}},
		{"a signature by a revoked writer", func(t *testing.T, h *harness, acc, _ *deletable) DeleteAccountRequest {
			if _, err := h.pool.Exec(bg, `UPDATE writers SET revoked_at = now() WHERE user_id = $1 AND writer_id = $2`,
				acc.u, deletableWriter); err != nil {
				t.Fatal(err)
			}
			return acc.body(t, h)
		}},
		{"a writer the account does not have", func(t *testing.T, h *harness, acc, _ *deletable) DeleteAccountRequest {
			su, nonce := acc.stepUp(t, h, acc.tok, acc.u, acc.pk)
			return DeleteAccountRequest{StepUp: su, WriterID: "ios-11111111-1111-4111-8111-111111111111",
				Sig: acc.sign(t, acc.priv, nonce)}
		}},
		{"another account's passkey", func(t *testing.T, h *harness, acc, mallory *deletable) DeleteAccountRequest {
			su, nonce := acc.stepUp(t, h, acc.tok, acc.u, mallory.pk)
			return DeleteAccountRequest{StepUp: su, WriterID: deletableWriter, Sig: acc.sign(t, acc.priv, nonce)}
		}},
		{"a step-up naming another account", func(t *testing.T, h *harness, acc, mallory *deletable) DeleteAccountRequest {
			su, nonce := acc.stepUp(t, h, acc.tok, mallory.u, acc.pk)
			return DeleteAccountRequest{StepUp: su, WriterID: deletableWriter, Sig: acc.sign(t, acc.priv, nonce)}
		}},
		{"another session's step-up", func(t *testing.T, h *harness, acc, mallory *deletable) DeleteAccountRequest {
			su, nonce := mallory.stepUp(t, h, mallory.tok, mallory.u, mallory.pk)
			return DeleteAccountRequest{StepUp: su, WriterID: deletableWriter, Sig: acc.sign(t, acc.priv, nonce)}
		}},
		{"a spent step-up", func(t *testing.T, h *harness, acc, _ *deletable) DeleteAccountRequest {
			b := acc.body(t, h)
			bad := b
			bad.Sig = acc.sign(t, acc.priv, make([]byte, 32))
			wantStatus(t, h.req("DELETE", "/api/v1/account", acc.tok, bad), http.StatusForbidden)
			return b
		}},
		{"an expired step-up", func(t *testing.T, h *harness, acc, _ *deletable) DeleteAccountRequest {
			b := acc.body(t, h)
			if _, err := h.pool.Exec(bg, `UPDATE step_up_challenges SET issued_at = issued_at - interval '10 minutes',
				expires_at = issued_at - interval '9 minutes' WHERE user_id = $1`, acc.u); err != nil {
				t.Fatal(err)
			}
			return b
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t).passkeys()
			acc := h.deletable(t, "alice")
			mallory := h.deletable(t, "mallory")
			before := h.countUsers(t)

			w := h.req("DELETE", "/api/v1/account", acc.tok, tc.build(t, h, acc, mallory))
			wantStatus(t, w, http.StatusForbidden)
			if got := w.Body.String(); got != `{"error":"step_up_failed"}` {
				t.Fatalf("body = %s, want the one refusal every factor shares", got)
			}
			if !h.accountExists(t, acc.u) || !h.accountExists(t, mallory.u) || h.countUsers(t) != before {
				t.Fatal("a refused deletion changed the accounts")
			}
		})
	}
}

// ---------------------------------------------------------------------------
// The happy path
// ---------------------------------------------------------------------------

func TestDeleteAccountWithAllThreeFactorsPurgesTheAccount(t *testing.T) {
	h := newHarness(t).passkeys()
	acc := h.deletable(t, "alice")
	bystander := h.deletable(t, "bob")

	body := acc.body(t, h)
	w := h.req("DELETE", "/api/v1/account", acc.tok, body)
	wantStatus(t, w, http.StatusNoContent)

	if h.accountExists(t, acc.u) {
		t.Fatal("the account survived its own deletion")
	}
	rels, err := purge.UserScopedTables(bg, h.pool)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rels {
		var n int
		if err := h.pool.QueryRow(bg, `SELECT count(*) FROM `+r.SQL()+` WHERE user_id = $1`, acc.u).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Fatalf("%s still holds %d rows for the deleted account", r, n)
		}
	}
	if !h.accountExists(t, bystander.u) {
		t.Fatal("the other account went with it")
	}
	// The session died with the account, and says so distinguishably: a 401
	// would look like an expired session, and the device that just deleted its
	// own account has to know which one it is looking at before it wipes.
	after := h.req("GET", "/api/v1/sync?stream=hot", acc.tok, nil)
	wantStatus(t, after, http.StatusGone)
	if got := after.Body.String(); got != `{"error":"account_deleted"}` {
		t.Fatalf("body = %s", got)
	}
	// A replay of the whole request meets the same 410.
	wantStatus(t, h.req("DELETE", "/api/v1/account", acc.tok, body), http.StatusGone)
}

// The signer may be any live writer of the account (spec 02 §15.2:
// "<signer, live>"), not only the session's own.
func TestAnotherLiveWriterMaySignTheDeletion(t *testing.T) {
	h := newHarness(t).passkeys()
	acc := h.deletable(t, "alice")
	other := h.writer(acc.u, "ios-22222222-2222-4222-8222-222222222222")
	su, nonce := acc.stepUp(t, h, acc.tok, acc.u, acc.pk)
	wantStatus(t, h.req("DELETE", "/api/v1/account", acc.tok, DeleteAccountRequest{StepUp: su,
		WriterID: "ios-22222222-2222-4222-8222-222222222222", Sig: acc.sign(t, other, nonce)}), http.StatusNoContent)
	if h.accountExists(t, acc.u) {
		t.Fatal("the account survived its deletion")
	}
}

// ---------------------------------------------------------------------------
// Shape
// ---------------------------------------------------------------------------

func TestDeleteAccountNeedsASession(t *testing.T) {
	h := newHarness(t).passkeys()
	wantStatus(t, h.req("DELETE", "/api/v1/account", "", DeleteAccountRequest{}), http.StatusUnauthorized)
}

// Malformed input describes the caller's own submission and reveals nothing
// about the account, so it is a 400.
func TestDeleteAccountAnswers400ForMalformedInput(t *testing.T) {
	h := newHarness(t).passkeys()
	acc := h.deletable(t, "alice")
	good := acc.body(t, h)
	badSig := good
	badSig.Sig = "!!"
	badNonce := good
	badNonce.StepUp = &StepUpWire{Nonce: "!!", Proof: good.StepUp.Proof}
	for name, body := range map[string]DeleteAccountRequest{"sig is not base64": badSig, "nonce is not base64url": badNonce} {
		t.Run(name, func(t *testing.T) {
			wantStatus(t, h.req("DELETE", "/api/v1/account", acc.tok, body), http.StatusBadRequest)
		})
	}
	if !h.accountExists(t, acc.u) {
		t.Fatal("a malformed request deleted the account")
	}
}
