// Package authkeys holds the server's two key files and everything derived
// from them (spec 01 §4.10–§4.11, §12.2; spec 02 §3.3):
//
//	K_salt     = HKDF(salt_key,   0^32, "hasala/v1/server/password-salt")   s_srv = HMAC(K_salt, email_norm)
//	K_pepper_g = HKDF(auth_key_g, 0^32, "hasala/v1/server/password-pepper") pw_hash = PBKDF2(HMAC(K_pepper_g, S), pw_salt, 100000)
//	K_code     = HKDF(auth_key_c, 0^32, "hasala/v1/server/email-code")      code_mac = HMAC(K_code, purpose ‖ 00 ‖ uuid_raw(code_id) ‖ email_tag ‖ code)
//	K_tag      = HKDF(auth_key_c, 0^32, "hasala/v1/server/email-tag")       email_tag = HMAC(K_tag, email_norm)
//	key_id(k)  = hex(HMAC(k, "hasala/v1/server/auth-key-id")[0:8])
//
// salt_key is never rotated and keys only s_srv, which is public by design;
// auth_key rotates by generation [P] (generation 1 in the beta). Nothing here
// derives or wraps anything under a password: S is peppered and hashed for
// comparison, never used as key material (PO B, spec 01 §4.10). This is the
// only package that imports crypto/pbkdf2 (spec 02 §4.4 fence 3(d)).
package authkeys

import (
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

// Sizes and work factors.
const (
	KeySize          = 32
	PasswordSaltSize = 16
	VerifierSize     = 32
	ServerIterations = 100_000
	CodeDigits       = 6
)

// Code purposes (spec 01 §10.14): a closed set.
var codePurposes = []string{
	"signup", "email_verify", "email_change_old", "email_change_new",
	"password_reset", "recovery", "waitlist",
}

// CodePurposes returns the closed set of email-code purposes.
func CodePurposes() []string { return append([]string(nil), codePurposes...) }

// ErrKeyFile is a key file that is not exactly 64 hex characters.
var ErrKeyFile = errors.New("authkeys: a key file holds exactly 64 hex characters")

// ParseKeyHex reads a key file's contents: 64 hex characters, with at most a
// trailing newline. Anything else is refused rather than repaired.
func ParseKeyHex(s string) ([]byte, error) {
	s = strings.TrimSuffix(strings.TrimSuffix(s, "\n"), "\r")
	if len(s) != 2*KeySize {
		return nil, ErrKeyFile
	}
	k, err := hex.DecodeString(s)
	if err != nil {
		return nil, ErrKeyFile
	}
	return k, nil
}

// Keys is the derived key set. Build it with New; it holds no file paths.
type Keys struct {
	kSalt   []byte
	peppers map[int][]byte // generation → K_pepper_g
	current int
	kCode   []byte
	kTag    []byte
	kInvite []byte

	SaltKeyID string         // key_id(salt_key)
	AuthKeyID map[int]string // generation → key_id(auth_key_g)

	hashes atomic.Int64 // VerifierHash calls, for the uniform-cost tests (spec 02 AT-AUTH-3)
}

// HashCount is how many server PBKDF2 computations this key set has run.
func (k *Keys) HashCount() int64 { return k.hashes.Load() }

// New derives the key set from salt_key and the auth_key generations it is
// given (map generation → 32-byte key); current is the generation new hashes,
// codes and tags use. In the beta that is {1: auth_key}, current 1.
func New(saltKey []byte, authKeys map[int][]byte, current int) (*Keys, error) {
	if len(saltKey) != KeySize {
		return nil, fmt.Errorf("authkeys: salt_key is %d bytes, want %d", len(saltKey), KeySize)
	}
	cur, ok := authKeys[current]
	if !ok {
		return nil, fmt.Errorf("authkeys: no auth_key for the current generation %d", current)
	}
	k := &Keys{
		peppers:   map[int][]byte{},
		current:   current,
		SaltKeyID: KeyID(saltKey),
		AuthKeyID: map[int]string{},
	}
	var err error
	if k.kSalt, err = subkey(saltKey, keyproto.DomainServerPasswordSalt); err != nil {
		return nil, err
	}
	for g, ak := range authKeys {
		if g < 1 {
			return nil, fmt.Errorf("authkeys: generation %d is not ≥ 1", g)
		}
		if len(ak) != KeySize {
			return nil, fmt.Errorf("authkeys: auth_key generation %d is %d bytes, want %d", g, len(ak), KeySize)
		}
		if k.peppers[g], err = subkey(ak, keyproto.DomainServerPasswordPeppr); err != nil {
			return nil, err
		}
		k.AuthKeyID[g] = KeyID(ak)
	}
	if k.kCode, err = subkey(cur, keyproto.DomainServerEmailCode); err != nil {
		return nil, err
	}
	if k.kTag, err = subkey(cur, keyproto.DomainServerEmailTag); err != nil {
		return nil, err
	}
	if k.kInvite, err = subkey(cur, keyproto.DomainServerInviteMint); err != nil {
		return nil, err
	}
	return k, nil
}

// Current is the generation new hashes are made under.
func (k *Keys) Current() int { return k.current }

// subkey is HKDF(ikm, 0^32, info) with the 32 zero bytes passed explicitly
// (spec 01 §1).
func subkey(ikm []byte, info string) ([]byte, error) {
	return hkdf.Key(sha256.New, ikm, make([]byte, 32), info, KeySize)
}

func mac(key []byte, parts ...[]byte) []byte {
	h := hmac.New(sha256.New, key)
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

// KeyID is D41: hex(HMAC(k, "hasala/v1/server/auth-key-id")[0:8]).
func KeyID(k []byte) string {
	return hex.EncodeToString(mac(k, []byte(keyproto.DomainServerAuthKeyID))[:8])
}

// PasswordSalt is s_srv = HMAC(K_salt, utf8(email_norm)): the public
// per-address salt. It is the same before, during and after an account exists.
func (k *Keys) PasswordSalt(emailNorm string) []byte {
	return mac(k.kSalt, []byte(emailNorm))
}

// EmailTag is HMAC(K_tag, utf8(email_norm)).
func (k *Keys) EmailTag(emailNorm string) []byte {
	return mac(k.kTag, []byte(emailNorm))
}

func (k *Keys) InviteSecrets(inviteID uuid.UUID, mailID int64) (code, link []byte) {
	return inviteSecrets(k.kInvite, inviteID, mailID)
}

func inviteSecrets(key []byte, inviteID uuid.UUID, mailID int64) (code, link []byte) {
	id := binary.BigEndian.AppendUint64(nil, uint64(mailID))
	code = mac(key, []byte("code"), []byte{0}, inviteID[:], id)[:15]
	link = mac(key, []byte("link"), []byte{0}, inviteID[:], id)
	return code, link
}

// CodeMAC is HMAC(K_code, utf8(purpose) ‖ 00 ‖ uuid_raw(code_id) ‖ email_tag
// ‖ utf8(code)).
func (k *Keys) CodeMAC(purpose string, codeID uuid.UUID, emailTag []byte, code string) ([]byte, error) {
	if !validPurpose(purpose) {
		return nil, fmt.Errorf("authkeys: %q is not a code purpose", purpose)
	}
	if len(emailTag) != 32 {
		return nil, fmt.Errorf("authkeys: email_tag is %d bytes", len(emailTag))
	}
	if len(code) != CodeDigits {
		return nil, fmt.Errorf("authkeys: a code is %d digits", CodeDigits)
	}
	for i := 0; i < len(code); i++ {
		if code[i] < '0' || code[i] > '9' {
			return nil, fmt.Errorf("authkeys: a code is %d digits", CodeDigits)
		}
	}
	return mac(k.kCode, []byte(purpose), []byte{0}, codeID[:], emailTag, []byte(code)), nil
}

// CodeMatches recomputes the MAC from the submitted digits and compares it in
// constant time.
func (k *Keys) CodeMatches(stored []byte, purpose string, codeID uuid.UUID, emailTag []byte, code string) bool {
	m, err := k.CodeMAC(purpose, codeID, emailTag, code)
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(m, stored) == 1
}

func validPurpose(p string) bool {
	for _, q := range codePurposes {
		if p == q {
			return true
		}
	}
	return false
}

// Pepper is HMAC(K_pepper_g, S), the PBKDF2 password input under generation g.
func (k *Keys) Pepper(s []byte, generation int) ([]byte, error) {
	kp, ok := k.peppers[generation]
	if !ok {
		return nil, fmt.Errorf("authkeys: no pepper for generation %d", generation)
	}
	if len(s) != VerifierSize {
		return nil, fmt.Errorf("authkeys: a verifier S is %d bytes", VerifierSize)
	}
	return mac(kp, s), nil
}

// VerifierHash is pw_hash = PBKDF2(HMAC(K_pepper_g, S), pw_salt, 100000).
func (k *Keys) VerifierHash(s, pwSalt []byte, generation int) ([]byte, error) {
	if len(pwSalt) != PasswordSaltSize {
		return nil, fmt.Errorf("authkeys: pw_salt is %d bytes, want %d", len(pwSalt), PasswordSaltSize)
	}
	p, err := k.Pepper(s, generation)
	if err != nil {
		return nil, err
	}
	k.hashes.Add(1)
	return pbkdf2.Key(sha256.New, string(p), pwSalt, ServerIterations, VerifierSize)
}
