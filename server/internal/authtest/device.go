package authtest

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// Device is a software iPhone's writer identity (spec 01 §4.8, §4.9): a fresh
// writer id, a DWK (Ed25519) and a software DAK standing in for the Secure
// Enclave key, with identical byte formats (CoreSoftAuth's role in Go).
type Device struct {
	WriterID string
	DWK      ed25519.PrivateKey
	DAK      *ecdsa.PrivateKey
}

// NewDevice mints a device identity.
func NewDevice(t testing.TB) *Device {
	t.Helper()
	_, dwk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	dak, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &Device{WriterID: "ios-" + uuid.New().String(), DWK: dwk, DAK: dak}
}

// DWKPub is the DWK's 32-byte public key.
func (d *Device) DWKPub() []byte { return d.DWK.Public().(ed25519.PublicKey) }

// DAKPub is the DAK's 65-byte X9.63 public key.
func (d *Device) DAKPub() []byte {
	out := []byte{4}
	out = append(out, d.DAK.X.FillBytes(make([]byte, 32))...)
	return append(out, d.DAK.Y.FillBytes(make([]byte, 32))...)
}

// SignDAK is P256.Sign(DAK, m): raw r ‖ s over SHA256(m).
func (d *Device) SignDAK(t testing.TB, m []byte) []byte {
	t.Helper()
	h := sha256.Sum256(m)
	r, s, err := ecdsa.Sign(rand.Reader, d.DAK, h[:])
	if err != nil {
		t.Fatal(err)
	}
	return append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
}

// Account is the device-side key material of one account (spec 01 §4): the
// phrase entropy, the AMK and the AAK seed, never held by the server.
type Account struct {
	User    uuid.UUID
	E       []byte
	AMK     []byte
	AAKSeed []byte
}

// NewAccount mints fresh key material for user.
func NewAccount(t testing.TB, user uuid.UUID) *Account {
	t.Helper()
	return &Account{User: user, E: RandBytesTB(t, 16), AMK: RandBytesTB(t, 32), AAKSeed: RandBytesTB(t, 32)}
}

// RandBytesTB is RandBytes for any testing.TB.
func RandBytesTB(t testing.TB, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// AAK is the authority key pair.
func (a *Account) AAK() ed25519.PrivateKey { return ed25519.NewKeyFromSeed(a.AAKSeed) }

// AAKPub is authority_pubkey.
func (a *Account) AAKPub() []byte { return cryptoref.AAKPub(a.AAKSeed) }

// Registration signs a RegistrationMessage for d over nonce with the AAK.
func (a *Account) Registration(t testing.TB, d *Device, nonce []byte) []byte {
	t.Helper()
	m, err := keyproto.RegistrationMessage(nonce, d.WriterID, d.DWKPub(), d.DAKPub())
	if err != nil {
		t.Fatal(err)
	}
	return ed25519.Sign(a.AAK(), m)
}

// Bootstrap is everything a bootstrap request carries, built the way the
// device builds it (spec 01 §10.3): the payload's fields and the AAK's two
// signatures over nonce.
type Bootstrap struct {
	Payload         keyproto.BootstrapPayload
	Nonce           []byte
	AuthoritySig    []byte
	RegistrationSig []byte
}

// BuildBootstrap builds and signs a bootstrap for device d. authKind and
// authHash are the authorization path's (§10.3.2 step 4); prfCredential and
// prfSecret, when non-nil, add a PRF wrap for that credential.
func (a *Account) BuildBootstrap(t testing.TB, d *Device, emailNorm string, nonce []byte, authKind byte, authHash, prfCredential, prfSecret []byte) Bootstrap {
	t.Helper()
	body := cryptoref.Body(a.AMK, a.AAKSeed)
	rk := cryptoref.RKPub(a.E)
	eh := keyproto.EmailHash(emailNorm)
	p := keyproto.BootstrapPayload{
		UserID: a.User, AMKCommitment: cryptoref.AMKCommit(a.AMK, a.User), AuthorityPubkey: a.AAKPub(),
		RecoveryPubkey: rk,
		RecoveryWrap:   cryptoref.SealRecoveryWrap(a.E, RandBytesTB(t, 32), RandBytesTB(t, 12), body, a.User),
		PhraseBox:      cryptoref.SealPhraseBox(a.AMK, a.User, rk, RandBytesTB(t, 12), a.E),
		EmailHash:      eh[:], AuthKind: authKind, AuthHash: authHash,
		WriterPubkey: d.DWKPub(), WriterDAK: d.DAKPub(), WriterID: d.WriterID,
	}
	if prfCredential != nil {
		p.CredentialID = prfCredential
		p.PRFWrap = cryptoref.SealPRFWrap(prfSecret, RandBytesTB(t, 32), RandBytesTB(t, 12), body, a.User, prfCredential)
	}
	payload, err := p.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	bm, err := keyproto.BootstrapMessage(nonce, payload)
	if err != nil {
		t.Fatal(err)
	}
	return Bootstrap{Payload: p, Nonce: nonce, AuthoritySig: ed25519.Sign(a.AAK(), bm), RegistrationSig: a.Registration(t, d, nonce)}
}

// AuthorityPub is a fresh, usable authority public key for a registration
// ceremony whose bootstrap the test does not run.
func AuthorityPub(t testing.TB) []byte {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub
}
