package api

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
)

// AT-DEL-3 (spec 02 §9.6): a suspended account keeps account deletion, and
// step-up begin for account.delete only.
func TestASuspendedAccountCanStillDeleteItself(t *testing.T) {
	h := newHarness(t).passkeys()
	acc := h.deletable(t, "suspended-delete")
	h.suspend(acc.u)

	other, _ := keyproto.ParamsHash(keyproto.ActionWriterRevoke, []byte("ios-00000000-0000-4000-8000-000000000206"))
	w := h.req("POST", "/api/v1/auth/step-up/begin", acc.tok, StepUpBeginRequest{
		Action: string(keyproto.ActionWriterRevoke), ParamsHash: hex.EncodeToString(other[:]), ProofKind: "passkey"})
	wantStatus(t, w, http.StatusForbidden)
	if got := decodeJSON[errorBody](t, w).Error; got != "account_suspended" {
		t.Fatalf("step-up begin for writer.revoke while suspended: %q", got)
	}
	del, _ := keyproto.ParamsHash(keyproto.ActionAccountDelete)
	wantStatus(t, h.req("POST", "/api/v1/auth/step-up/begin", acc.tok, StepUpBeginRequest{
		Action: string(keyproto.ActionAccountDelete), ParamsHash: hex.EncodeToString(del[:]), ProofKind: "passkey"}), http.StatusOK)

	nonce := h.deleteChallenge(t, acc.tok)
	wantStatus(t, h.req("DELETE", "/api/v1/account", acc.tok, acc.body(t, nonce)), http.StatusNoContent)
	if h.accountExists(t, acc.u) {
		t.Fatal("a suspended account could not delete itself")
	}
}

// AT-RL-7 (spec 02 §16.2): a busy PBKDF2 gate answers 503 unavailable with
// Retry-After: 2 and runs no PBKDF2; the same request succeeds once it frees.
func TestABusyGateAnswers503WithRetryAfter(t *testing.T) {
	h := newHarness(t)
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "gate@example.com")

	g := authkeys.NewGate(1, 0, 10*time.Millisecond)
	release, err := g.Acquire(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	h.srv.Accounts.Gate, h.srv.StepUp.Gate = g, g
	hashes := keys.HashCount()
	w := h.passwordLogin(a, a.s)
	wantStatus(t, w, http.StatusServiceUnavailable)
	if w.Body.String() != `{"error":"unavailable"}` || w.Header().Get("Retry-After") != "2" {
		t.Fatalf("a busy gate answered %s with Retry-After %q", w.Body.String(), w.Header().Get("Retry-After"))
	}
	if keys.HashCount() != hashes {
		t.Fatal("a refused request ran a PBKDF2")
	}
	release()
	wantStatus(t, h.passwordLogin(a, a.s), http.StatusOK)
	if keys.HashCount() != hashes+1 {
		t.Fatalf("%d PBKDF2 runs for one sign-in", keys.HashCount()-hashes)
	}
}

// logSink collects every log line the server, the mail queue and the mailer
// write, and the standard and slog loggers' too.
type logSink struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (l *logSink) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

func (l *logSink) logf(format string, args ...any) { fmt.Fprintf(l, format+"\n", args...) }

func (l *logSink) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.String()
}

// AT-LOG-1, AT-NAME-4: the account ceremonies, driven through their success
// and failure paths, log no session token, address, address tag, S, code,
// freeze token, nonce, display name or Cf-Connecting-Ip value.
func TestNothingSecretReachesTheLog(t *testing.T) {
	sink := &logSink{}
	prevOut, prevFlags, prevSlog := log.Writer(), log.Flags(), slog.Default()
	log.SetOutput(sink)
	slog.SetDefault(slog.New(slog.NewTextHandler(sink, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { log.SetOutput(prevOut); log.SetFlags(prevFlags); slog.SetDefault(prevSlog) })

	h := newHarness(t)
	h.srv.Logf = sink.logf
	h.srv.TrustedProxy = ProxyCloudflare
	const clientIP = "203.0.113.77"
	keys, err := authkeys.New(bytes.Repeat([]byte{1}, 32), map[int][]byte{1: bytes.Repeat([]byte{2}, 32)}, 1)
	if err != nil {
		t.Fatal(err)
	}
	fake := &mail.Fake{}
	q := &mailq.Queue{Pool: h.pool, Sender: fake, Tagger: keys.EmailTag, Logf: sink.logf}
	m := &auth.Mailer{Queue: q, Keys: keys, Async: func(f func()) { f() }, Logf: sink.logf}
	q.Renderers = m.Renderers()
	h.srv.EnableAccounts(keys, nil, m)
	inner := h.srv.Handler()
	h.h = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.RemoteAddr = "127.0.0.1:5000"
		r.Header.Set("Cf-Connecting-Ip", clientIP)
		inner.ServeHTTP(w, r)
	})

	const addr = "canary.person@example.com"
	a := h.passwordSignup(keys, fake, addr)
	// From here, the provider refuses one send, so the worker logs a failure.
	failOnce := true
	fake.Err = func(mail.Message) error {
		if failOnce {
			failOnce = false
			return fmt.Errorf("mail: the provider said no (HTTP 503)")
		}
		return nil
	}
	// Sign-ins: right, wrong, and an unknown ceremony.
	w := h.passwordLogin(a, a.s)
	wantStatus(t, w, http.StatusOK)
	second := decodeJSON[SignInResponse](t, w).SessionToken
	wrong := append([]byte(nil), a.s...)
	wrong[0] ^= 1
	wantStatus(t, h.passwordLogin(a, wrong), http.StatusForbidden)
	h.req("POST", "/api/v1/auth/password/login/finish", "", PasswordLoginFinishRequest{CeremonyID: "nope", Verifier: b64(a.s)})
	// Signup and reset with wrong codes, for the account and a stranger.
	code, _ := auth.MintInvite(bg, h.pool, auth.MintOptions{Now: time.Now()})
	w = h.req("POST", "/api/v1/auth/signup/begin", "", SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Canary Name"})
	sb := decodeJSON[SignupBeginResponse](t, w)
	h.req("POST", "/api/v1/auth/signup/verify", "", SignupVerifyRequest{SignupID: sb.SignupID, Code: "999999"})
	h.req("POST", "/api/v1/auth/signup/begin", "", SignupBeginRequest{InviteCode: "NOPE", Email: addr, DisplayName: "Canary Name"})
	for _, e := range []string{addr, "stranger.canary@example.com", "not an address"} {
		w = h.req("POST", "/api/v1/auth/password/reset/begin", "", EmailRequest{Email: e})
		if w.Code == http.StatusOK {
			rb := decodeJSON[ResetBeginResponse](t, w)
			h.req("POST", "/api/v1/auth/password/reset/verify", "", ResetCodeRequest{ResetID: rb.ResetID, Code: "123456"})
		}
	}
	// Freeze links, device freeze, bad sessions, a bad step-up.
	h.req("POST", "/api/v1/account/freeze", "", map[string]string{"token": strings.Repeat("A", 43)})
	unknown := authtest.NewDevice(t)
	h.req("POST", "/api/v1/auth/device-freeze/challenge", "", DeviceFreezeChallengeRequest{WriterID: unknown.WriterID})
	h.req("POST", "/api/v1/auth/device-freeze", "", DeviceFreezeRequest{WriterID: a.device.WriterID, Nonce: b64(make([]byte, 32)),
		Sig: b64(make([]byte, 64))})
	h.req("GET", "/api/v1/account", "not-a-token", nil)
	h.req("POST", "/api/v1/auth/step-up/begin", a.token, StepUpBeginRequest{Action: "nonsense.action", ParamsHash: strings.Repeat("0", 64), ProofKind: "evil-kind"})
	h.req("PUT", "/api/v1/account/display-name", a.token, map[string]string{"display_name": "Canary\u0000Name"})
	// The worker: one transient failure, then the rest.
	for i := 0; i < 3; i++ {
		if _, err := q.RunOnce(bg); err != nil {
			t.Fatal(err)
		}
	}

	secrets := map[string]string{
		"the address":         addr,
		"the stranger":        "stranger.canary@example.com",
		"the display name":    "Canary Name",
		"the client IP":       clientIP,
		"a session token":     a.token,
		"the second session":  second,
		"S (b64)":             b64(a.s),
		"S (b64url)":          b64url(a.s),
		"S (hex)":             hex.EncodeToString(a.s),
		"the tag (hex)":       hex.EncodeToString(keys.EmailTag(addr)),
		"the tag (b64)":       b64(keys.EmailTag(addr)),
		"the tag (b64url)":    b64url(keys.EmailTag(addr)),
		"the signup nonce":    sb.Nonce,
		"the signup id":       sb.SignupID,
		"an evil proof kind":  "evil-kind",
		"the salt (b64)":      b64(keys.PasswordSalt(addr)),
		"the stranger's salt": b64(keys.PasswordSalt("stranger.canary@example.com")),
	}
	codeRe := regexp.MustCompile(`\b[0-9]{6}\b`)
	tokenRe := regexp.MustCompile(`freeze#([A-Za-z0-9_-]{43})`)
	for i, msg := range fake.Sent() {
		for _, c := range codeRe.FindAllString(msg.Text, -1) {
			secrets[fmt.Sprintf("a mailed code (message %d)", i)] = c
		}
		for _, m := range tokenRe.FindAllStringSubmatch(msg.Text, -1) {
			secrets[fmt.Sprintf("a freeze token (message %d)", i)] = m[1]
		}
	}
	logged := sink.String()
	if logged == "" {
		t.Fatal("nothing was logged: the canary proves nothing")
	}
	for what, v := range secrets {
		if v == "" {
			continue
		}
		if strings.Contains(strings.ToLower(logged), strings.ToLower(v)) {
			t.Errorf("%s reached the log", what)
		}
	}
	if t.Failed() {
		t.Logf("the log:\n%s", logged)
	}
}
