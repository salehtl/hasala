package keyproto

import (
	"crypto/sha256"
	"encoding/base32"
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ErrBadEmail is an address email_norm refuses (spec 02's 400 bad_email).
var ErrBadEmail = errors.New("keyproto: not an address this beta accepts")

// EmailNorm is spec 01 §4.11's normalization:
//
//  1. every byte is 0x09 or in 0x20–0x7E (non-ASCII addresses are refused);
//  2. strip leading and trailing 0x20 and 0x09;
//  3. ASCII-lowercase A–Z;
//  4. valid iff 3 ≤ length ≤ 254, exactly one '@', a local part of 1–64 bytes,
//     a domain of 1–253 bytes containing a '.' that is at neither end, and no
//     byte below 0x21.
//
// Nothing else is canonicalized: dots and +tags are kept. The users CHECK
// restates the result's shape.
func EmailNorm(x string) (string, error) {
	for i := 0; i < len(x); i++ {
		c := x[i]
		if c != 0x09 && (c < 0x20 || c > 0x7e) {
			return "", ErrBadEmail
		}
	}
	s := strings.Trim(x, " \t")
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	s = string(b)
	if len(s) < 3 || len(s) > 254 || strings.Count(s, "@") != 1 {
		return "", ErrBadEmail
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x21 {
			return "", ErrBadEmail
		}
	}
	at := strings.IndexByte(s, '@')
	local, domain := s[:at], s[at+1:]
	if len(local) < 1 || len(local) > 64 || len(domain) < 1 || len(domain) > 253 {
		return "", ErrBadEmail
	}
	if domain[0] == '.' || domain[len(domain)-1] == '.' || !strings.Contains(domain, ".") {
		return "", ErrBadEmail
	}
	return s, nil
}

// EmailHash is SHA256(utf8(email_norm)): the address binding inside
// BootstrapPayload (§10.3.1).
func EmailHash(emailNorm string) [32]byte { return sha256.Sum256([]byte(emailNorm)) }

// NameOK is spec 01 §4.11's display-name floor: valid UTF-8, 1–64 Unicode
// scalars, each Go unicode.IsGraphic and not in Zs except U+0020, no leading
// or trailing U+0020 and no two in a row. Spec 02 §10.7.4's DisplayName is the
// narrower rule the server enforces; every name it accepts passes this.
func NameOK(x string) bool {
	if !utf8.ValidString(x) {
		return false
	}
	n := utf8.RuneCountInString(x)
	if n < 1 || n > 64 {
		return false
	}
	if x[0] == ' ' || x[len(x)-1] == ' ' || strings.Contains(x, "  ") {
		return false
	}
	for _, r := range x {
		if r == ' ' {
			continue
		}
		if !unicode.IsGraphic(r) || unicode.Is(unicode.Zs, r) {
			return false
		}
	}
	return true
}

// ResetCode is C9's 80-bit approval code (D37): code80 =
// SHA256("hasala/v1/reset-code" ‖ 00 ‖ ek_pub32)[0:10], shown as base32
// without padding (16 characters). hasalad never computes it (spec 02 §3.3);
// the vectors and the Swift tests do.
func ResetCode(ekPub []byte) (code80 []byte, code string, err error) {
	if err := need("ek_pub", ekPub, Ed25519KeySize); err != nil {
		return nil, "", err
	}
	m := prefix(DomainResetCode, len(DomainResetCode)+1+32)
	m = append(m, ekPub...)
	h := sha256.Sum256(m)
	code80 = append([]byte(nil), h[:10]...)
	return code80, base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(code80), nil
}
