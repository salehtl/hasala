package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
)

// accounts enables the account ceremonies with fixed keys and a fake mail
// sender whose sends run inline.
func (h *harness) accounts() (*authkeys.Keys, *mail.Fake, *mailq.Queue) {
	h.t.Helper()
	keys, err := authkeys.New(bytes.Repeat([]byte{1}, 32), map[int][]byte{1: bytes.Repeat([]byte{2}, 32)}, 1)
	if err != nil {
		h.t.Fatal(err)
	}
	fake := &mail.Fake{}
	q := &mailq.Queue{Pool: h.pool, Sender: fake, Tagger: keys.EmailTag, Logf: func(string, ...any) {}}
	m := &auth.Mailer{Queue: q, Keys: keys, Async: func(f func()) { f() }}
	q.Renderers = m.Renderers()
	h.srv.EnableAccounts(keys, nil, m)
	// Tests make more device-freeze attempts per writer than the hourly burst.
	h.srv.DevFreezeWriter = NewLimiter(100, 100, 16, nil)
	h.h = h.srv.Handler()
	return keys, fake, q
}

var apiCodeRe = regexp.MustCompile(`Your Hasala code is ([0-9]{6})\.`)

func lastCodeTo(t *testing.T, fake *mail.Fake, addr string) string {
	t.Helper()
	ms := fake.To(addr)
	for i := len(ms) - 1; i >= 0; i-- {
		if m := apiCodeRe.FindStringSubmatch(ms[i].Text); m != nil {
			return m[1]
		}
	}
	t.Fatalf("no code to %s", addr)
	return ""
}

// passwordAccount signs an account up over HTTP with a printed invite, a
// signup code and a password (C1-P), and answers its address, S, device and
// session.
type pwAccount struct {
	addr   string
	s      []byte
	device *authtest.Device
	acct   *authtest.Account
	token  string
	user   string
}

func (h *harness) passwordSignup(keys *authkeys.Keys, fake *mail.Fake, addr string) pwAccount {
	h.t.Helper()
	code, err := auth.MintInvite(bg, h.pool, auth.MintOptions{Now: time.Now()})
	if err != nil {
		h.t.Fatal(err)
	}
	w := h.req("POST", "/api/v1/auth/signup/begin", "", SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya Rahman"})
	wantStatus(h.t, w, http.StatusOK)
	sb := decodeJSON[SignupBeginResponse](h.t, w)
	if sb.EmailProven {
		h.t.Fatal("a printed invite proved the address")
	}
	wantStatus(h.t, h.req("POST", "/api/v1/auth/signup/verify", "", SignupVerifyRequest{SignupID: sb.SignupID,
		Code: lastCodeTo(h.t, fake, addr)}), http.StatusNoContent)
	salt, _ := base64.StdEncoding.DecodeString(sb.Salt)
	nonce, _ := base64.StdEncoding.DecodeString(sb.Nonce)
	a := pwAccount{addr: addr, s: cryptoref.Stretch("correct horse battery staple", salt, addr), device: authtest.NewDevice(h.t)}
	a.acct = authtest.NewAccount(h.t, mustUUID(h.t, sb.UserID))
	sh := sha256.Sum256(a.s)
	b := a.acct.BuildBootstrap(h.t, a.device, addr, nonce, keyproto.AuthKindPassword, sh[:], nil, nil)
	p := b.Payload
	w = h.req("POST", "/api/v1/auth/password/register", "", PasswordRegisterRequest{SignupID: sb.SignupID, Verifier: b64(a.s),
		Bootstrap: BootstrapRequest{FormatVersion: 1, AMKCommitment: b64(p.AMKCommitment), AuthorityPubkey: b64(p.AuthorityPubkey),
			RecoveryPubkey: b64(p.RecoveryPubkey), RecoveryWrap: b64(p.RecoveryWrap), PhraseBox: b64(p.PhraseBox),
			EmailHash: b64(p.EmailHash), AuthKind: 2, AuthHash: b64(p.AuthHash),
			Writer: BootstrapWriter{WriterID: a.device.WriterID, Alg: "ed25519", PubKey: b64(a.device.DWKPub()), DAKPubkey: b64(a.device.DAKPub())},
			Nonce:  b64(b.Nonce), AuthoritySig: b64(b.AuthoritySig), RegistrationSig: b64(b.RegistrationSig)}})
	wantStatus(h.t, w, http.StatusCreated)
	out := decodeJSON[WriterSessionResponse](h.t, w)
	if out.WriterID != a.device.WriterID || out.UserID != sb.UserID {
		h.t.Fatalf("password/register answered %+v", out)
	}
	a.token, a.user = out.SessionToken, out.UserID
	return a
}

func (h *harness) passwordLogin(a pwAccount, s []byte) *httptest.ResponseRecorder {
	h.t.Helper()
	w := h.req("POST", "/api/v1/auth/password/login/begin", "", EmailRequest{Email: a.addr})
	wantStatus(h.t, w, http.StatusOK)
	b := decodeJSON[PasswordLoginBeginResponse](h.t, w)
	return h.req("POST", "/api/v1/auth/password/login/finish", "", PasswordLoginFinishRequest{CeremonyID: b.CeremonyID, Verifier: b64(s)})
}

func TestAccountRoutesAreNotMountedWithoutTheKeyFiles(t *testing.T) {
	h := newHarness(t)
	for _, p := range []string{"/api/v1/auth/signup/begin", "/api/v1/auth/password/login/begin", "/api/v1/account/freeze",
		"/api/v1/auth/recover/begin", "/api/v1/auth/device-freeze/challenge"} {
		wantStatus(t, h.req("POST", p, "", map[string]any{}), http.StatusNotFound)
	}
}

func TestPasswordAccountOverHTTP(t *testing.T) {
	h := newHarness(t)
	keys, fake, q := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")

	// GET /account (#40).
	w := h.req("GET", "/api/v1/account", a.token, nil)
	wantStatus(t, w, http.StatusOK)
	acct := decodeJSON[AccountResponse](t, w)
	if acct.Email != a.addr || acct.DisplayName != "Maya Rahman" || !acct.HasPassword || acct.HasPasskey || !acct.HasKeys ||
		acct.Frozen || acct.Restricted || !acct.EmailDeliverable || acct.PasswordSalt != b64(keys.PasswordSalt(a.addr)) {
		t.Fatalf("GET /account %+v", acct)
	}
	// GET /auth/session (#14).
	w = h.req("GET", "/api/v1/auth/session", a.token, nil)
	wantStatus(t, w, http.StatusOK)
	if s := decodeJSON[SessionWire](t, w); s.MintedBy != "password_signup" || s.WriterID == nil || *s.WriterID != a.device.WriterID {
		t.Fatalf("session %+v", s)
	}
	// The display name (#76).
	wantStatus(t, h.req("PUT", "/api/v1/account/display-name", a.token, DisplayNameRequest{DisplayName: "Maya"}), http.StatusNoContent)
	w = h.req("PUT", "/api/v1/account/display-name", a.token, DisplayNameRequest{DisplayName: "maya.example.com"})
	wantStatus(t, w, http.StatusBadRequest)
	if w.Body.String() != `{"error":"bad_name","detail":"display_name: characters"}` {
		t.Fatalf("bad name %s", w.Body.String())
	}

	// Password sign-in (#46, #47) and its uniform failures.
	w = h.passwordLogin(a, a.s)
	wantStatus(t, w, http.StatusOK)
	in := decodeJSON[SignInResponse](t, w)
	if !strings.Contains(w.Body.String(), `"writer_id":null`) || !in.HasKeys || in.Restricted {
		t.Fatalf("login %s", w.Body.String())
	}
	wrong := append([]byte(nil), a.s...)
	wrong[0] ^= 1
	bad := h.passwordLogin(a, wrong)
	nobody := h.passwordLogin(pwAccount{addr: "nobody@example.com"}, a.s)
	for _, w := range []*httptest.ResponseRecorder{bad, nobody} {
		wantStatus(t, w, http.StatusForbidden)
		if w.Body.String() != `{"error":"password_rejected"}` {
			t.Fatalf("a failed sign-in answered %s", w.Body.String())
		}
	}
	wantStatus(t, h.req("POST", "/api/v1/auth/password/login/begin", "", EmailRequest{Email: "café@example.com"}), http.StatusBadRequest)

	// The new sign-in alert carries a freeze link; #64 takes it as text/plain
	// and answers 204 whatever it is given.
	if _, err := q.RunOnce(bg); err != nil {
		t.Fatal(err)
	}
	link := regexp.MustCompile(`freeze#([A-Za-z0-9_-]{43})`).FindStringSubmatch(mailTexts(fake.To(a.addr)))
	if link == nil {
		t.Fatal("no freeze link was mailed")
	}
	for _, body := range []string{"garbage", `{"token":"AAAA"}`, strings.Repeat("x", 1000)} {
		r := httptest.NewRequest("POST", "/api/v1/account/freeze", strings.NewReader(body))
		r.Header.Set("Content-Type", "text/plain")
		rec := httptest.NewRecorder()
		h.h.ServeHTTP(rec, r)
		if rec.Code != http.StatusNoContent || rec.Body.Len() != 0 {
			t.Fatalf("#64 with %q answered %d %q", body[:min(len(body), 10)], rec.Code, rec.Body.String())
		}
	}
	r := httptest.NewRequest("POST", "/api/v1/account/freeze", strings.NewReader(`{"token":"`+link[1]+`"}`))
	r.Header.Set("Content-Type", "text/plain;charset=UTF-8")
	rec := httptest.NewRecorder()
	h.h.ServeHTTP(rec, r)
	wantStatus(t, rec, http.StatusNoContent)

	// Frozen: every session was revoked; a new sign-in is restricted and
	// reaches only GET /account, the unfreeze step-up and unfreeze.
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusUnauthorized)
	w = h.passwordLogin(a, a.s)
	wantStatus(t, w, http.StatusOK)
	restricted := decodeJSON[SignInResponse](t, w)
	if !restricted.Restricted {
		t.Fatal("a sign-in into a frozen account is not restricted")
	}
	wantStatus(t, h.req("GET", "/api/v1/account", restricted.SessionToken, nil), http.StatusOK)
	w = h.req("GET", "/api/v1/sync?stream=hot", restricted.SessionToken, nil)
	wantStatus(t, w, http.StatusForbidden)
	if w.Body.String() != `{"error":"account_frozen"}` {
		t.Fatalf("frozen sync answered %s", w.Body.String())
	}
	ph, _ := keyproto.ParamsHash(keyproto.ActionPasskeyAdd)
	wantStatus(t, h.req("POST", "/api/v1/auth/step-up/begin", restricted.SessionToken, StepUpBeginRequest{
		Action: "passkey.add", ParamsHash: hexs(ph[:]), ProofKind: "passkey"}), http.StatusForbidden)
	ph, _ = keyproto.ParamsHash(keyproto.ActionAccountUnfreeze)
	wantStatus(t, h.req("POST", "/api/v1/auth/step-up/begin", restricted.SessionToken, StepUpBeginRequest{
		Action: "account.unfreeze", ParamsHash: hexs(ph[:]), ProofKind: "passkey"}), http.StatusOK)

	// Auth events (#68).
	w = h.req("GET", "/api/v1/auth/events", restricted.SessionToken, nil)
	wantStatus(t, w, http.StatusForbidden) // not on §9.8's list
}

func TestSignupAnswersAreUniform(t *testing.T) {
	h := newHarness(t)
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")
	_ = a
	code, _ := auth.MintInvite(bg, h.pool, auth.MintOptions{Now: time.Now()})
	shape := func(email string) string {
		w := h.req("POST", "/api/v1/auth/signup/begin", "", SignupBeginRequest{InviteCode: code, Email: email, DisplayName: "Eve"})
		wantStatus(t, w, http.StatusOK)
		out := decodeJSON[SignupBeginResponse](t, w)
		return strings.Join([]string{strings.Repeat("x", len(out.SignupID)), strings.Repeat("x", len(out.Salt)),
			strings.Repeat("x", len(out.Nonce)), map[bool]string{true: "p", false: "u"}[out.EmailProven]}, "|")
	}
	if shape("maya@example.com") != shape("someone@example.com") {
		t.Fatal("signup/begin's answer depends on whether the address has an account")
	}
	w := h.req("POST", "/api/v1/auth/signup/begin", "", SignupBeginRequest{InviteCode: "NOPE", Email: "x@example.com", DisplayName: "Eve"})
	wantStatus(t, w, http.StatusForbidden)
	if w.Body.String() != `{"error":"not_invited"}` {
		t.Fatalf("unknown invite %s", w.Body.String())
	}
	w = h.req("POST", "/api/v1/auth/signup/begin", "", SignupBeginRequest{InviteCode: code, Email: "x@", DisplayName: "Eve"})
	wantStatus(t, w, http.StatusBadRequest)
	if w.Body.String() != `{"error":"bad_email"}` {
		t.Fatalf("bad address %s", w.Body.String())
	}
	// Reset begin (#49) is uniform too.
	r1 := h.req("POST", "/api/v1/auth/password/reset/begin", "", EmailRequest{Email: "maya@example.com"})
	r2 := h.req("POST", "/api/v1/auth/password/reset/begin", "", EmailRequest{Email: "nobody@example.com"})
	wantStatus(t, r1, http.StatusOK)
	wantStatus(t, r2, http.StatusOK)
	if len(r1.Body.String()) != len(r2.Body.String()) {
		t.Fatal("reset/begin's answer depends on the account")
	}
}

func TestDeviceFreezeOverHTTPIsUniform(t *testing.T) {
	h := newHarness(t)
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")
	wantStatus(t, h.req("POST", "/api/v1/auth/device-freeze/challenge", "", DeviceFreezeChallengeRequest{WriterID: "bad"}), http.StatusBadRequest)
	unknown := authtest.NewDevice(t)
	wantStatus(t, h.req("POST", "/api/v1/auth/device-freeze/challenge", "", DeviceFreezeChallengeRequest{WriterID: unknown.WriterID}), http.StatusOK)
	w := h.req("POST", "/api/v1/auth/device-freeze/challenge", "", DeviceFreezeChallengeRequest{WriterID: a.device.WriterID})
	wantStatus(t, w, http.StatusOK)
	nonce, _ := base64.StdEncoding.DecodeString(decodeJSON[DeviceFreezeChallengeResponse](t, w).Nonce)
	msg, _ := keyproto.DeviceFreezeMessage(nonce, mustUUID(t, a.user), a.device.WriterID)
	w = h.req("POST", "/api/v1/auth/device-freeze", "", DeviceFreezeRequest{WriterID: a.device.WriterID, Nonce: b64(nonce),
		Sig: b64(unknown.SignDAK(t, msg))})
	wantStatus(t, w, http.StatusForbidden)
	if w.Body.String() != `{"error":"freeze_refused"}` {
		t.Fatalf("a bad device freeze answered %s", w.Body.String())
	}
	w = h.req("POST", "/api/v1/auth/device-freeze/challenge", "", DeviceFreezeChallengeRequest{WriterID: a.device.WriterID})
	nonce, _ = base64.StdEncoding.DecodeString(decodeJSON[DeviceFreezeChallengeResponse](t, w).Nonce)
	msg, _ = keyproto.DeviceFreezeMessage(nonce, mustUUID(t, a.user), a.device.WriterID)
	wantStatus(t, h.req("POST", "/api/v1/auth/device-freeze", "", DeviceFreezeRequest{WriterID: a.device.WriterID,
		Nonce: b64(nonce), Sig: b64(a.device.SignDAK(t, msg))}), http.StatusNoContent)
	wantStatus(t, h.req("GET", "/api/v1/sync?stream=hot", a.token, nil), http.StatusUnauthorized)
}

func TestClientKeyTrustsCloudflareOnlyFromLoopback(t *testing.T) {
	s := &Server{TrustedProxy: ProxyCloudflare}
	req := func(remote, cf string, extra map[string]string) *http.Request {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = remote
		if cf != "" {
			r.Header.Set("Cf-Connecting-Ip", cf)
		}
		for k, v := range extra {
			r.Header.Set(k, v)
		}
		return r
	}
	for _, c := range []struct {
		remote, cf string
		extra      map[string]string
		want       string
	}{
		{"127.0.0.1:5000", "203.0.113.7", nil, "4:203.0.113.7"},
		{"[::1]:5000", "2001:db8:1:2:3:4:5:6", nil, "6:20010db800010002"},
		{"[::1]:5000", "2001:db8:1:2:ffff:4:5:6", nil, "6:20010db800010002"},
		{"127.0.0.1:5000", "", nil, "local"},
		{"127.0.0.1:5000", "not-an-ip", nil, "local"},
		{"198.51.100.9:443", "203.0.113.7", nil, "peer:198.51.100.9"},
		{"127.0.0.1:5000", "", map[string]string{"X-Forwarded-For": "203.0.113.7", "True-Client-IP": "203.0.113.7"}, "local"},
	} {
		if got := s.clientKey(req(c.remote, c.cf, c.extra)); got != c.want {
			t.Errorf("%s with %q: %q, want %q", c.remote, c.cf, got, c.want)
		}
	}
	none := &Server{TrustedProxy: ProxyNone}
	if got := none.clientKey(req("127.0.0.1:5000", "203.0.113.7", nil)); got != "peer:127.0.0.1" {
		t.Fatalf("trusted_proxy none trusted the header: %q", got)
	}
}

func hexs(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 0, 2*len(b))
	for _, c := range b {
		out = append(out, digits[c>>4], digits[c&15])
	}
	return string(out)
}

func mailTexts(ms []mail.Message) string {
	var b strings.Builder
	for _, m := range ms {
		b.WriteString(m.Text)
	}
	return b.String()
}
