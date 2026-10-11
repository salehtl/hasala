package auth

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// acctFixture is the account ceremonies with fixed server keys, a fake mail
// sender whose sends run inline, and a settable clock.
type acctFixture struct {
	t        *testing.T
	pool     *pgxpool.Pool
	owner    *pgxpool.Pool
	clock    *clock
	keys     *authkeys.Keys
	fake     *mail.Fake
	queue    *mailq.Queue
	mailer   *Mailer
	sessions *Sessions
	passkeys *Passkeys
	stepUp   *StepUp
	writers  *Writers
	keysSvc  *AccountKeys
	acct     *Accounts
}

var testSaltKey = bytes.Repeat([]byte{0x5a}, 32)
var testAuthKey = bytes.Repeat([]byte{0xa5}, 32)

var addrN atomic.Int64

// newAddr is a fresh address.
func newAddr() string { return fmt.Sprintf("maya.%d@example.com", addrN.Add(1)) }

func newAcctFixture(t *testing.T) *acctFixture {
	t.Helper()
	pool, owner := pgtest.NewWithOwner(t)
	c := newClock()
	keys, err := authkeys.New(testSaltKey, map[int][]byte{1: testAuthKey}, 1)
	if err != nil {
		t.Fatal(err)
	}
	f := &acctFixture{t: t, pool: pool, owner: owner, clock: c, keys: keys, fake: &mail.Fake{}}
	f.queue = mailq.New(pool, f.fake, keys)
	f.mailer = &Mailer{Queue: f.queue, Keys: keys, Now: c.now, Async: func(fn func()) { fn() }}
	f.mailer.Register(f.queue)
	f.sessions = &Sessions{Pool: pool, TTL: 30 * 24 * time.Hour, Now: c.now}
	f.passkeys = newPasskeys(t, pool)
	f.passkeys.Now, f.passkeys.Mail = c.now, f.mailer
	f.stepUp = &StepUp{Pool: pool, Passkeys: f.passkeys, Keys: keys, Mail: f.mailer, Now: c.now}
	f.passkeys.StepUp = f.stepUp
	f.writers = &Writers{Pool: pool, StepUp: f.stepUp, Mail: f.mailer, Now: c.now}
	f.keysSvc = &AccountKeys{Pool: pool, StepUp: f.stepUp, Now: c.now}
	f.acct = &Accounts{Pool: pool, Keys: keys, Sessions: f.sessions, Passkeys: f.passkeys, StepUp: f.stepUp,
		Mail: f.mailer, Now: c.now}
	return f
}

var codeRe = regexp.MustCompile(`Your Hasala code is ([0-9]{6})\.`)

// lastCode is the newest code mailed to addr.
func (f *acctFixture) lastCode(addr string) string {
	f.t.Helper()
	msgs := f.fake.To(addr)
	for i := len(msgs) - 1; i >= 0; i-- {
		if m := codeRe.FindStringSubmatch(msgs[i].Text); m != nil {
			return m[1]
		}
	}
	f.t.Fatalf("no code was mailed to %s", addr)
	return ""
}

// sendQueued runs the mail worker once.
func (f *acctFixture) sendQueued() {
	f.t.Helper()
	if _, err := f.queue.Drain(bgctx); err != nil {
		f.t.Fatal(err)
	}
}

var freezeLinkRe = regexp.MustCompile(`https://hasala\.app/freeze#([A-Za-z0-9_-]{43})`)

// freezeToken is the newest freeze link's token mailed to addr.
func (f *acctFixture) freezeToken(addr string) string {
	f.t.Helper()
	f.sendQueued()
	msgs := f.fake.To(addr)
	for i := len(msgs) - 1; i >= 0; i-- {
		if m := freezeLinkRe.FindStringSubmatch(msgs[i].Text); m != nil {
			return m[1]
		}
	}
	f.t.Fatalf("no freeze link was mailed to %s", addr)
	return ""
}

// addressedInvite mints an emailed invite for addr with a link key, as 07's
// worker does, and answers the code and the b64url link key.
func (f *acctFixture) addressedInvite(addr string) (string, string) {
	f.t.Helper()
	lk := authtest.RandBytesTB(f.t, 32)
	code, err := MintInvite(bgctx, f.pool, MintOptions{EmailTag: f.keys.EmailTag(addr), LinkKey: lk, Now: f.clock.now()})
	if err != nil {
		f.t.Fatal(err)
	}
	return code, base64.RawURLEncoding.EncodeToString(lk)
}

func (f *acctFixture) printedInvite(review bool) string {
	f.t.Helper()
	code, err := MintInvite(bgctx, f.pool, MintOptions{Review: review, Now: f.clock.now()})
	if err != nil {
		f.t.Fatal(err)
	}
	return code
}

// provenSignup is signup/begin with an addressed invite's link.
func (f *acctFixture) provenSignup(addr, name string) SignupBegun {
	f.t.Helper()
	norm, err := keyproto.EmailNorm(addr)
	if err != nil {
		f.t.Fatal(err)
	}
	code, lk := f.addressedInvite(norm)
	s, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: name, InviteLinkKey: lk})
	if err != nil {
		f.t.Fatal(err)
	}
	if !s.EmailProven {
		f.t.Fatal("the link did not prove the address")
	}
	return s
}

// member is one account taken through password signup (C1-P), with its
// device and its key material.
type member struct {
	f      *acctFixture
	addr   string
	pw     string
	s      []byte // S
	user   SignedIn
	acct   *authtest.Account
	device *authtest.Device
	token  string
}

func (f *acctFixture) stretch(addr, pw string) []byte {
	return cryptoref.Stretch(pw, f.keys.PasswordSalt(addr), addr)
}

// passwordMember signs a new account up with a password on a proven address.
func (f *acctFixture) passwordMember(name string) *member {
	f.t.Helper()
	addr := newAddr()
	s := f.provenSignup(addr, name)
	m := &member{f: f, addr: addr, pw: "correct horse battery staple"}
	m.s = f.stretch(addr, m.pw)
	m.acct = authtest.NewAccount(f.t, s.UserID)
	m.device = authtest.NewDevice(f.t)
	b := f.passwordBootstrap(m, s)
	out, err := f.acct.PasswordSignup(bgctx, s.SignupID, m.s, b)
	if err != nil {
		f.t.Fatalf("password signup: %v", err)
	}
	m.token = out.Session.Token
	m.user = SignedIn{Session: out.Session, UserID: out.UserID, WriterID: out.WriterID, HasKeys: true}
	return m
}

func (f *acctFixture) passwordBootstrap(m *member, s SignupBegun) Bootstrap {
	f.t.Helper()
	sh := sumBytes(m.s)
	return toBootstrap(m.acct.BuildBootstrap(f.t, m.device, m.addr, s.Nonce, keyproto.AuthKindPassword, sh, nil, nil))
}

func sumBytes(b []byte) []byte {
	h, _ := verifierHash(b)
	return h
}

func (m *member) info() SessionInfo {
	m.f.t.Helper()
	i, err := m.f.sessions.Info(bgctx, m.token)
	if err != nil {
		m.f.t.Fatal(err)
	}
	return i
}

// deviceStepUp begins and proves a device step-up (the DAK plus S) for action
// on the member's session.
func (m *member) deviceStepUp(action keyproto.Action, s []byte, fields ...[]byte) *StepUpObject {
	m.f.t.Helper()
	i := m.info()
	ph, _ := keyproto.ParamsHash(action, fields...)
	b, err := m.f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, action, ph[:], keyproto.ProofDevice)
	if err != nil {
		m.f.t.Fatalf("begin %s: %v", action, err)
	}
	msg, _ := keyproto.DeviceStepUpMessage(b.Challenge, m.device.WriterID)
	return &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "device", WriterID: m.device.WriterID,
		Sig: m.device.SignDAK(m.f.t, msg), Verifier: s}}
}

// loginPassword signs in with S; device binds it when non-nil.
func (m *member) loginPassword(s []byte, device *authtest.Device) (SignedIn, error) {
	m.f.t.Helper()
	b, err := m.f.acct.PasswordLoginBegin(bgctx, m.addr)
	if err != nil {
		m.f.t.Fatal(err)
	}
	var d *DeviceBinding
	if device != nil {
		msg, _ := keyproto.SessionBindMessage(b.Nonce, device.WriterID)
		d = &DeviceBinding{WriterID: device.WriterID, Sig: ed25519.Sign(device.DWK, msg)}
	}
	return m.f.acct.PasswordLoginFinish(bgctx, b.CeremonyID, s, d)
}

func (f *acctFixture) count(sql string, args ...any) int {
	f.t.Helper()
	return countRows(f.t, f.pool, sql, args...)
}

func mailTexts(ms []mail.Message) string {
	var b strings.Builder
	for _, m := range ms {
		b.WriteString(m.Subject + "\n" + m.Text + "\n")
	}
	return b.String()
}
