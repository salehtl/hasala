package keyproto

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"regexp"

	"filippo.io/edwards25519"
)

// Wraps and the phrase box (spec 01 §5.1, §5.5). The server stores both
// opaque; it checks only the exact length and the header bytes it is told to
// check, never anything a key would be needed for.
//
//	wrap = version(1) ‖ kdf(1) ‖ salt(32) ‖ nonce(12) ‖ ct(65) ‖ tag(16)   = 127 bytes
//	box  = 0x01 ‖ nonce(12) ‖ ct(16) ‖ tag(16)                              = 45 bytes
const (
	WrapSize       = 127
	WrapHeaderSize = 46
	WrapVersion1   = 0x01
	PhraseBoxSize  = 45
	PhraseBoxV1    = 0x01

	// KDF ids (spec 01 §5.1). 0x03 is reserved for a stretched phrase root.
	KDFRecovery = 0x01
	KDFPRF      = 0x02

	// CredentialID bounds (webauthn_credentials_id_is_bounded).
	MinCredentialID = 16
	MaxCredentialID = 1023
)

// ErrShape is a wrap, phrase box, key or id of the wrong form.
var ErrShape = errors.New("keyproto: malformed")

// CheckRecoveryWrap is the server's check of account_keys.recovery_wrap:
// exactly 127 bytes, version 0x01, kdf 0x01.
func CheckRecoveryWrap(w []byte) error { return checkWrap(w, KDFRecovery) }

// CheckPRFWrap is the server's check of a PRF wrap: exactly 127 bytes,
// version 0x01, kdf 0x02.
func CheckPRFWrap(w []byte) error { return checkWrap(w, KDFPRF) }

func checkWrap(w []byte, kdf byte) error {
	if len(w) != WrapSize {
		return fmt.Errorf("%w: wrap is %d bytes, want %d", ErrShape, len(w), WrapSize)
	}
	if w[0] != WrapVersion1 {
		return fmt.Errorf("%w: wrap version 0x%02x", ErrShape, w[0])
	}
	if w[1] != kdf {
		return fmt.Errorf("%w: wrap kdf 0x%02x, want 0x%02x", ErrShape, w[1], kdf)
	}
	return nil
}

// CheckPhraseBox is the server's check of account_keys.phrase_box: exactly 45
// bytes, byte 0 = 0x01.
func CheckPhraseBox(b []byte) error {
	if len(b) != PhraseBoxSize {
		return fmt.Errorf("%w: phrase box is %d bytes, want %d", ErrShape, len(b), PhraseBoxSize)
	}
	if b[0] != PhraseBoxV1 {
		return fmt.Errorf("%w: phrase box version 0x%02x", ErrShape, b[0])
	}
	return nil
}

// CheckCredentialID bounds a raw credential id (16–1023 bytes).
func CheckCredentialID(id []byte) error {
	if len(id) < MinCredentialID || len(id) > MaxCredentialID {
		return fmt.Errorf("%w: credential id is %d bytes", ErrShape, len(id))
	}
	return nil
}

var writerIDGrammar = regexp.MustCompile(`^ios-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// ValidWriterID is spec 01 §4.8's grammar: "ios-" ‖ a lowercase UUIDv4, 40
// ASCII characters. The writers and key_history CHECKs restate it (spec 02
// N-03).
func ValidWriterID(id string) bool { return writerIDGrammar.MatchString(id) }

// CheckEd25519PublicKey refuses a key that cannot carry "a valid signature
// proves possession of the private key": the wrong length, a non-point, or a
// point of small order. Under the identity point the signature identity ‖ 0^32
// verifies for every message, so length alone is not enough (spec 01 §10.1:
// small-order rejection before verifying anything). edwards25519.SetBytes
// accepts the non-canonical encodings crypto/ed25519 accepts, so no encoding
// slips past here and still verifies.
func CheckEd25519PublicKey(pub []byte) error {
	if len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("%w: Ed25519 key is %d bytes", ErrShape, len(pub))
	}
	p, err := new(edwards25519.Point).SetBytes(pub)
	if err != nil {
		return fmt.Errorf("%w: Ed25519 key is not a curve point", ErrShape)
	}
	if new(edwards25519.Point).MultByCofactor(p).Equal(edwards25519.NewIdentityPoint()) == 1 {
		return fmt.Errorf("%w: Ed25519 key has small order", ErrShape)
	}
	return nil
}

// VerifyEd25519 checks a signature under a key that passes
// CheckEd25519PublicKey. Every server-side Ed25519 verification goes through
// it, so a key read back from a row planted past the write-time check still
// authorizes nothing.
func VerifyEd25519(pub, msg, sig []byte) bool {
	if CheckEd25519PublicKey(pub) != nil || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pub), msg, sig)
}

// InviteLinkKeyMatches is spec 01 §10.3's link-key half of the address proof:
// a 32-byte key whose SHA-256 equals the invite's stored link_key_hash,
// compared in constant time. The caller also requires the invite's email_tag to
// equal the address's.
func InviteLinkKeyMatches(linkKey, linkKeyHash []byte) bool {
	if len(linkKey) != 32 || len(linkKeyHash) != 32 {
		return false
	}
	h := sha256.Sum256(linkKey)
	return subtle.ConstantTimeCompare(h[:], linkKeyHash) == 1
}

// distinct reports whether all the given byte strings differ pairwise.
func distinct(keys ...[]byte) bool {
	for i := range keys {
		for j := i + 1; j < len(keys); j++ {
			if bytes.Equal(keys[i], keys[j]) {
				return false
			}
		}
	}
	return true
}
