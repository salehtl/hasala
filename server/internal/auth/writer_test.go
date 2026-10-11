package auth

import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/oplog"
)

// ---------------------------------------------------------------------------
// The device's key-history verification (spec 01 §10.13), as a reference: the
// tests below require every log the server serves to pass it.
// ---------------------------------------------------------------------------

type rosterRow struct {
	pub, dak     []byte
	live         bool
	finalCounter int64
	finalHead    []byte
}

func verifyKeyHistory(aakPub []byte, entries []KeyHistoryEntry) (map[string]rosterRow, error) {
	roster := map[string]rosterRow{}
	for _, e := range entries {
		if e.Alg != AlgEd25519 || len(e.PubKey) != 32 || len(e.Nonce) != 32 || len(e.Signature) != 64 {
			return nil, fmt.Errorf("entry %d: shape", e.ID)
		}
		switch e.Event {
		case EventRegistered:
			if e.AuthorizedBy != AuthorizedAuthority || len(e.DAKPubkey) != 65 || e.DAKPubkey[0] != 4 {
				return nil, fmt.Errorf("entry %d: registration shape", e.ID)
			}
			m, err := keyproto.RegistrationMessage(e.Nonce, e.WriterID, e.PubKey, e.DAKPubkey)
			if err != nil || !ed25519.Verify(aakPub, m, e.Signature) {
				return nil, fmt.Errorf("entry %d: the registration does not verify under the AAK", e.ID)
			}
			if _, ok := roster[e.WriterID]; ok {
				return nil, fmt.Errorf("entry %d: writer registered twice", e.ID)
			}
			roster[e.WriterID] = rosterRow{pub: e.PubKey, dak: e.DAKPubkey, live: true}
		case EventRevoked:
			s, ok := roster[e.AuthorizerWriterID]
			if e.AuthorizedBy != AuthorizedDevice || !ok || !s.live || e.FinalCounter == nil || len(e.FinalHead) != 32 {
				return nil, fmt.Errorf("entry %d: revocation shape", e.ID)
			}
			m, err := keyproto.RevocationMessage(e.Nonce, e.WriterID, uint64(*e.FinalCounter), e.FinalHead)
			if err != nil || !ed25519.Verify(s.pub, m, e.Signature) {
				return nil, fmt.Errorf("entry %d: the revocation does not verify under the signer", e.ID)
			}
			tgt, ok := roster[e.WriterID]
			if !ok || !tgt.live {
				return nil, fmt.Errorf("entry %d: revocation of a writer that is not live", e.ID)
			}
			tgt.live, tgt.finalCounter, tgt.finalHead = false, *e.FinalCounter, e.FinalHead
			roster[e.WriterID] = tgt
		default:
			return nil, fmt.Errorf("entry %d: event %q", e.ID, e.Event)
		}
	}
	return roster, nil
}

func (f *keyFixture) verifiedRoster() map[string]rosterRow {
	f.t.Helper()
	log, err := f.writers.KeyHistory(bgctx, f.user)
	if err != nil {
		f.t.Fatal(err)
	}
	r, err := verifyKeyHistory(f.acct.AAKPub(), log)
	if err != nil {
		f.t.Fatalf("the key history does not verify on a device: %v", err)
	}
	return r
}

// ---------------------------------------------------------------------------
// Bootstrap (spec 01 §10.3.2–§10.3.3)
// ---------------------------------------------------------------------------

func TestBootstrapUnderThePendingAuthorityPublishesKeysAndTheFirstWriter(t *testing.T) {
	f := newKeyFixture(t)
	k, err := f.keys.Read(bgctx, f.user)
	if err != nil {
		t.Fatal(err)
	}
	if k.CurrentEpoch != 1 || !bytes.Equal(k.AuthorityPubkey, f.acct.AAKPub()) || len(k.RecoveryWrap) != 127 {
		t.Fatalf("keys: %+v", k)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND authority_pubkey_pending IS NULL`, f.user); n != 1 {
		t.Fatal("the pending authority key was not cleared")
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1`, f.user); n != 1 {
		t.Fatal("the PRF wrap was not stored")
	}
	if i := f.info(f.token); i.WriterID != f.device.WriterID {
		t.Fatalf("the session is bound to %q, want the first writer", i.WriterID)
	}
	r := f.verifiedRoster()
	if w, ok := r[f.device.WriterID]; !ok || !w.live || !bytes.Equal(w.dak, f.device.DAKPub()) {
		t.Fatalf("roster: %+v", r)
	}
	// The key-history row carries the RegistrationMessage signature, never the
	// bootstrap signature (spec 01 §9 (a)).
	if n := f.count(`SELECT count(*) FROM account_usage WHERE user_id = $1`, f.user); n != 1 {
		t.Fatal("no account_usage row")
	}
}

func TestBootstrapRefusesWhatItMustRefuse(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	info := f.info(f.token)
	good := func() Bootstrap { return f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true) }
	cases := []struct {
		name string
		mut  func(b *Bootstrap)
		want error
	}{
		{"auth_hash is not the creating credential's attestation", func(b *Bootstrap) { b.AuthHash = make([]byte, 32); b.AuthHash[0] = 1 }, ErrKeysMalformed},
		{"auth_kind 2 outside the password signup", func(b *Bootstrap) { b.AuthKind = 2 }, ErrKeysMalformed},
		{"auth_kind 0 with the pending key", func(b *Bootstrap) { b.AuthKind = 0 }, ErrKeysMalformed},
		{"email_hash of another address", func(b *Bootstrap) { h := keyproto.EmailHash("evil@example.com"); b.EmailHash = h[:] }, ErrKeysMalformed},
		{"a 126-byte recovery wrap", func(b *Bootstrap) { b.RecoveryWrap = b.RecoveryWrap[:126] }, ErrKeysMalformed},
		{"a recovery wrap with kdf 0x02", func(b *Bootstrap) { b.RecoveryWrap = append([]byte{1, 2}, b.RecoveryWrap[2:]...) }, ErrKeysMalformed},
		{"a PRF wrap with kdf 0x01", func(b *Bootstrap) { b.PRFWrap = append([]byte{1, 1}, b.PRFWrap[2:]...) }, ErrKeysMalformed},
		{"a 44-byte phrase box", func(b *Bootstrap) { b.PhraseBox = b.PhraseBox[:44] }, ErrKeysMalformed},
		{"a small-order writer key", func(b *Bootstrap) { b.Writer.PubKey = append([]byte{1}, make([]byte, 31)...) }, ErrKeysMalformed},
		{"the recovery key equals the authority key", func(b *Bootstrap) { b.RecoveryPubkey = b.AuthorityPubkey }, ErrKeysMalformed},
		{"a DAK off the curve", func(b *Bootstrap) {
			b.Writer.DAKPubkey = append([]byte{4}, make([]byte, 64)...)
			b.Writer.DAKPubkey[64] = 7
		}, ErrKeysMalformed},
		{"a writer id outside the grammar", func(b *Bootstrap) { b.Writer.WriterID = "dev-a" }, ErrBadWriterID},
		{"another account's credential for the PRF wrap", func(b *Bootstrap) { b.PRFCredentialID = authtest.RandBytesTB(t, 20) }, ErrNotYours},
		{"an authority signature over another payload", func(b *Bootstrap) { b.AuthoritySig = ed25519.Sign(f.acct.AAK(), []byte("x")) }, ErrBadSignature},
		{"a registration signature by the DWK", func(b *Bootstrap) {
			m, _ := keyproto.RegistrationMessage(b.Writer.Nonce, b.Writer.WriterID, b.Writer.PubKey, b.Writer.DAKPubkey)
			b.Writer.Sig = ed25519.Sign(f.device.DWK, m)
		}, ErrBadSignature},
	}
	for _, c := range cases {
		b := good()
		c.mut(&b)
		if _, err := f.keys.Bootstrap(bgctx, info, b); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", c.name, err, c.want)
		}
	}
	// A nonce is spent by the attempt: a good request on a spent nonce fails.
	b := good()
	b.AuthoritySig = ed25519.Sign(f.acct.AAK(), []byte("x"))
	if _, err := f.keys.Bootstrap(bgctx, info, b); !errors.Is(err, ErrBadSignature) {
		t.Fatal(err)
	}
	b2 := good()
	b2.Writer.Nonce = b.Writer.Nonce
	if _, err := f.keys.Bootstrap(bgctx, info, b2); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a spent nonce bootstrapped: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM account_keys`); n != 0 {
		t.Fatalf("%d account_keys rows after refusals", n)
	}
	// Then the real one, and a second is 409 keys_exist.
	if _, err := f.keys.Bootstrap(bgctx, info, good()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.keys.Bootstrap(bgctx, info, good()); !errors.Is(err, ErrKeysExist) {
		t.Fatalf("a second bootstrap: %v, want keys_exist", err)
	}
}

// The interrupted-onboarding path: an authority key that is not the pending
// one needs step-up keys.bootstrap with T = (authority_pubkey), and auth_kind
// 0 with a zero auth_hash (spec 01 §10.3, R-04).
func TestBootstrapWithAnotherAuthorityKeyNeedsAStepUp(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	f.acct.AAKSeed = authtest.RandBytesTB(t, 32) // the onboarding restarted with new secrets
	b := f.bootstrap(f.device, keyproto.AuthKindNone, make([]byte, 32), false)
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); !errors.Is(err, ErrStepUpRequired) {
		t.Fatalf("no step-up: %v", err)
	}
	// A step-up for another key is a failed proof.
	b = f.bootstrap(f.device, keyproto.AuthKindNone, make([]byte, 32), false)
	b.StepUp = f.stepUpPasskey(f.token, keyproto.ActionKeysBootstrap, authtest.AuthorityPub(t))
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("step-up over another key: %v", err)
	}
	// auth_kind 1 on the step-up path is malformed.
	b = f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), false)
	b.StepUp = f.stepUpPasskey(f.token, keyproto.ActionKeysBootstrap, f.acct.AAKPub())
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); !errors.Is(err, ErrKeysMalformed) {
		t.Fatalf("auth_kind 1 on the step-up path: %v", err)
	}
	b = f.bootstrap(f.device, keyproto.AuthKindNone, make([]byte, 32), false)
	b.StepUp = f.stepUpPasskey(f.token, keyproto.ActionKeysBootstrap, f.acct.AAKPub())
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); err != nil {
		t.Fatalf("stepped-up bootstrap: %v", err)
	}
	// The nonce is spent with the action.
	if n := f.count(`SELECT count(*) FROM step_up_challenges WHERE nonce = $1 AND used_at IS NOT NULL`, b.StepUp.Nonce); n != 1 {
		t.Fatal("the step-up nonce was not spent")
	}
	f.verifiedRoster()
}

// ---------------------------------------------------------------------------
// Registration (spec 01 §10.5): the AAK, and only the AAK
// ---------------------------------------------------------------------------

func TestASecondWriterIsRegisteredByTheAuthorityKeyAndBindsItsSession(t *testing.T) {
	f := newKeyFixture(t)
	d2 := authtest.NewDevice(t)
	tok := f.enrol(d2)
	if i := f.info(tok); i.WriterID != d2.WriterID {
		t.Fatalf("the registering session is bound to %q", i.WriterID)
	}
	r := f.verifiedRoster()
	if len(r) != 2 || !r[d2.WriterID].live {
		t.Fatalf("roster %+v", r)
	}
}

func TestRegistrationRefusals(t *testing.T) {
	f := newKeyFixture(t)
	d := authtest.NewDevice(t)
	hash := f.info(f.newSession()).Hash
	reg := func(mut func(*Registration)) error {
		r := f.registration(d)
		mut(&r)
		return f.writers.Register(bgctx, f.user, hash, r)
	}
	if err := reg(func(r *Registration) { r.WriterID = "dev-a" }); !errors.Is(err, ErrBadWriterID) {
		t.Errorf("bad grammar: %v", err)
	}
	if err := reg(func(r *Registration) { r.PubKey = append([]byte{1}, make([]byte, 31)...) }); !errors.Is(err, ErrWriterMalformed) {
		t.Errorf("small-order key: %v", err)
	}
	if err := reg(func(r *Registration) { r.DAKPubkey = append([]byte{2}, r.DAKPubkey[1:33]...) }); !errors.Is(err, ErrWriterMalformed) {
		t.Errorf("compressed DAK: %v", err)
	}
	if err := reg(func(r *Registration) { r.DAKPubkey = f.device.DAKPub() }); !errors.Is(err, ErrWriterMalformed) {
		t.Errorf("an enrolled DAK: %v", err)
	}
	// Signed by the device's own DWK (ledgerd's TOFU), by an enrolled writer's
	// DWK (ledgerd's device authorizer), and by the recovery key: all refused.
	for name, signer := range map[string]ed25519.PrivateKey{"self": d.DWK, "enrolled writer": f.device.DWK,
		"recovery key": ed25519.NewKeyFromSeed(authtest.RandBytesTB(t, 32))} {
		if err := reg(func(r *Registration) {
			m, _ := keyproto.RegistrationMessage(r.Nonce, r.WriterID, r.PubKey, r.DAKPubkey)
			r.Sig = ed25519.Sign(signer, m)
		}); !errors.Is(err, ErrBadSignature) {
			t.Errorf("signed by %s: %v", name, err)
		}
	}
	// A spent nonce stays spent.
	r := f.registration(d)
	bad := r
	bad.Sig = ed25519.Sign(d.DWK, []byte("x"))
	if err := f.writers.Register(bgctx, f.user, hash, bad); !errors.Is(err, ErrBadSignature) {
		t.Fatal(err)
	}
	if err := f.writers.Register(bgctx, f.user, hash, r); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a good signature over a spent nonce: %v", err)
	}
	// A session that is already bound is never re-bound.
	if err := f.writers.Register(bgctx, f.user, f.info(f.token).Hash, f.registration(d)); !errors.Is(err, ErrSessionBound) {
		t.Fatalf("re-binding: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM writers WHERE writer_id = $1`, d.WriterID); n != 0 {
		t.Fatal("a refused registration left a writer")
	}
	// An account without keys has no authority to register under.
	g := newKeyFixtureUnbootstrapped(t)
	if err := g.writers.Register(bgctx, g.user, g.info(g.token).Hash, g.registration(d)); !errors.Is(err, ErrKeysRequired) {
		t.Fatalf("no keys: %v", err)
	}
}

func TestAtMostTwentyLiveWriters(t *testing.T) {
	f := newKeyFixture(t)
	for i := 1; i < MaxLiveWriters; i++ {
		f.enrol(authtest.NewDevice(t))
	}
	err := f.writers.Register(bgctx, f.user, f.info(f.newSession()).Hash, f.registration(authtest.NewDevice(t)))
	if !errors.Is(err, ErrTooManyDevices) {
		t.Fatalf("the 21st writer: %v", err)
	}
}

func TestAWriterChallengeIsSingleUseUnderConcurrency(t *testing.T) {
	f := newKeyFixture(t)
	const racers = 8
	warmPool(t, f.pool, racers)
	for round := 0; round < 4; round++ {
		n := f.nonce()
		errs := make([]error, racers)
		var wg sync.WaitGroup
		start := make(chan struct{})
		for i := 0; i < racers; i++ {
			d := authtest.NewDevice(t)
			hash := f.info(f.newSession()).Hash
			r := Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
				Nonce: n, Sig: f.acct.Registration(t, d, n)}
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-start
				errs[i] = f.writers.Register(bgctx, f.user, hash, r)
			}(i)
		}
		close(start)
		wg.Wait()
		won := 0
		for _, err := range errs {
			switch {
			case err == nil:
				won++
			case errors.Is(err, ErrBadSignature):
			default:
				t.Fatalf("a racer was refused by something other than the spent nonce: %v", err)
			}
		}
		if won != 1 {
			t.Fatalf("round %d: %d racers redeemed one nonce", round, won)
		}
	}
}

// warmPool forces n connections to be established before a race starts, so
// the racers are not staggered by connection setup.
func warmPool(t *testing.T, pool *pgxpool.Pool, n int) {
	t.Helper()
	conns := make([]*pgxpool.Conn, 0, n)
	for i := 0; i < n; i++ {
		c, err := pool.Acquire(bgctx)
		if err != nil {
			t.Fatalf("warm pool: %v", err)
		}
		conns = append(conns, c)
	}
	for _, c := range conns {
		c.Release()
	}
}

// ---------------------------------------------------------------------------
// Revocation (spec 01 §10.6, R-02)
// ---------------------------------------------------------------------------

func TestRevocationPinsTheFinalHeadAndEndsTheDevice(t *testing.T) {
	f := newKeyFixture(t)
	stolen := authtest.NewDevice(t)
	stolenTok := f.enrol(stolen)
	counter, head := f.appendRows(stolen, 3)
	registerPushToken(t, f.pool, f.user, stolen.WriterID, stolenTok, "stolen")

	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(stolen.WriterID))
	// A head the server has moved past is 409 head_moved, and the step-up is
	// NOT burned (the action failed after a good proof).
	err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(stolen.WriterID, f.device, counter-1, head, su))
	if !errors.Is(err, ErrHeadMoved) {
		t.Fatalf("stale head: %v", err)
	}
	su = f.reprove(su, keyproto.ActionWriterRevoke, []byte(stolen.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(stolen.WriterID, f.device, counter, head, su)); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	r := f.verifiedRoster()
	if w := r[stolen.WriterID]; w.live || w.finalCounter != counter || !bytes.Equal(w.finalHead, head) {
		t.Fatalf("roster after revocation: %+v", w)
	}
	if n := f.count(`SELECT count(*) FROM sessions WHERE token_hash = $1 AND revoked_at IS NOT NULL`, SessionHash(stolenTok)); n != 1 {
		t.Fatal("the revoked writer's session is still live")
	}
	if n := f.count(`SELECT count(*) FROM apns_tokens WHERE writer_id = $1`, stolen.WriterID); n != 0 {
		t.Fatal("the revoked writer's push token survived")
	}
	// It can append nothing more: the writer row is read FOR SHARE at append.
	if err := f.tryAppend(stolen, 1); !errors.Is(err, oplog.ErrWriterRevoked) {
		t.Fatalf("a revoked writer's validly signed batch: %v, want ErrWriterRevoked", err)
	}
	// Revoking again is refused: the log never revokes a writer twice.
	su2 := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(stolen.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(stolen.WriterID, f.device, counter, head, su2)); !errors.Is(err, ErrWriterRevoked) {
		t.Fatalf("second revocation: %v", err)
	}
}

func TestAWriterMayRevokeItselfWithAnEmptyChain(t *testing.T) {
	f := newKeyFixture(t)
	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(f.device.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(f.device.WriterID, f.device, 0, make([]byte, 32), su)); err != nil {
		t.Fatal(err)
	}
	if r := f.verifiedRoster(); r[f.device.WriterID].live {
		t.Fatal("still live")
	}
}

func TestRevocationRefusals(t *testing.T) {
	f := newKeyFixture(t)
	other := authtest.NewDevice(t)
	f.enrol(other)
	zero := make([]byte, 32)
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, zero, nil)); !errors.Is(err, ErrStepUpRequired) {
		t.Fatalf("no step-up: %v", err)
	}
	// A step-up begun for another writer id fails, and burns.
	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(f.device.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, zero, su)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("step-up for another target: %v", err)
	}
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(f.device.WriterID, f.device, 0, zero, su)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a burned nonce: %v", err)
	}
	// An assertion without UV fails.
	f.authn.NoUV = true
	su = f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	f.authn.NoUV = false
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, zero, su)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("UV cleared: %v", err)
	}
	// A signer that is not a live writer of the account.
	stranger := authtest.NewDevice(t)
	su = f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, stranger, 0, zero, su)); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("unenrolled signer: %v", err)
	}
	// The step-up survives a failed action: retry with the right signer.
	su = f.reprove(su, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, zero, su)); err != nil {
		t.Fatalf("retry after a refused signer: %v", err)
	}
	f.verifiedRoster()
}

// ---------------------------------------------------------------------------
// key_history is append-only (spec 02 D-6, spec 01 §9)
// ---------------------------------------------------------------------------

func TestKeyHistoryGuardBindsANonOwnerRuntimeRole(t *testing.T) {
	f := newKeyFixture(t)
	for _, sql := range []string{`UPDATE key_history SET pubkey = pubkey`, `DELETE FROM key_history`, `TRUNCATE key_history`} {
		if _, err := f.pool.Exec(bgctx, sql); err == nil || !strings.Contains(err.Error(), "permission denied") {
			t.Fatalf("runtime %s: %v, want permission denied", sql, err)
		}
	}
	if _, err := f.pool.Exec(bgctx, `ALTER TABLE key_history DISABLE TRIGGER key_history_no_rewrite`); err == nil ||
		!strings.Contains(err.Error(), "must be owner") {
		t.Fatalf("runtime DISABLE TRIGGER: %v", err)
	}
	for _, sql := range []string{`UPDATE key_history SET at = at`, `DELETE FROM key_history`} {
		if _, err := f.owner.Exec(bgctx, sql); err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Fatalf("owner %s: %v, want the append-only guard", sql, err)
		}
	}
	// The CHECKs refuse rows a device could not verify.
	for name, sql := range map[string]string{
		"a registration without a DAK": `INSERT INTO key_history (user_id, writer_id, alg, pubkey, event, authorized_by, nonce, signature, at)
			SELECT user_id, writer_id, alg, pubkey, 'registered', 'authority', nonce, signature, now() FROM key_history LIMIT 1`,
		"a registration by a device": `INSERT INTO key_history (user_id, writer_id, alg, pubkey, dak_pubkey, event, authorized_by, authorizer_writer_id, nonce, signature, at)
			SELECT user_id, writer_id, alg, pubkey, dak_pubkey, 'registered', 'device', writer_id, nonce, signature, now() FROM key_history LIMIT 1`,
		"a revocation without a final head": `INSERT INTO key_history (user_id, writer_id, alg, pubkey, event, authorized_by, authorizer_writer_id, nonce, signature, at)
			SELECT user_id, writer_id, alg, pubkey, 'revoked', 'device', writer_id, nonce, signature, now() FROM key_history LIMIT 1`,
	} {
		if _, err := f.pool.Exec(bgctx, sql); err == nil {
			t.Errorf("%s was stored", name)
		}
	}
}

func TestKeyHistoryIsRemovedWithItsUser(t *testing.T) {
	f := newKeyFixture(t)
	if _, err := f.pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, f.user); err != nil {
		t.Fatalf("deleting a user must cascade through key_history: %v", err)
	}
	for _, table := range []string{"key_history", "writers", "writer_challenges", "account_keys", "account_key_wraps", "step_up_challenges"} {
		if n := f.count(`SELECT count(*) FROM ` + table); n != 0 {
			t.Fatalf("%s still holds %d rows after the user was deleted", table, n)
		}
	}
}

// ---------------------------------------------------------------------------
// Step-up (spec 01 §10.2, spec 02 §8)
// ---------------------------------------------------------------------------

func TestStepUpBeginRefusals(t *testing.T) {
	f := newKeyFixture(t)
	i := f.info(f.token)
	ph := make([]byte, 32)
	for name, c := range map[string]struct {
		a    keyproto.Action
		k    keyproto.ProofKind
		want error
	}{
		"keys.bootstrap by device":  {keyproto.ActionKeysBootstrap, keyproto.ProofDevice, ErrStepUpBadRequest},
		"password.reset by passkey": {keyproto.ActionPasswordReset, keyproto.ProofPasskey, ErrStepUpBadRequest},
		"an action outside the set": {"writer.register", keyproto.ProofPasskey, ErrStepUpBadRequest},
	} {
		if _, err := f.stepUp.Begin(bgctx, f.user, i.Hash, i.WriterID, c.a, ph, c.k); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
	unbound := f.info(f.newSession())
	if _, err := f.stepUp.Begin(bgctx, f.user, unbound.Hash, "", keyproto.ActionPasskeyDelete, ph, keyproto.ProofDevice); !errors.Is(err, ErrWriterUnbound) {
		t.Errorf("a device proof on an unbound session: %v", err)
	}
	b := f.begin(f.token, keyproto.ActionPasskeyDelete, keyproto.ProofPasskey, f.credID)
	if len(b.AllowCredentials) != 1 || !bytes.Equal(b.AllowCredentials[0], f.credID) {
		t.Fatalf("allow list %x", b.AllowCredentials)
	}
}

// A device proof: the DAK first, then the password. This account has no
// password, so a valid DAK signature fails at the password step (and burns),
// and an invalid one fails before it.
func TestStepUpDeviceProofChecksTheDAKFirst(t *testing.T) {
	f := newKeyFixture(t)
	target := []byte(f.device.WriterID)
	run := func(sign func(c [32]byte) []byte) error {
		b := f.begin(f.token, keyproto.ActionWriterRevoke, keyproto.ProofDevice, target)
		su := &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "device", WriterID: f.device.WriterID,
			Sig: sign(b.Challenge), Verifier: make([]byte, 32)}}
		return f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(f.device.WriterID, f.device, 0, make([]byte, 32), su))
	}
	good := func(c [32]byte) []byte {
		m, _ := keyproto.DeviceStepUpMessage(c, f.device.WriterID)
		return f.device.SignDAK(t, m)
	}
	if err := run(good); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("an account without a password: %v", err)
	}
	other := authtest.NewDevice(t)
	for name, sign := range map[string]func([32]byte) []byte{
		"another writer's DAK": func(c [32]byte) []byte {
			m, _ := keyproto.DeviceStepUpMessage(c, f.device.WriterID)
			return other.SignDAK(t, m)
		},
		"over another C": func(c [32]byte) []byte {
			c[0] ^= 1
			m, _ := keyproto.DeviceStepUpMessage(c, f.device.WriterID)
			return f.device.SignDAK(t, m)
		},
		"r = 0": func(c [32]byte) []byte { s := good(c); copy(s[:32], make([]byte, 32)); return s },
	} {
		if err := run(sign); !errors.Is(err, ErrStepUpFailed) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if r := f.verifiedRoster(); !r[f.device.WriterID].live {
		t.Fatal("a failed step-up revoked the writer")
	}
}

func TestAStepUpIsBoundToItsSessionAndExpires(t *testing.T) {
	f := newKeyFixture(t)
	other := authtest.NewDevice(t)
	f.enrol(other)
	zero := make([]byte, 32)
	// Another session's nonce.
	su := f.stepUpPasskey(f.newSession(), keyproto.ActionWriterRevoke, []byte(other.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, zero, su)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("another session's step-up: %v", err)
	}
	// An expired one.
	su = f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	f.clock.advance(StepUpTTL + 1)
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, zero, su)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("an expired step-up: %v", err)
	}
	// A proof kind that differs from the one begun.
	su = f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	su.Proof.Kind = "device"
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, zero, su)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a proof of another kind: %v", err)
	}
}
