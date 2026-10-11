package authkeys

import (
	"bytes"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// The A19 and A19-K values are pinned in internal/cryptoref's anchor test;
// these are the package's own refusals.

func TestParseKeyHexIsExact(t *testing.T) {
	good := strings.Repeat("ab", 32)
	for _, s := range []string{good, good + "\n", good + "\r\n"} {
		if k, err := ParseKeyHex(s); err != nil || len(k) != 32 {
			t.Errorf("%q: %v", s, err)
		}
	}
	for _, s := range []string{"", good[:62], good + "ab", " " + good, strings.Repeat("zz", 32), good + "\n\n"} {
		if _, err := ParseKeyHex(s); err == nil {
			t.Errorf("%q accepted", s)
		}
	}
}

func TestCodesBindPurposeIDAddressAndGeneration(t *testing.T) {
	salt := bytes.Repeat([]byte{1}, 32)
	k1, err := New(salt, map[int][]byte{1: bytes.Repeat([]byte{2}, 32)}, 1)
	if err != nil {
		t.Fatal(err)
	}
	k2, err := New(salt, map[int][]byte{1: bytes.Repeat([]byte{2}, 32), 2: bytes.Repeat([]byte{3}, 32)}, 2)
	if err != nil {
		t.Fatal(err)
	}
	id := uuid.New()
	tag := k1.EmailTag("a@b.co")
	m, err := k1.CodeMAC("recovery", id, tag, "012345")
	if err != nil {
		t.Fatal(err)
	}
	if !k1.CodeMatches(m, "recovery", id, tag, "012345") {
		t.Fatal("the code does not verify")
	}
	for name, ok := range map[string]bool{
		"other purpose":    k1.CodeMatches(m, "signup", id, tag, "012345"),
		"other id":         k1.CodeMatches(m, "recovery", uuid.New(), tag, "012345"),
		"other address":    k1.CodeMatches(m, "recovery", id, k1.EmailTag("c@d.co"), "012345"),
		"other digits":     k1.CodeMatches(m, "recovery", id, tag, "012346"),
		"other generation": k2.CodeMatches(m, "recovery", id, tag, "012345"),
	} {
		if ok {
			t.Errorf("%s verifies", name)
		}
	}
	if _, err := k1.CodeMAC("login", id, tag, "012345"); err == nil {
		t.Error("an unknown purpose is accepted")
	}
	if _, err := k1.CodeMAC("recovery", id, tag, "12345a"); err == nil {
		t.Error("a non-digit code is accepted")
	}
	if !bytes.Equal(k1.PasswordSalt("a@b.co"), k2.PasswordSalt("a@b.co")) {
		t.Error("s_srv depends on auth_key; it must depend on salt_key only")
	}
	if _, err := k1.VerifierHash(make([]byte, 32), make([]byte, 16), 2); err == nil {
		t.Error("a generation that is not loaded verifies")
	}
	if _, err := New(salt, map[int][]byte{1: salt}, 2); err == nil {
		t.Error("a current generation without a key is accepted")
	}
}
