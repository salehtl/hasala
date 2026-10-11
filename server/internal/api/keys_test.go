package api

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// The key routes over HTTP, driven the way the app drives them (spec 01
// §10.3 C1, §10.5, §10.6, §10.7; spec 02 #3, #4, #9, #17–#27).

// prfWrap is a well-formed PRF wrap (spec 01 §5.1: 127 bytes, header 01 02).
func prfWrap(fill byte) []byte { return append([]byte{1, 2}, bytes.Repeat([]byte{fill}, 125)...) }

// credential inserts a webauthn credential row for u directly.
func (h *harness) credential(u uuid.UUID, id []byte) []byte {
	h.t.Helper()
	if _, err := h.pool.Exec(bg, `INSERT INTO webauthn_credentials
		(credential_id, user_id, user_handle, public_key, sign_count, backup_eligible, backup_state, attestation_sha256, created_at)
		VALUES ($1, $2, $3, $4, 0, true, true, $5, now())`,
		id, u, authtest.RandBytesTB(h.t, 32), authtest.RandBytesTB(h.t, 77), authtest.RandBytesTB(h.t, 32)); err != nil {
		h.t.Fatal(err)
	}
	return id
}

func (h *harness) countWraps(u uuid.UUID) int {
	h.t.Helper()
	var n int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM account_key_wraps WHERE user_id = $1`, u).Scan(&n); err != nil {
		h.t.Fatal(err)
	}
	return n
}

// keyed is one account onboarded over HTTP.
type keyed struct {
	h       *harness
	user    uuid.UUID
	token   string
	authn   *authtest.Authenticator
	acct    *authtest.Account
	device  *authtest.Device
	email   string
	counter atomic.Uint32
}

var keyedN atomic.Int64

// onboard runs spec 01 §10.3's C1 over HTTP up to (bootstrap = false) or
// including the bootstrap.
func (h *harness) onboard(bootstrap bool) *keyed {
	h.t.Helper()
	k := &keyed{h: h, device: authtest.NewDevice(h.t)}
	aakSeed := authtest.RandBytesTB(h.t, 32)
	w := h.req("POST", "/api/v1/auth/passkey/register/begin", "", PasskeyRegisterBeginRequest{
		InviteCode: h.invite("keys"), AuthorityPubkey: b64(cryptoref.AAKPub(aakSeed)),
	})
	wantStatus(h.t, w, http.StatusOK)
	begun := decodeJSON[PasskeyRegisterBeginResponse](h.t, w)
	nonce, _ := base64.StdEncoding.DecodeString(begun.Nonce)
	var opts struct {
		PublicKey struct {
			Challenge string `json:"challenge"`
		} `json:"publicKey"`
	}
	if err := json.Unmarshal(begun.Options, &opts); err != nil {
		h.t.Fatal(err)
	}
	creg, _ := keyproto.RegisterChallenge(nonce, cryptoref.AAKPub(aakSeed))
	if opts.PublicKey.Challenge != base64.RawURLEncoding.EncodeToString(creg[:]) {
		h.t.Fatalf("options.challenge %q is not C_reg", opts.PublicKey.Challenge)
	}
	var createOpts protocol.CredentialCreation
	if err := json.Unmarshal(begun.Options, &createOpts); err != nil {
		h.t.Fatal(err)
	}
	k.authn = authtest.New(h.t)
	fw := h.req("POST", "/api/v1/auth/passkey/register/finish", "", PasskeyFinishRequest{
		CeremonyID: begun.CeremonyID, Credential: k.authn.Create(h.t, &createOpts),
	})
	wantStatus(h.t, fw, http.StatusOK)
	sess := decodeJSON[SessionResponse](h.t, fw)
	k.user, k.token = mustUUID(h.t, sess.UserID), sess.SessionToken
	k.counter.Store(2)
	k.acct = &authtest.Account{User: k.user, E: authtest.RandBytesTB(h.t, 16), AMK: authtest.RandBytesTB(h.t, 32), AAKSeed: aakSeed}
	k.email = fmt.Sprintf("maya+%d@example.com", keyedN.Add(1))
	if _, err := h.pool.Exec(bg, `UPDATE users SET email_norm = $2 WHERE id = $1`, k.user, k.email); err != nil {
		h.t.Fatal(err)
	}
	if bootstrap {
		wantStatus(h.t, h.req("POST", "/api/v1/account/bootstrap", k.token,
			k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true)), http.StatusCreated)
	}
	return k
}

func (k *keyed) attestation() []byte { return auth.AttestationHash(k.authn.LastAttestationObject) }

func (k *keyed) nonce(token string) []byte {
	k.h.t.Helper()
	w := k.h.req("POST", "/api/v1/writers/challenge", token, map[string]any{})
	wantStatus(k.h.t, w, http.StatusOK)
	n, err := base64.StdEncoding.DecodeString(decodeJSON[ChallengeResponse](k.h.t, w).Nonce)
	if err != nil || len(n) != 32 {
		k.h.t.Fatalf("challenge nonce %x", n)
	}
	return n
}

func (k *keyed) bootstrapRequest(d *authtest.Device, kind byte, authHash []byte, prf bool) BootstrapRequest {
	k.h.t.Helper()
	var cred, secret []byte
	if prf {
		cred, secret = k.authn.CredID, authtest.RandBytesTB(k.h.t, 32)
	}
	b := k.acct.BuildBootstrap(k.h.t, d, k.email, k.nonce(k.token), kind, authHash, cred, secret)
	p := b.Payload
	req := BootstrapRequest{
		FormatVersion: 1, AMKCommitment: b64(p.AMKCommitment), AuthorityPubkey: b64(p.AuthorityPubkey),
		RecoveryPubkey: b64(p.RecoveryPubkey), RecoveryWrap: b64(p.RecoveryWrap), PhraseBox: b64(p.PhraseBox),
		EmailHash: b64(p.EmailHash), AuthKind: int(p.AuthKind), AuthHash: b64(p.AuthHash),
		Writer: BootstrapWriter{WriterID: d.WriterID, Alg: "ed25519", PubKey: b64(d.DWKPub()), DAKPubkey: b64(d.DAKPub())},
		Nonce:  b64(b.Nonce), AuthoritySig: b64(b.AuthoritySig), RegistrationSig: b64(b.RegistrationSig),
	}
	if prf {
		req.PRFWrap = &BootstrapPRFWrap{CredentialID: b64url(p.CredentialID), Wrap: b64(p.PRFWrap), WrapVersion: 1}
	}
	return req
}

// stepUp begins a passkey step-up on token's session and proves it.
func (k *keyed) stepUp(token string, action keyproto.Action, fields ...[]byte) *StepUpWire {
	k.h.t.Helper()
	ph, _ := keyproto.ParamsHash(action, fields...)
	w := k.h.req("POST", "/api/v1/auth/step-up/begin", token, StepUpBeginRequest{
		Action: string(action), ParamsHash: hex.EncodeToString(ph[:]), ProofKind: "passkey",
	})
	wantStatus(k.h.t, w, http.StatusOK)
	b := decodeJSON[StepUpBeginResponse](k.h.t, w)
	nonce, _ := base64.RawURLEncoding.DecodeString(b.Nonce)
	// The client computes C itself and refuses a challenge that differs (AT-C9).
	c, _ := keyproto.StepUpChallenge(nonce, action, ph)
	if b.Challenge != b64url(c[:]) {
		k.h.t.Fatalf("step-up challenge %s, want %s", b.Challenge, b64url(c[:]))
	}
	return &StepUpWire{Nonce: b.Nonce, Proof: StepUpProofWire{Kind: "passkey",
		Assertion: k.authn.AssertChallenge(k.h.t, authtest.RPID, c[:], k.counter.Add(1))}}
}

// enrol registers d over HTTP on a fresh session and returns that session.
func (k *keyed) enrol(d *authtest.Device) string {
	k.h.t.Helper()
	tok := k.h.session(k.user)
	n := k.nonce(tok)
	wantStatus(k.h.t, k.h.req("POST", "/api/v1/writers/register", tok, RegisterRequest{
		WriterID: d.WriterID, Alg: "ed25519", PubKey: b64(d.DWKPub()), DAKPubkey: b64(d.DAKPub()),
		Nonce: b64(n), Sig: b64(k.acct.Registration(k.h.t, d, n)),
	}), http.StatusCreated)
	return tok
}

// verifyHistory is spec 01 §10.13 over the wire form: every registration
// verifies under the AAK the device holds, every revocation under a writer
// live at that point.
func (k *keyed) verifyHistory(token string) map[string]bool {
	k.h.t.Helper()
	w := k.h.req("GET", "/api/v1/key-history", token, nil)
	wantStatus(k.h.t, w, http.StatusOK)
	live := map[string]bool{}
	pubs := map[string][]byte{}
	dec := func(s string) []byte { b, _ := base64.StdEncoding.DecodeString(s); return b }
	for _, e := range decodeJSON[KeyHistoryResponse](k.h.t, w).Entries {
		switch e.Event {
		case "registered":
			m, err := keyproto.RegistrationMessage(dec(e.Nonce), e.WriterID, dec(e.PubKey), dec(*e.DAKPubkey))
			if err != nil || e.AuthorizedBy != "authority" || !ed25519.Verify(k.acct.AAKPub(), m, dec(e.Signature)) {
				k.h.t.Fatalf("registration of %s does not verify under the AAK", e.WriterID)
			}
			live[e.WriterID], pubs[e.WriterID] = true, dec(e.PubKey)
		case "revoked":
			c, _ := strconv.ParseUint(*e.FinalCounter, 10, 64)
			m, err := keyproto.RevocationMessage(dec(e.Nonce), e.WriterID, c, dec(*e.FinalHead))
			if err != nil || !live[*e.AuthorizerWriterID] || !ed25519.Verify(pubs[*e.AuthorizerWriterID], m, dec(e.Signature)) {
				k.h.t.Fatalf("revocation of %s does not verify", e.WriterID)
			}
			live[e.WriterID] = false
		}
	}
	return live
}

func TestOnboardingOverHTTPPublishesKeysAndBindsTheFirstWriter(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)

	w := h.req("GET", "/api/v1/keys", k.token, nil)
	wantStatus(t, w, http.StatusOK)
	if strings.Contains(w.Body.String(), "phrase_box") {
		t.Fatal("GET /keys returned the phrase box")
	}
	keys := decodeJSON[KeysResponse](t, w)
	if keys.AuthorityPubkey != b64(k.acct.AAKPub()) || keys.CurrentEpoch != 1 || keys.FormatVersion != 1 {
		t.Fatalf("keys %+v", keys)
	}
	wraps := decodeJSON[KeyWrapsResponse](t, h.req("GET", "/api/v1/keys/wraps", k.token, nil))
	if len(wraps.Wraps) != 1 || wraps.Wraps[0].CredentialID != b64url(k.authn.CredID) {
		t.Fatalf("wraps %+v", wraps)
	}
	roster := decodeJSON[WritersResponse](t, h.req("GET", "/api/v1/writers", k.token, nil))
	if len(roster.Writers) != 1 || !roster.Writers[0].Current || roster.Writers[0].DAKPubkey != b64(k.device.DAKPub()) {
		t.Fatalf("roster %+v", roster)
	}
	if live := k.verifyHistory(k.token); !live[k.device.WriterID] {
		t.Fatal("the first writer is not live in the verified history")
	}

	// The bound session uploads under its writer with a signed head, and the
	// pull hands the head back on the batch's last row.
	signHeads = false
	defer func() { signHeads = true }()
	blobs, last := uploadChain(t, k.user, k.device.WriterID, 1, blob.ZeroHash, 2)
	m, _ := keyproto.HeadMessage(k.user, 2, last[:], k.device.WriterID)
	wantStatus(t, h.req("POST", "/api/v1/sync", k.token, UploadRequest{
		WriterID: k.device.WriterID, Stream: "hot", Blobs: blobs, HeadSig: b64(ed25519.Sign(k.device.DWK, m)),
	}), http.StatusOK)
	pull := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&limit=1", k.token, nil))
	if len(pull.Rows) != 2 || pull.Rows[0].HeadSig != nil || pull.Rows[1].HeadSig == nil {
		t.Fatalf("a page ended inside a batch, or the head is missing: %+v", pull.Rows)
	}
}

func TestBootstrapAnswersWithSpec02Codes(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(false)
	type tc struct {
		name   string
		mut    func(*BootstrapRequest)
		status int
		code   string
	}
	for _, c := range []tc{
		{"another address", func(r *BootstrapRequest) { e := keyproto.EmailHash("x@y.zz"); r.EmailHash = b64(e[:]) }, 400, "bad_request"},
		{"a writer id outside the grammar", func(r *BootstrapRequest) { r.Writer.WriterID = "dev-a" }, 400, "bad_writer_id"},
		{"a bad authority signature", func(r *BootstrapRequest) { r.AuthoritySig = b64(make([]byte, 64)) }, 400, "bad_signature"},
		{"another authority key without a step-up", func(r *BootstrapRequest) {
			r.AuthorityPubkey = b64(authtest.AuthorityPub(t))
			r.AuthKind, r.AuthHash = 0, b64(make([]byte, 32))
		}, 403, "step_up_required"},
	} {
		req := k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true)
		c.mut(&req)
		w := h.req("POST", "/api/v1/account/bootstrap", k.token, req)
		wantStatus(t, w, c.status)
		wantError(t, w, c.code)
	}
	unknown := []byte(`{"format_version":1,"authorizer":"x"}`)
	wantError(t, h.req("POST", "/api/v1/account/bootstrap", k.token, unknown), "bad_request")
	wantStatus(t, h.req("POST", "/api/v1/account/bootstrap", k.token,
		k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true)), http.StatusCreated)
	w := h.req("POST", "/api/v1/account/bootstrap", k.token, k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true))
	wantStatus(t, w, http.StatusConflict)
	wantError(t, w, "keys_exist")
	// No keys yet is a 404 no_keys, and writer routes are keys_required.
	other := h.onboard(false)
	wantError(t, h.req("GET", "/api/v1/keys", other.token, nil), "no_keys")
	d := authtest.NewDevice(t)
	n := other.nonce(other.token)
	wantError(t, h.req("POST", "/api/v1/writers/register", other.token, RegisterRequest{
		WriterID: d.WriterID, Alg: "ed25519", PubKey: b64(d.DWKPub()), DAKPubkey: b64(d.DAKPub()),
		Nonce: b64(n), Sig: b64(other.acct.Registration(t, d, n)),
	}), "keys_required")
}

func TestWritersRegisterAndRevokeOverHTTP(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	d2 := authtest.NewDevice(t)
	tok2 := k.enrol(d2)

	// A registration signed by a device key (ledgerd's TOFU) is refused.
	d3 := authtest.NewDevice(t)
	tok3 := h.session(k.user)
	n := k.nonce(tok3)
	m, _ := keyproto.RegistrationMessage(n, d3.WriterID, d3.DWKPub(), d3.DAKPub())
	w := h.req("POST", "/api/v1/writers/register", tok3, RegisterRequest{
		WriterID: d3.WriterID, Alg: "ed25519", PubKey: b64(d3.DWKPub()), DAKPubkey: b64(d3.DAKPub()),
		Nonce: b64(n), Sig: b64(ed25519.Sign(d3.DWK, m)),
	})
	wantStatus(t, w, http.StatusBadRequest)
	wantError(t, w, "bad_signature")
	// A bound session is never re-bound.
	n = k.nonce(tok2)
	w = h.req("POST", "/api/v1/writers/register", tok2, RegisterRequest{
		WriterID: d3.WriterID, Alg: "ed25519", PubKey: b64(d3.DWKPub()), DAKPubkey: b64(d3.DAKPub()),
		Nonce: b64(n), Sig: b64(k.acct.Registration(t, d3, n)),
	})
	wantStatus(t, w, http.StatusConflict)
	wantError(t, w, "session_bound")

	// Revoke d2 from the first device: step-up writer.revoke, the empty head.
	su := k.stepUp(k.token, keyproto.ActionWriterRevoke, []byte(d2.WriterID))
	n = k.nonce(k.token)
	rm, _ := keyproto.RevocationMessage(n, d2.WriterID, 0, make([]byte, 32))
	revoke := RevokeRequest{WriterID: d2.WriterID, SignerWriterID: k.device.WriterID, Nonce: b64(n),
		FinalCounter: "0", FinalHead: b64(make([]byte, 32)), Sig: b64(ed25519.Sign(k.device.DWK, rm)), StepUp: su}
	noSU := revoke
	noSU.StepUp = nil
	wantError(t, h.req("POST", "/api/v1/writers/revoke", k.token, noSU), "step_up_required")
	revoke.Nonce = b64(k.nonce(k.token))
	rm, _ = keyproto.RevocationMessage(mustB64(t, revoke.Nonce), d2.WriterID, 0, make([]byte, 32))
	revoke.Sig = b64(ed25519.Sign(k.device.DWK, rm))
	wantStatus(t, h.req("POST", "/api/v1/writers/revoke", k.token, revoke), http.StatusNoContent)
	if live := k.verifyHistory(k.token); live[d2.WriterID] || !live[k.device.WriterID] {
		t.Fatalf("live after revocation: %v", live)
	}
	// The revoked writer's session is gone.
	wantStatus(t, h.req("GET", "/api/v1/keys", tok2, nil), http.StatusUnauthorized)
}

func mustB64(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestWrapPutNeedsItsOwnCredentialAndTheWriterSignature(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	cred := k.authn.CredID
	wrap := prfWrap(9)
	put := func(token string, sig []byte, su *StepUpWire, w []byte) *PutKeyWrapRequest {
		return &PutKeyWrapRequest{CredentialID: b64url(cred), Wrap: b64(w), WrapVersion: 1, DWKSig: b64(sig), StepUp: su}
	}
	sign := func(su *StepUpWire, w []byte) []byte {
		nonce, _ := base64.RawURLEncoding.DecodeString(su.Nonce)
		m, _ := keyproto.WrapPutMessage(nonce, cred, w)
		return ed25519.Sign(k.device.DWK, m)
	}
	// Shape first.
	su := k.stepUp(k.token, keyproto.ActionKeysWrapPut, cred)
	wantError(t, h.req("POST", "/api/v1/keys/wraps", k.token, put(k.token, sign(su, wrap[:126]), su, wrap[:126])), "bad_request")
	// An unbound session.
	unbound := h.session(k.user)
	su2 := k.stepUp(unbound, keyproto.ActionKeysWrapPut, cred)
	wantError(t, h.req("POST", "/api/v1/keys/wraps", unbound, put(unbound, sign(su2, wrap), su2, wrap)), "writer_unbound")
	// A DWK signature over another wrap.
	su = k.stepUp(k.token, keyproto.ActionKeysWrapPut, cred)
	w := h.req("POST", "/api/v1/keys/wraps", k.token, put(k.token, sign(su, prfWrap(8)), su, wrap))
	wantStatus(t, w, http.StatusBadRequest)
	wantError(t, w, "bad_signature")
	// The good one.
	su = k.stepUp(k.token, keyproto.ActionKeysWrapPut, cred)
	wantStatus(t, h.req("POST", "/api/v1/keys/wraps", k.token, put(k.token, sign(su, wrap), su, wrap)), http.StatusNoContent)
	got := decodeJSON[KeyWrapsResponse](t, h.req("GET", "/api/v1/keys/wraps", k.token, nil))
	if len(got.Wraps) != 1 || got.Wraps[0].Wrap != b64(wrap) {
		t.Fatalf("wraps %+v", got)
	}
	// Delete it under keys.wrap.delete.
	su = k.stepUp(k.token, keyproto.ActionKeysWrapDelete, cred)
	wantStatus(t, h.req("DELETE", "/api/v1/keys/wraps", k.token, DeleteKeyWrapRequest{CredentialID: b64url(cred), StepUp: su}),
		http.StatusNoContent)
	if n := h.countWraps(k.user); n != 0 {
		t.Fatalf("%d wraps after the delete", n)
	}
}

func TestStepUpBeginOverHTTP(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	ph := hex.EncodeToString(make([]byte, 32))
	wantError(t, h.req("POST", "/api/v1/auth/step-up/begin", k.token, StepUpBeginRequest{Action: "passkey.delete", ParamsHash: "zz", ProofKind: "passkey"}), "bad_request")
	wantError(t, h.req("POST", "/api/v1/auth/step-up/begin", k.token, StepUpBeginRequest{Action: "keys.bootstrap", ParamsHash: ph, ProofKind: "device"}), "bad_request")
	unbound := h.session(k.user)
	wantError(t, h.req("POST", "/api/v1/auth/step-up/begin", unbound, StepUpBeginRequest{Action: "passkey.delete", ParamsHash: ph, ProofKind: "device"}), "writer_unbound")
	w := h.req("POST", "/api/v1/auth/step-up/begin", k.token, StepUpBeginRequest{Action: "passkey.delete", ParamsHash: ph, ProofKind: "passkey"})
	wantStatus(t, w, http.StatusOK)
	b := decodeJSON[StepUpBeginResponse](t, w)
	if b.RPID != authtest.RPID || len(b.AllowCredentials) != 1 || b.AllowCredentials[0] != b64url(k.authn.CredID) {
		t.Fatalf("begin %+v", b)
	}
	wantStatus(t, h.req("POST", "/api/v1/auth/step-up/begin", "", StepUpBeginRequest{}), http.StatusUnauthorized)
}
