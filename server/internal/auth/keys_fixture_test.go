package auth

import (
	"crypto/ed25519"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/oplog"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// keyFixture is one account taken through spec 01 §10.3's C1 the way a device
// does it: an authority key generated first, a passkey registration whose
// challenge binds it (C_reg), a session, an address, and — unless the test
// asks otherwise — the bootstrap that publishes the keys and registers the
// first writer under the pending authority.
type keyFixture struct {
	t        *testing.T
	pool     *pgxpool.Pool
	owner    *pgxpool.Pool
	clock    *clock
	passkeys *Passkeys
	stepUp   *StepUp
	writers  *Writers
	keys     *AccountKeys
	sessions *Sessions

	user   uuid.UUID
	authn  *authtest.Authenticator
	credID []byte
	acct   *authtest.Account
	email  string
	token  string
	device *authtest.Device
	// counter is the authenticator's next signature counter: it must rise, or
	// the assertion reads as a cloned authenticator.
	counter atomic.Uint32
}

var fixtureN atomic.Int64

func newKeyFixtureUnbootstrapped(t *testing.T) *keyFixture {
	t.Helper()
	pool, owner := pgtest.NewWithOwner(t)
	c := newClock()
	f := &keyFixture{t: t, pool: pool, owner: owner, clock: c}
	f.passkeys = newPasskeys(t, pool)
	f.passkeys.Now = c.now
	f.stepUp = &StepUp{Pool: pool, Passkeys: f.passkeys, Now: c.now}
	f.writers = &Writers{Pool: pool, StepUp: f.stepUp, Now: c.now}
	f.keys = &AccountKeys{Pool: pool, StepUp: f.stepUp, Now: c.now}
	f.sessions = newSessions(pool, time.Hour, c)

	aakSeed := authtest.RandBytesTB(t, 32)
	id, opts, nonce, err := f.passkeys.BeginRegistration(bgctx, mustMint(t, pool, "keys"), cryptoref.AAKPub(aakSeed))
	if err != nil {
		t.Fatal(err)
	}
	creg, _ := keyproto.RegisterChallenge(nonce, cryptoref.AAKPub(aakSeed))
	if string(opts.Response.Challenge) != string(creg[:]) {
		t.Fatal("the registration challenge is not C_reg")
	}
	f.authn = authtest.New(t)
	f.user, f.credID, err = f.passkeys.FinishRegistration(bgctx, id, f.authn.Create(t, opts))
	if err != nil {
		t.Fatal(err)
	}
	f.counter.Store(2)
	f.acct = &authtest.Account{User: f.user, E: authtest.RandBytesTB(t, 16), AMK: authtest.RandBytesTB(t, 32), AAKSeed: aakSeed}
	f.email = fmt.Sprintf("maya+%d@example.com", fixtureN.Add(1))
	if _, err := pool.Exec(bgctx, `UPDATE users SET email_norm = $2 WHERE id = $1`, f.user, f.email); err != nil {
		t.Fatal(err)
	}
	f.token = f.newSession()
	f.device = authtest.NewDevice(t)
	return f
}

func newKeyFixture(t *testing.T) *keyFixture {
	t.Helper()
	f := newKeyFixtureUnbootstrapped(t)
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}
	return f
}

func (f *keyFixture) newSession() string {
	f.t.Helper()
	tok, err := f.sessions.IssueForCredential(bgctx, f.user, f.credID)
	if err != nil {
		f.t.Fatal(err)
	}
	return tok
}

func (f *keyFixture) info(token string) SessionInfo {
	f.t.Helper()
	i, err := f.sessions.Info(bgctx, token)
	if err != nil {
		f.t.Fatal(err)
	}
	return i
}

func (f *keyFixture) attestation() []byte { return AttestationHash(f.authn.LastAttestationObject) }

func (f *keyFixture) nonce() []byte {
	f.t.Helper()
	n, _, err := f.writers.Challenge(bgctx, f.user)
	if err != nil {
		f.t.Fatal(err)
	}
	return n
}

// bootstrap builds the request a device sends (with a PRF wrap for the
// creating credential when prf is set).
func (f *keyFixture) bootstrap(d *authtest.Device, kind byte, authHash []byte, prf bool) Bootstrap {
	f.t.Helper()
	var cred, secret []byte
	if prf {
		cred, secret = f.credID, authtest.RandBytesTB(f.t, 32)
	}
	b := f.acct.BuildBootstrap(f.t, d, f.email, f.nonce(), kind, authHash, cred, secret)
	return toBootstrap(b)
}

func toBootstrap(b authtest.Bootstrap) Bootstrap {
	p := b.Payload
	out := Bootstrap{
		FormatVersion: 1, AMKCommitment: p.AMKCommitment, AuthorityPubkey: p.AuthorityPubkey,
		RecoveryPubkey: p.RecoveryPubkey, RecoveryWrap: p.RecoveryWrap, PhraseBox: p.PhraseBox,
		EmailHash: p.EmailHash, AuthKind: int(p.AuthKind), AuthHash: p.AuthHash,
		Writer: Registration{WriterID: p.WriterID, Alg: AlgEd25519, PubKey: p.WriterPubkey, DAKPubkey: p.WriterDAK,
			Nonce: b.Nonce, Sig: b.RegistrationSig},
		AuthoritySig: b.AuthoritySig,
	}
	if p.CredentialID != nil {
		out.PRFCredentialID, out.PRFWrap, out.PRFWrapVersion = p.CredentialID, p.PRFWrap, 1
	}
	return out
}

// registration builds a writer registration for d signed by the AAK.
func (f *keyFixture) registration(d *authtest.Device) Registration {
	n := f.nonce()
	return Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
		Nonce: n, Sig: f.acct.Registration(f.t, d, n)}
}

// enrol registers d on a new session and returns that session's token.
func (f *keyFixture) enrol(d *authtest.Device) string {
	f.t.Helper()
	tok := f.newSession()
	if err := f.writers.Register(bgctx, f.user, f.info(tok).Hash, f.registration(d)); err != nil {
		f.t.Fatalf("register %s: %v", d.WriterID, err)
	}
	return tok
}

// stepUpPasskey begins a step-up for action on token's session and proves it
// with the fixture's passkey.
func (f *keyFixture) stepUpPasskey(token string, action keyproto.Action, fields ...[]byte) *StepUpObject {
	f.t.Helper()
	b := f.begin(token, action, keyproto.ProofPasskey, fields...)
	return &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "passkey",
		Assertion: f.authn.AssertChallenge(f.t, authtest.RPID, b.Challenge[:], f.counter.Add(1))}}
}

// reprove makes a fresh assertion over an existing step-up's challenge: the
// nonce stays usable after an action that failed past a good proof, but an
// assertion is single use (its signature counter must rise).
func (f *keyFixture) reprove(su *StepUpObject, action keyproto.Action, fields ...[]byte) *StepUpObject {
	f.t.Helper()
	ph, _ := keyproto.ParamsHash(action, fields...)
	c, _ := keyproto.StepUpChallenge(su.Nonce, action, ph)
	return &StepUpObject{Nonce: su.Nonce, Proof: StepUpProof{Kind: "passkey",
		Assertion: f.authn.AssertChallenge(f.t, authtest.RPID, c[:], f.counter.Add(1))}}
}

func (f *keyFixture) begin(token string, action keyproto.Action, kind keyproto.ProofKind, fields ...[]byte) Begun {
	f.t.Helper()
	ph, err := keyproto.ParamsHash(action, fields...)
	if err != nil {
		f.t.Fatal(err)
	}
	i := f.info(token)
	b, err := f.stepUp.Begin(bgctx, f.user, i.Hash, i.WriterID, action, ph[:], kind)
	if err != nil {
		f.t.Fatalf("step-up begin %s: %v", action, err)
	}
	return b
}

// appendRows appends n sealed rows to d's chain, head-signed by d's DWK, and
// returns the new head.
func (f *keyFixture) appendRows(d *authtest.Device, n int) (int64, []byte) {
	f.t.Helper()
	if err := f.tryAppend(d, n); err != nil {
		f.t.Fatalf("append: %v", err)
	}
	c, h, err := (&oplog.Appender{Pool: f.pool}).Head(bgctx, f.user, d.WriterID, blob.StreamHot)
	if err != nil {
		f.t.Fatal(err)
	}
	return c, h[:]
}

// tryAppend appends n sealed, chained, head-signed rows to d's chain.
func (f *keyFixture) tryAppend(d *authtest.Device, n int) error {
	f.t.Helper()
	a := &oplog.Appender{Pool: f.pool}
	counter, prev, err := a.Head(bgctx, f.user, d.WriterID, blob.StreamHot)
	if err != nil {
		f.t.Fatal(err)
	}
	var rows []oplog.Row
	for i := 0; i < n; i++ {
		c := counter + int64(i) + 1
		s, err := blobtest.Seal3(blob.Envelope{UserID: f.user, Stream: blob.StreamHot, WriterID: d.WriterID, WriterCounter: c},
			1, blobtest.TestEpochKey, prev, []byte(`{"v":4,"kind":"ops","ops":[]}`))
		if err != nil {
			f.t.Fatal(err)
		}
		h := blob.Hash(prev, s)
		rows = append(rows, oplog.Row{WriterCounter: c, Blob: s.Bytes, SizeBucket: s.SizeBucket,
			BlobHash: append([]byte(nil), h[:]...), PrevHash: append([]byte(nil), prev[:]...)})
		prev = h
	}
	last := rows[len(rows)-1]
	m, _ := keyproto.HeadMessage(f.user, uint64(last.WriterCounter), last.BlobHash, d.WriterID)
	_, err = a.AppendClient(bgctx, f.user, d.WriterID, blob.StreamHot, rows, ed25519.Sign(d.DWK, m))
	return err
}

// revocation builds a revocation of target signed by signer's DWK over a
// fresh writer nonce, pinning (counter, head).
func (f *keyFixture) revocation(target string, signer *authtest.Device, counter int64, head []byte, su *StepUpObject) Revocation {
	f.t.Helper()
	n := f.nonce()
	m, err := keyproto.RevocationMessage(n, target, uint64(counter), head)
	if err != nil {
		f.t.Fatal(err)
	}
	return Revocation{WriterID: target, SignerWriterID: signer.WriterID, Nonce: n, FinalCounter: counter,
		FinalHead: head, Sig: ed25519.Sign(signer.DWK, m), StepUp: su}
}

func (f *keyFixture) count(sql string, args ...any) int {
	f.t.Helper()
	return countRows(f.t, f.pool, sql, args...)
}

func countRows(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bgctx, sql, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
