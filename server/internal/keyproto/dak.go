package keyproto

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"fmt"
	"math/big"
)

// The device approval key (spec 01 §4.9): a Secure Enclave P-256 key per
// writer, published as the 65-byte X9.63 point 04 ‖ X ‖ Y and certified by the
// AAK inside the RegistrationMessage. Its signatures are the 64 raw bytes
// r ‖ s over SHA256(m). The server only verifies (spec 02 §4.4 fence 3(d): no
// ecdsa.Sign in production).

// ParseDAK parses a DAK with ecdsa.ParseUncompressedPublicKey, which refuses a
// compressed point, a point off the curve and the point at infinity (V-H).
func ParseDAK(b []byte) (*ecdsa.PublicKey, error) {
	if len(b) != DAKKeySize || b[0] != 0x04 {
		return nil, fmt.Errorf("%w: DAK is not a 65-byte uncompressed point", ErrShape)
	}
	pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), b)
	if err != nil {
		return nil, fmt.Errorf("%w: DAK: %v", ErrShape, err)
	}
	return pub, nil
}

// VerifyDAK verifies a raw r ‖ s signature over SHA256(msg). It refuses r or s
// equal to 0 or at least the group order before calling ecdsa.Verify (spec 01
// §10.1).
func VerifyDAK(pub *ecdsa.PublicKey, msg, sig []byte) bool {
	if pub == nil || len(sig) != DAKSigSize {
		return false
	}
	n := elliptic.P256().Params().N
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if r.Sign() == 0 || s.Sign() == 0 || r.Cmp(n) >= 0 || s.Cmp(n) >= 0 {
		return false
	}
	h := sha256.Sum256(msg)
	return ecdsa.Verify(pub, h[:], r, s)
}

// VerifyDAKBytes is ParseDAK then VerifyDAK.
func VerifyDAKBytes(dak, msg, sig []byte) bool {
	pub, err := ParseDAK(dak)
	if err != nil {
		return false
	}
	return VerifyDAK(pub, msg, sig)
}
