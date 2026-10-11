package auth

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// registerPasskey runs register/begin and finish for a signup and answers the
// account.
func (f *acctFixture) registerPasskey(signupID string) (Registered, *authtest.Authenticator, error) {
	f.t.Helper()
	id, opts, _, err := f.passkeys.BeginRegistration(bgctx, signupID, authtest.AuthorityPub(f.t))
	if err != nil {
		return Registered{}, nil, err
	}
	a := authtest.New(f.t)
	r, err := f.passkeys.FinishRegistrationSession(bgctx, id, a.Create(f.t, opts), f.sessions)
	return r, a, err
}

func TestAProvenSignupSendsNoCodeAndCreatesTheAccount(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	// A waitlist entry for the address, as 07's approval leaves it.
	if _, err := f.pool.Exec(bgctx,
		`INSERT INTO waitlist_entries (email_tag, email_norm, state, source, created_at, updated_at, confirmed_at, invited_at)
		 VALUES ($1, $2, 'invited', 'web', now(), now(), now(), now())`, f.keys.EmailTag(addr), addr); err != nil {
		t.Fatal(err)
	}
	s := f.provenSignup(strings.ToUpper(addr), "  Maya   Rahman ")
	if len(f.fake.Sent()) != 0 {
		t.Fatal("a proven signup mailed something")
	}
	if !sameBytes(s.Salt, f.keys.PasswordSalt(addr)) {
		t.Fatal("the salt is not s_srv(email_norm)")
	}
	r, _, err := f.registerPasskey(s.SignupID)
	if err != nil {
		t.Fatal(err)
	}
	if r.UserID != s.UserID || r.Session.Token == "" {
		t.Fatalf("registered %v, want the reserved id %v and a session", r.UserID, s.UserID)
	}
	var (
		email, name string
		verified    time.Time
		review      bool
		pending     []byte
	)
	if err := f.pool.QueryRow(bgctx,
		`SELECT email_norm, display_name, email_verified_at, review_account, authority_pubkey_pending FROM users WHERE id = $1`,
		r.UserID).Scan(&email, &name, &verified, &review, &pending); err != nil {
		t.Fatal(err)
	}
	if email != addr || name != "Maya Rahman" || review || len(pending) != 32 {
		t.Fatalf("account %q %q review=%v pending=%d", email, name, review, len(pending))
	}
	if n := f.count(`SELECT count(*) FROM invite_codes WHERE state = 'redeemed' AND redeemed_by = $1`, r.UserID); n != 1 {
		t.Fatal("the invite was not redeemed by the account")
	}
	// 07's join hook: the entry joined and forgot its address.
	var (
		state string
		norm  *string
	)
	if err := f.pool.QueryRow(bgctx, `SELECT state, email_norm FROM waitlist_entries`).Scan(&state, &norm); err != nil {
		t.Fatal(err)
	}
	if state != "joined" || norm != nil {
		t.Fatalf("waitlist entry %s, address kept: %v", state, norm != nil)
	}
	i, err := f.sessions.Info(bgctx, r.Session.Token)
	if err != nil || i.MintedBy != MintedRegister || i.WriterID != "" {
		t.Fatalf("session %+v %v", i, err)
	}
}

func TestACodeSignupVerifiesTheAddressWithAnEmailedCode(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	s, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: f.printedInvite(false), Email: addr, DisplayName: "Maya"})
	if err != nil {
		t.Fatal(err)
	}
	if s.EmailProven {
		t.Fatal("a printed code proved an address")
	}
	if _, _, err := f.registerPasskey(s.SignupID); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("register before the code: %v", err)
	}
	code := f.lastCode(addr)
	msg := f.fake.To(addr)[0]
	if !strings.HasPrefix(msg.Text, "Hi,\n\n") || msg.Subject != "Your Hasala code" {
		t.Fatalf("a signup code greets no one by name: %q", msg.Text[:20])
	}
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	if err := f.acct.SignupVerify(bgctx, s.SignupID, wrong); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a wrong code: %v", err)
	}
	if err := f.acct.SignupVerify(bgctx, s.SignupID, code); err != nil {
		t.Fatalf("the right code: %v", err)
	}
	if err := f.acct.SignupVerify(bgctx, s.SignupID, code); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a code used twice: %v", err)
	}
	if _, _, err := f.registerPasskey(s.SignupID); err != nil {
		t.Fatal(err)
	}
	// The code row stores a MAC, never the code.
	var mac []byte
	if err := f.pool.QueryRow(bgctx, `SELECT code_mac FROM email_codes`).Scan(&mac); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(mac), code) {
		t.Fatal("the code is stored")
	}
}

func TestFiveWrongCodesBurnTheCodeAndPauseTheAddress(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	code := f.printedInvite(false)
	s, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya"})
	if err != nil {
		t.Fatal(err)
	}
	right := f.lastCode(addr)
	wrong := "000000"
	if right == wrong {
		wrong = "111111"
	}
	for i := 0; i < 5; i++ {
		if err := f.acct.SignupVerify(bgctx, s.SignupID, wrong); !errors.Is(err, ErrCodeRejected) {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	if err := f.acct.SignupVerify(bgctx, s.SignupID, right); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("the right code after a burn: %v", err)
	}
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya"}); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a new signup code while paused: %v", err)
	}
	f.clock.advance(codePause + time.Second)
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya"}); err != nil {
		t.Fatalf("after the pause: %v", err)
	}
}

func TestCodeSendsAreCountedPerAddressAndHour(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	code := f.printedInvite(false)
	for i := 0; i < codeSendsPerHour; i++ {
		if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya"}); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya"}); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("the sixth code in an hour: %v", err)
	}
	// Another address is unaffected.
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: newAddr(), DisplayName: "Maya"}); err != nil {
		t.Fatal(err)
	}
}

// An addressed invite opens only its address, with the same bytes as an
// unknown code (07 Q6); a wrong link key is not an error, it only leaves the
// address unproven.
func TestAnAddressedInviteIsBoundToItsAddress(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	code, lk := f.addressedInvite(addr)
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: newAddr(), DisplayName: "Eve", InviteLinkKey: lk}); !errors.Is(err, ErrNotInvited) {
		t.Fatalf("another address: %v", err)
	}
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: "ABCDEFGHIJKLMNOPQRSTUVWX", Email: addr, DisplayName: "Eve"}); !errors.Is(err, ErrNotInvited) {
		t.Fatalf("an unknown code: %v", err)
	}
	other := authtest.RandBytesTB(t, 32)
	s, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya",
		InviteLinkKey: strings.Repeat("A", 43)})
	if err != nil || s.EmailProven {
		t.Fatalf("a wrong link key: %+v %v", s, err)
	}
	_ = other
	s, err = f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya"})
	if err != nil || s.EmailProven {
		t.Fatalf("the code without its key proved the address: %+v %v", s, err)
	}
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya", InviteLinkKey: "short"}); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("a malformed link key: %v", err)
	}
}

func TestOnlyAnActiveUnexpiredInviteIsRedeemable(t *testing.T) {
	f := newAcctFixture(t)
	code := f.printedInvite(false)
	if _, err := f.pool.Exec(bgctx, `UPDATE invite_codes SET state = 'revoked', closed_at = now()`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: newAddr(), DisplayName: "Maya"}); !errors.Is(err, ErrNotInvited) {
		t.Fatalf("a revoked invite: %v", err)
	}
	code = f.printedInvite(false)
	f.clock.advance(15 * 24 * time.Hour)
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: newAddr(), DisplayName: "Maya"}); !errors.Is(err, ErrNotInvited) {
		t.Fatalf("an expired invite: %v", err)
	}
}

// Two signups begun on one invite: the redemption in the account transaction
// is the gate, and only the first account exists.
func TestTwoSignupsOnOneInviteYieldOneAccount(t *testing.T) {
	f := newAcctFixture(t)
	code := f.printedInvite(false)
	var ids []string
	for _, addr := range []string{newAddr(), newAddr()} {
		s, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya"})
		if err != nil {
			t.Fatal(err)
		}
		if err := f.acct.SignupVerify(bgctx, s.SignupID, f.lastCode(addr)); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, s.SignupID)
	}
	if _, _, err := f.registerPasskey(ids[0]); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.registerPasskey(ids[1]); !errors.Is(err, ErrNotInvited) {
		t.Fatalf("the second redemption: %v", err)
	}
	if n := countUsers(t, f.pool); n != 1 {
		t.Fatalf("%d accounts", n)
	}
}

// signup/begin answers the same for an address that already has an account,
// and emails a notice in place of a code; a proven address in use is the one
// distinguishable case (409 email_in_use, only to the invite's holder).
func TestAnAddressInUseGetsTheSameAnswerAndANotice(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.fake.Reset()
	s, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: f.printedInvite(false), Email: m.addr, DisplayName: "Eve"})
	if err != nil || s.EmailProven {
		t.Fatalf("%+v %v", s, err)
	}
	msgs := f.fake.To(m.addr)
	if len(msgs) != 1 || msgs[0].Subject != "Your Hasala email address" || codeRe.MatchString(msgs[0].Text) {
		t.Fatalf("expected the address-in-use notice, got %q", mailTexts(msgs))
	}
	if n := f.count(`SELECT count(*) FROM email_codes WHERE NOT sent`); n != 1 {
		t.Fatalf("unsent code rows: %d", n)
	}
	for _, c := range []string{"000000", "123456"} {
		if err := f.acct.SignupVerify(bgctx, s.SignupID, c); !errors.Is(err, ErrCodeRejected) {
			t.Fatal("a code nobody received verified")
		}
	}
	code, lk := f.addressedInvite(m.addr)
	p, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: m.addr, DisplayName: "Eve", InviteLinkKey: lk})
	if err != nil || !p.EmailProven {
		t.Fatal(err)
	}
	if _, _, err := f.registerPasskey(p.SignupID); !errors.Is(err, ErrEmailInUse) {
		t.Fatalf("a proven address in use: %v", err)
	}
}

func TestAReviewInviteMakesAReviewAccount(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	s, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: f.printedInvite(true), Email: addr, DisplayName: "App Review"})
	if err != nil {
		t.Fatal(err)
	}
	if err := f.acct.SignupVerify(bgctx, s.SignupID, f.lastCode(addr)); err != nil {
		t.Fatal(err)
	}
	r, _, err := f.registerPasskey(s.SignupID)
	if err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND review_account`, r.UserID); n != 1 {
		t.Fatal("the account is not a review account")
	}
}

func TestDisplayNameRule(t *testing.T) {
	for in, want := range map[string]string{
		"Maya":                  "Maya",
		"  Maya \t Rahman ":     "Maya Rahman",
		"J. Smith":              "J. Smith",
		"Maya R.":               "Maya R.",
		"O'Brien-Lee":           "O'Brien-Lee",
		"مايا":                  "مايا",
		strings.Repeat("a", 64): strings.Repeat("a", 64),
	} {
		got, err := DisplayName(in)
		if err != nil || got != want {
			t.Errorf("DisplayName(%q) = %q, %v; want %q", in, got, err, want)
		}
		if !keyproto.NameOK(got) {
			t.Errorf("%q passes DisplayName but not name_ok", got)
		}
	}
	for in, length := range map[string]bool{
		"":                      true,
		"   ":                   true,
		strings.Repeat("a", 65): true,
		"maya.example":          false,
		"Maya 2":                false,
		"maya@example.com":      false,
		"https://x":             false,
		"Maya‮R":                false,
		"Maya​R":                false,
		"...":                   false,
		"\xff":                  false,
	} {
		_, err := DisplayName(in)
		if !errors.Is(err, ErrBadName) {
			t.Errorf("DisplayName(%q) accepted", in)
			continue
		}
		if errors.Is(err, ErrBadNameLength) != length {
			t.Errorf("DisplayName(%q): %v, length rule %v", in, err, length)
		}
	}
}

// C1-P: one request creates the account with its keys, its first writer, its
// password and a session bound to that writer; the bootstrap is bound to the
// signup's reserved id, address, SHA256(S) and nonce.
func TestPasswordSignupIsOneAtomicRequest(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	i := m.info()
	if i.MintedBy != MintedPasswordSignup || i.WriterID != m.device.WriterID {
		t.Fatalf("session %+v", i)
	}
	var (
		hash, salt []byte
		version    int
	)
	if err := f.pool.QueryRow(bgctx, `SELECT password_hash, password_salt, password_version FROM users WHERE id = $1`,
		m.user.UserID).Scan(&hash, &salt, &version); err != nil {
		t.Fatal(err)
	}
	want, _ := f.keys.VerifierHash(m.s, salt, 1)
	if !sameBytes(hash, want) || version != 1 {
		t.Fatal("password_hash is not PBKDF2(HMAC(K_pepper, S), salt)")
	}
	if f.count(`SELECT count(*) FROM account_keys WHERE user_id = $1`, m.user.UserID) != 1 ||
		f.count(`SELECT count(*) FROM key_history WHERE user_id = $1 AND event = 'registered'`, m.user.UserID) != 1 {
		t.Fatal("keys or the first writer are missing")
	}

	// The checks, each against a fresh proven signup.
	for name, mutate := range map[string]func(*Bootstrap, *[]byte){
		"auth_hash is not SHA256(S)": func(b *Bootstrap, s *[]byte) { (*s)[0] ^= 1 },
		"another address":            func(b *Bootstrap, _ *[]byte) { h := keyproto.EmailHash("x@example.com"); b.EmailHash = h[:] },
		"a forged authority_sig":     func(b *Bootstrap, _ *[]byte) { b.AuthoritySig[0] ^= 1 },
		"another nonce":              func(b *Bootstrap, _ *[]byte) { b.Writer.Nonce = authtest.RandBytesTB(t, 32) },
		"auth_kind 1":                func(b *Bootstrap, _ *[]byte) { b.AuthKind = 1 },
	} {
		addr := newAddr()
		s := f.provenSignup(addr, "Maya")
		mm := &member{f: f, addr: addr, s: f.stretch(addr, "a password of some length"), acct: authtest.NewAccount(t, s.UserID),
			device: authtest.NewDevice(t)}
		b := f.passwordBootstrap(mm, s)
		v := append([]byte(nil), mm.s...)
		mutate(&b, &v)
		if _, err := f.acct.PasswordSignup(bgctx, s.SignupID, v, b); err == nil {
			t.Errorf("%s: accepted", name)
		}
		// The attempt spent the signup.
		if _, err := f.acct.PasswordSignup(bgctx, s.SignupID, mm.s, f.passwordBootstrap(mm, s)); !errors.Is(err, ErrCodeRejected) {
			t.Errorf("%s: the signup was not spent: %v", name, err)
		}
	}
	if n := countUsers(t, f.pool); n != 1 {
		t.Fatalf("%d accounts", n)
	}
	_ = uuid.Nil
}

// #45 with an invite another signup already redeemed answers code_rejected
// (spec 02 §10.7.3 step 1), before the PBKDF2 it would waste, and spends the
// signup.
func TestAPasswordSignupOnASpentInviteIsCodeRejected(t *testing.T) {
	f := newAcctFixture(t)
	code := f.printedInvite(false)
	type begun struct {
		s SignupBegun
		m *member
	}
	var both []begun
	for _, addr := range []string{newAddr(), newAddr()} {
		s, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: code, Email: addr, DisplayName: "Maya"})
		if err != nil {
			t.Fatal(err)
		}
		if err := f.acct.SignupVerify(bgctx, s.SignupID, f.lastCode(addr)); err != nil {
			t.Fatal(err)
		}
		m := &member{f: f, addr: addr, pw: "correct horse battery staple"}
		m.s = f.stretch(addr, m.pw)
		m.acct, m.device = authtest.NewAccount(t, s.UserID), authtest.NewDevice(t)
		both = append(both, begun{s, m})
	}
	first, second := both[0], both[1]
	if _, err := f.acct.PasswordSignup(bgctx, first.s.SignupID, first.m.s, f.passwordBootstrap(first.m, first.s)); err != nil {
		t.Fatal(err)
	}
	hashes := f.keys.HashCount()
	_, err := f.acct.PasswordSignup(bgctx, second.s.SignupID, second.m.s, f.passwordBootstrap(second.m, second.s))
	if !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a signup on a spent invite: %v, want code_rejected", err)
	}
	if f.keys.HashCount() != hashes {
		t.Fatal("a signup on a spent invite ran a PBKDF2")
	}
	if f.count(`SELECT count(*) FROM signup_ceremonies WHERE id = $1 AND claimed_at IS NOT NULL`, second.s.SignupID) != 1 {
		t.Fatal("the refused signup is still claimable")
	}
	if n := countUsers(t, f.pool); n != 1 {
		t.Fatalf("%d accounts", n)
	}
}
