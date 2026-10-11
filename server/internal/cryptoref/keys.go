// Package cryptoref is the Go reference for the device-side cryptography of
// spec 01: the key derivations (§4), the wraps and the phrase box (§5), the
// recovery phrase (§4.3), the password stretch (§4.10) and the frame reader's
// order of checks (§6.6). TEST AND VECTORS ONLY.
//
// The server holds no data key and never seals, opens, unwraps or stretches
// anything (spec 02 §4.4 fences 3 and 5). This package exists so that
// cmd/gen-crypto-vectors can write conformance/crypto-v3/ and the Go tests can
// open what the Swift client writes (spec 01 §15.2). cmd/hasalad's build graph
// must never reach it; fence_test.go asserts that.
package cryptoref

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

// Sizes (spec 01 §4.2, §5.1).
const (
	EntropySize = 16
	KeySize     = 32
	NonceSize   = 12
	TagSize     = 16
	BodySize    = 65
	BodyV1      = 0x01
)

// Unwrap outcomes (spec 01 §5.4, §5.5). They are the names the Swift client
// uses, and the W-cases of conformance/crypto-v3/ name them.
var (
	ErrUnwrapFailed          = errors.New("unwrapFailed")
	ErrNotThisAccountsPhrase = errors.New("notThisAccountsPhrase")
	ErrAccountKeysMismatch   = errors.New("integrityAlarm(accountKeysMismatch)")
	ErrPhraseBoxMismatch     = errors.New("integrityAlarm(phraseBoxMismatch)")
)

var zeroSalt = make([]byte, 32)

// HKDF is RFC 5869 HKDF-SHA-256 with a 32-byte output (spec 01 §1).
func HKDF(ikm, salt, info []byte) []byte {
	k, err := hkdf.Key(sha256.New, ikm, salt, string(info), KeySize)
	if err != nil {
		panic(err) // unreachable for a 32-byte output
	}
	return k
}

// HMAC is HMAC-SHA-256 over the concatenation of parts.
func HMAC(key []byte, parts ...[]byte) []byte {
	h := hmac.New(sha256.New, key)
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

func cat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func dom(d string) []byte { return append([]byte(d), 0x00) }

// PRFSalt is SHA256("hasala/v1/prf-salt/unlock") (A01), no 0x00.
func PRFSalt() [32]byte { return sha256.Sum256([]byte(keyproto.DomainPRFSaltUnlock)) }

// RKSeed is HKDF(E, 0^32, "hasala/v1/recovery-key").
func RKSeed(e []byte) []byte { return HKDF(e, zeroSalt, []byte(keyproto.DomainRecoveryKey)) }

// RK is the recovery key pair derived from E.
func RK(e []byte) ed25519.PrivateKey { return ed25519.NewKeyFromSeed(RKSeed(e)) }

// RKPub is RK.pub, published as account_keys.recovery_pubkey.
func RKPub(e []byte) []byte { return RK(e).Public().(ed25519.PublicKey) }

// RWK is HKDF(E, salt, "hasala/v1/wrap/recovery").
func RWK(e, salt []byte) []byte { return HKDF(e, salt, []byte(keyproto.DomainWrapRecovery)) }

// PWK is HKDF(P, salt, "hasala/v1/wrap/prf").
func PWK(p, salt []byte) []byte { return HKDF(p, salt, []byte(keyproto.DomainWrapPRF)) }

// AMKCommit is HMAC(AMK, "hasala/v1/amk-commitment" ‖ 00 ‖ uuid_raw(user_id)).
func AMKCommit(amk []byte, user uuid.UUID) []byte {
	return HMAC(amk, dom(keyproto.DomainAMKCommitment), user[:])
}

// EpochKey1 is K_1 = HKDF(AMK, uuid_raw, "hasala/v1/epoch-key" ‖ 00 ‖ u32be(1)).
func EpochKey1(amk []byte, user uuid.UUID) []byte {
	return HKDF(amk, user[:], binary.BigEndian.AppendUint32(dom(keyproto.DomainEpochKey), 1))
}

// KPV is HKDF(AMK, uuid_raw, "hasala/v1/phrase-box-key").
func KPV(amk []byte, user uuid.UUID) []byte {
	return HKDF(amk, user[:], []byte(keyproto.DomainPhraseBoxKey))
}

// Body is 0x01 ‖ AMK ‖ AAK_seed (65 bytes).
func Body(amk, aakSeed []byte) []byte { return cat([]byte{BodyV1}, amk, aakSeed) }

// AAKPub is Ed25519.pub(AAK_seed).
func AAKPub(seed []byte) []byte {
	return ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
}

func gcm(key []byte) cipher.AEAD {
	if len(key) != KeySize {
		panic(fmt.Sprintf("cryptoref: key is %d bytes", len(key)))
	}
	b, err := aes.NewCipher(key)
	if err != nil {
		panic(err)
	}
	g, err := cipher.NewGCM(b)
	if err != nil {
		panic(err)
	}
	return g
}

// Seal is AEAD.Seal: AES-256-GCM returning ct ‖ tag. It refuses any key that
// is not 32 bytes and any nonce that is not 12 (spec 01 §1).
func Seal(key, nonce, pt, ad []byte) []byte {
	if len(nonce) != NonceSize {
		panic("cryptoref: nonce is not 12 bytes")
	}
	return gcm(key).Seal(nil, nonce, pt, ad)
}

// Open is AEAD.Open with one opaque error.
func Open(key, nonce, ctTag, ad []byte) ([]byte, error) {
	if len(key) != KeySize || len(nonce) != NonceSize {
		return nil, ErrUnwrapFailed
	}
	pt, err := gcm(key).Open(nil, nonce, ctTag, ad)
	if err != nil {
		return nil, ErrUnwrapFailed
	}
	return pt, nil
}

// ---------------------------------------------------------------------------
// Wraps (spec 01 §5)
// ---------------------------------------------------------------------------

func wrapAD(header []byte, user uuid.UUID, credentialID []byte) []byte {
	return cat(dom(keyproto.DomainWrap), header, user[:], credentialID)
}

func sealWrap(kdf byte, key, salt, nonce, body []byte, user uuid.UUID, credentialID []byte) []byte {
	if len(salt) != 32 || len(nonce) != NonceSize || len(body) != BodySize {
		panic("cryptoref: wrap input has the wrong length")
	}
	header := cat([]byte{keyproto.WrapVersion1, kdf}, salt, nonce)
	return cat(header, Seal(key, nonce, body, wrapAD(header, user, credentialID)))
}

// SealRecoveryWrap is §5.2: RWK = HKDF(E, salt, D05); AD = D07 ‖ 00 ‖ header46
// ‖ uuid_raw(user_id).
func SealRecoveryWrap(e, salt, nonce, body []byte, user uuid.UUID) []byte {
	return sealWrap(keyproto.KDFRecovery, RWK(e, salt), salt, nonce, body, user, nil)
}

// SealPRFWrap is §5.3: PWK = HKDF(P, salt, D06); AD also binds credential_id.
func SealPRFWrap(p, salt, nonce, body []byte, user uuid.UUID, credentialID []byte) []byte {
	return sealWrap(keyproto.KDFPRF, PWK(p, salt), salt, nonce, body, user, credentialID)
}

// Unwrapped is an opened body whose commitments were checked.
type Unwrapped struct {
	AMK, AAKSeed []byte
}

// AccountKeys is what GET /keys publishes and the unwrap checks against.
type AccountKeys struct {
	User            uuid.UUID
	AMKCommitment   []byte
	AuthorityPubkey []byte
	RecoveryPubkey  []byte
}

func openWrap(kdf byte, keyFor func(salt []byte) []byte, wrap []byte, acct AccountKeys, credentialID []byte) (Unwrapped, error) {
	if len(wrap) != keyproto.WrapSize || wrap[0] != keyproto.WrapVersion1 || wrap[1] != kdf {
		return Unwrapped{}, ErrUnwrapFailed
	}
	header := wrap[:keyproto.WrapHeaderSize]
	salt, nonce := wrap[2:34], wrap[34:46]
	body, err := Open(keyFor(salt), nonce, wrap[keyproto.WrapHeaderSize:], wrapAD(header, acct.User, credentialID))
	if err != nil {
		return Unwrapped{}, ErrUnwrapFailed
	}
	if len(body) != BodySize || body[0] != BodyV1 {
		return Unwrapped{}, ErrUnwrapFailed
	}
	amk, aak := body[1:33], body[33:65]
	if subtle.ConstantTimeCompare(AMKCommit(amk, acct.User), acct.AMKCommitment) != 1 ||
		subtle.ConstantTimeCompare(AAKPub(aak), acct.AuthorityPubkey) != 1 {
		return Unwrapped{}, ErrAccountKeysMismatch
	}
	return Unwrapped{AMK: append([]byte(nil), amk...), AAKSeed: append([]byte(nil), aak...)}, nil
}

// OpenRecoveryWrap is §5.4 on the phrase path: the RK.pub check first
// (notThisAccountsPhrase), then the shape, the AEAD, the body version and the
// commitments.
func OpenRecoveryWrap(e, wrap []byte, acct AccountKeys) (Unwrapped, error) {
	if subtle.ConstantTimeCompare(RKPub(e), acct.RecoveryPubkey) != 1 {
		return Unwrapped{}, ErrNotThisAccountsPhrase
	}
	return openWrap(keyproto.KDFRecovery, func(salt []byte) []byte { return RWK(e, salt) }, wrap, acct, nil)
}

// OpenPRFWrap is §5.4 on the PRF path.
func OpenPRFWrap(p, wrap []byte, acct AccountKeys, credentialID []byte) (Unwrapped, error) {
	return openWrap(keyproto.KDFPRF, func(salt []byte) []byte { return PWK(p, salt) }, wrap, acct, credentialID)
}

// ---------------------------------------------------------------------------
// Phrase box (spec 01 §5.5)
// ---------------------------------------------------------------------------

func boxAD(user uuid.UUID, recoveryPub []byte, version byte) []byte {
	return cat(dom(keyproto.DomainPhraseBox), user[:], recoveryPub, []byte{version})
}

// SealPhraseBox is box = 0x01 ‖ nonce ‖ AEAD(K_pv, nonce, E, AD), AD = D36 ‖ 00
// ‖ uuid_raw ‖ recovery_pubkey ‖ box[0:1].
func SealPhraseBox(amk []byte, user uuid.UUID, recoveryPub, nonce, e []byte) []byte {
	if len(e) != EntropySize || len(recoveryPub) != 32 {
		panic("cryptoref: phrase box input has the wrong length")
	}
	return cat([]byte{keyproto.PhraseBoxV1}, nonce, Seal(KPV(amk, user), nonce, e, boxAD(user, recoveryPub, keyproto.PhraseBoxV1)))
}

// OpenPhraseBox opens in §5.5's order: version, AEAD, then RK(E).pub ==
// recovery_pubkey.
func OpenPhraseBox(amk []byte, user uuid.UUID, recoveryPub, box []byte) ([]byte, error) {
	if len(box) != keyproto.PhraseBoxSize || box[0] != keyproto.PhraseBoxV1 {
		return nil, ErrUnwrapFailed
	}
	e, err := Open(KPV(amk, user), box[1:13], box[13:], boxAD(user, recoveryPub, box[0]))
	if err != nil || len(e) != EntropySize {
		return nil, ErrUnwrapFailed
	}
	if subtle.ConstantTimeCompare(RKPub(e), recoveryPub) != 1 {
		return nil, ErrPhraseBoxMismatch
	}
	return e, nil
}
