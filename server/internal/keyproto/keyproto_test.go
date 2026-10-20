package keyproto

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math/big"
	"strings"
	"testing"

	"github.com/google/uuid"
)

const writer = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

func TestRegistryHas43DistinctStringsInIDOrder(t *testing.T) {
	r := Registry()
	if len(r) != 43 {
		t.Fatalf("%d strings, want 43", len(r))
	}
	seen := map[string]bool{}
	for i, d := range r {
		if want := "D" + string(rune('0'+(i+1)/10)) + string(rune('0'+(i+1)%10)); d.ID != want {
			t.Errorf("row %d is %s, want %s", i, d.ID, want)
		}
		if !strings.HasPrefix(d.String, "hasala/v1/") || seen[d.String] {
			t.Errorf("%s %q is not a new hasala/v1 string", d.ID, d.String)
		}
		seen[d.String] = true
	}
}

func TestMessageLengthsMatchTheTable(t *testing.T) {
	n := bytes.Repeat([]byte{7}, 32)
	h := bytes.Repeat([]byte{9}, 32)
	dak := append([]byte{4}, bytes.Repeat([]byte{1}, 64)...)
	u := uuid.New()
	var c [32]byte
	for _, tc := range []struct {
		name string
		b    func() ([]byte, error)
		n    int
	}{
		{"registration", func() ([]byte, error) { return RegistrationMessage(n, writer, h, dak) }, 201},
		{"revocation", func() ([]byte, error) { return RevocationMessage(n, writer, 0, h) }, 142},
		{"session-bind", func() ([]byte, error) { return SessionBindMessage(n, writer) }, 96},
		{"account-delete", func() ([]byte, error) { return DeletionMessage(n, u) }, 94},
		{"bootstrap", func() ([]byte, error) { return BootstrapMessage(n, []byte("p")) }, 84},
		{"recovery-signin", func() ([]byte, error) { return RecoverySigninPassword(n, h) }, 155},
		{"recovery-rotate", func() ([]byte, error) { return RecoveryRotateMessage(n, h, nil, nil) }, 154},
		{"epoch-rotate", func() ([]byte, error) { return EpochRotateMessage(n, 2, nil) }, 91},
		{"writer-head", func() ([]byte, error) { return HeadMessage(u, 1, h, writer) }, 119},
		{"passkey-add", func() ([]byte, error) { return PasskeyAddMessage(n, nil, nil, nil) }, 150},
		{"wrap-put", func() ([]byte, error) { return WrapPutMessage(n, nil, nil) }, 115},
		{"step-up-device", func() ([]byte, error) { return DeviceStepUpMessage(c, writer) }, 98},
		{"reset-approve", func() ([]byte, error) { return ResetApproveMessage(n, u, h, writer) }, 145},
		{"reset-finish", func() ([]byte, error) { return ResetFinishMessage(n, h) }, 87},
		{"email-change", func() ([]byte, error) { return EmailChangeMessage(n, "a@b.c") }, 87},
		{"device-freeze", func() ([]byte, error) { return DeviceFreezeMessage(n, u, writer) }, 113},
	} {
		m, err := tc.b()
		if err != nil || len(m) != tc.n {
			t.Errorf("%s: %d bytes, %v; want %d", tc.name, len(m), err, tc.n)
		}
	}
}

func TestBuildersRefuseWrongLengths(t *testing.T) {
	n := bytes.Repeat([]byte{7}, 32)
	if _, err := RegistrationMessage(n[:31], writer, n, append([]byte{4}, make([]byte, 64)...)); !errors.Is(err, ErrFieldLength) {
		t.Errorf("31-byte nonce: %v", err)
	}
	if _, err := RevocationMessage(n, writer+"x", 0, n); !errors.Is(err, ErrFieldLength) {
		t.Errorf("41-byte writer id: %v", err)
	}
	if _, err := HeadMessage(uuid.New(), 1, n[:31], writer); !errors.Is(err, ErrFieldLength) {
		t.Errorf("short hash: %v", err)
	}
	if _, err := SessionBindMessage(n, strings.Replace(writer, "a", "\x00", 1)); !errors.Is(err, ErrFieldLength) {
		t.Errorf("NUL in writer id: %v", err)
	}
	if _, err := RecoverySigninMessage(n, AuthKindNone, n, n, n); !errors.Is(err, ErrFieldLength) {
		t.Errorf("auth_kind 0 in recovery-signin: %v", err)
	}
	if _, err := ParamsHash("Not.An.Action"); !errors.Is(err, ErrFieldLength) {
		t.Errorf("bad action grammar: %v", err)
	}
}

func TestTwentyActionsAndTheirProofKinds(t *testing.T) {
	a := Actions()
	if len(a) != 20 {
		t.Fatalf("%d actions", len(a))
	}
	for _, x := range a {
		if !actionGrammar.MatchString(string(x)) || len(x) > 48 {
			t.Errorf("%q breaks the grammar", x)
		}
	}
	if !ProofAllowed(ActionPasswordReset, ProofDeviceCode) || ProofAllowed(ActionPasswordReset, ProofPasskey) {
		t.Error("password.reset is device_code only")
	}
	for _, x := range []Action{ActionPasswordSet, ActionPasswordRemove, ActionPhraseView, ActionKeysWrapPut, ActionKeysBootstrap} {
		if ProofAllowed(x, ProofDevice) || !ProofAllowed(x, ProofPasskey) {
			t.Errorf("%s is passkey only", x)
		}
	}
	if ValidAction("writer.register") {
		t.Error("writer.register is not a step-up action")
	}
}

func TestEncTupleEmptyFieldAndEmptyTuple(t *testing.T) {
	if len(EncTuple()) != 0 {
		t.Error("an empty tuple is zero bytes")
	}
	if got := hex.EncodeToString(EncTuple([]byte{}, []byte{1})); got != "000000000000000101" {
		t.Errorf("enc((), (1)) = %s", got)
	}
}

func TestWrapAndBoxShapes(t *testing.T) {
	w := make([]byte, 127)
	w[0], w[1] = 1, 1
	if CheckRecoveryWrap(w) != nil || CheckPRFWrap(w) == nil {
		t.Error("kdf 0x01 is a recovery wrap only")
	}
	w[1] = 2
	if CheckPRFWrap(w) != nil || CheckRecoveryWrap(w) == nil {
		t.Error("kdf 0x02 is a PRF wrap only")
	}
	for _, n := range []int{126, 128} {
		x := make([]byte, n)
		x[0], x[1] = 1, 2
		if CheckPRFWrap(x) == nil {
			t.Errorf("%d bytes accepted", n)
		}
	}
	w[0] = 2
	if CheckPRFWrap(w) == nil {
		t.Error("version 0x02 accepted")
	}
	b := make([]byte, 45)
	b[0] = 1
	if CheckPhraseBox(b) != nil || CheckPhraseBox(b[:44]) == nil || CheckPhraseBox(append(b, 0)) == nil {
		t.Error("phrase box is exactly 45 bytes")
	}
	b[0] = 2
	if CheckPhraseBox(b) == nil {
		t.Error("phrase box version 2 accepted")
	}
}

func TestWriterIDGrammar(t *testing.T) {
	for _, ok := range []string{writer, "ios-00000000-0000-4000-8000-000000000000"} {
		if !ValidWriterID(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{
		"dev-a", "ios-0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D", // uppercase
		"ios-0a1b2c3d-4e5f-3a6b-8c7d-9e0f1a2b3c4d", // version 3
		"ios-0a1b2c3d-4e5f-4a6b-cc7d-9e0f1a2b3c4d", // variant c
		writer + "\n", "ingest",
	} {
		if ValidWriterID(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestSmallOrderEd25519KeysAreRefused(t *testing.T) {
	identity := append([]byte{1}, make([]byte, 31)...)
	if CheckEd25519PublicKey(identity) == nil {
		t.Fatal("the identity point is accepted")
	}
	// The forgery the check exists for: identity ‖ 0^32 verifies under the
	// identity point for any message in crypto/ed25519, and VerifyEd25519
	// refuses it.
	sig := append(append([]byte(nil), identity...), make([]byte, 32)...)
	if VerifyEd25519(identity, []byte("anything"), sig) {
		t.Fatal("VerifyEd25519 accepted the small-order forgery")
	}
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	if CheckEd25519PublicKey(pub) != nil || !VerifyEd25519(pub, []byte("m"), ed25519.Sign(priv, []byte("m"))) {
		t.Fatal("an honest key is refused")
	}
	if CheckEd25519PublicKey(pub[:31]) == nil {
		t.Fatal("a 31-byte key is accepted")
	}
}

func x963(k *ecdsa.PublicKey) []byte {
	out := []byte{4}
	out = append(out, k.X.FillBytes(make([]byte, 32))...)
	return append(out, k.Y.FillBytes(make([]byte, 32))...)
}

func TestDAKParseAndVerify(t *testing.T) {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pub := x963(&k.PublicKey)
	msg := []byte("hasala/v1/step-up-device\x00…")
	h := sha256.Sum256(msg)
	r, s, _ := ecdsa.Sign(rand.Reader, k, h[:])
	sig := append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
	if !VerifyDAKBytes(pub, msg, sig) {
		t.Fatal("an honest DAK signature is refused")
	}
	if VerifyDAKBytes(pub, append(msg, 0), sig) {
		t.Fatal("a signature over another message verifies")
	}
	n := elliptic.P256().Params().N
	for name, bad := range map[string][]byte{
		"r = 0":   append(make([]byte, 32), sig[32:]...),
		"s = 0":   append(append([]byte(nil), sig[:32]...), make([]byte, 32)...),
		"r = n":   append(n.FillBytes(make([]byte, 32)), sig[32:]...),
		"s = n":   append(append([]byte(nil), sig[:32]...), n.FillBytes(make([]byte, 32))...),
		"s = n+1": append(append([]byte(nil), sig[:32]...), new(big.Int).Add(n, big.NewInt(1)).FillBytes(make([]byte, 32))...),
	} {
		if VerifyDAKBytes(pub, msg, bad) {
			t.Errorf("%s verifies", name)
		}
	}
	off := append([]byte(nil), pub...)
	off[64] ^= 1
	compressed := append([]byte{2 + byte(k.Y.Bit(0))}, pub[1:33]...)
	zero := append([]byte{4}, make([]byte, 64)...)
	for name, b := range map[string][]byte{"off the curve": off, "compressed": compressed, "(0,0)": zero} {
		if _, err := ParseDAK(b); err == nil {
			t.Errorf("%s DAK parsed", name)
		}
	}
}

func TestEmailNorm(t *testing.T) {
	for in, want := range map[string]string{
		"  Maya.Rahman+Hasala@Gmail.COM ": "maya.rahman+hasala@gmail.com",
		"\tA@B.CO\t":                      "a@b.co",
		"x@y.z":                           "x@y.z",
	} {
		got, err := EmailNorm(in)
		if err != nil || got != want {
			t.Errorf("EmailNorm(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{
		"maya@exämple.com", "a@@b.c", "a@b@c.d", "a@bc", "a@.bc", "a@bc.", "a b@c.d",
		"@b.c", "a@", strings.Repeat("a", 65) + "@b.c", strings.Repeat("a", 64) + "@" + strings.Repeat("b", 186) + ".com",
	} {
		if _, err := EmailNorm(bad); err == nil {
			t.Errorf("EmailNorm(%q) accepted", bad)
		}
	}
}

func TestNameOK(t *testing.T) {
	for _, ok := range []string{"Maya Rahman", "مايا رحمن", strings.Repeat("م", 64), "O’Neil-Ahmed"} {
		if !NameOK(ok) {
			t.Errorf("NameOK(%q) refused", ok)
		}
	}
	for _, bad := range []string{"", strings.Repeat("a", 65), " Maya", "Maya ", "Maya  R", "a\u202eb", "a\u200bb", "a\u00a0b", "a\tb", "\xff"} {
		if NameOK(bad) {
			t.Errorf("NameOK(%q) accepted", bad)
		}
	}
}

func TestBootstrapPayloadRefusesHalfAPRFWrap(t *testing.T) {
	p := BootstrapPayload{
		UserID: uuid.New(), AMKCommitment: make([]byte, 32), AuthorityPubkey: make([]byte, 32),
		RecoveryPubkey: make([]byte, 32), RecoveryWrap: append([]byte{1, 1}, make([]byte, 125)...),
		PhraseBox: append([]byte{1}, make([]byte, 44)...), EmailHash: make([]byte, 32),
		AuthHash: make([]byte, 32), WriterPubkey: make([]byte, 32),
		WriterDAK: append([]byte{4}, make([]byte, 64)...), WriterID: writer,
	}
	b, err := p.Bytes()
	if err != nil || len(b) != 501 {
		t.Fatalf("%d bytes, %v", len(b), err)
	}
	p.CredentialID = make([]byte, 16)
	if _, err := p.Bytes(); err == nil {
		t.Fatal("a credential without a wrap builds")
	}
	p.PRFWrap = append([]byte{1, 1}, make([]byte, 125)...)
	if _, err := p.Bytes(); err == nil {
		t.Fatal("a PRF wrap with kdf 0x01 builds")
	}
	p.PRFWrap[1] = 2
	if b, err := p.Bytes(); err != nil || len(b) != 501+16+127 {
		t.Fatalf("%d bytes, %v", len(b), err)
	}
	if p.CheckKeys() == nil {
		t.Fatal("all-zero keys pass CheckKeys")
	}
}

func TestInviteLinkKey(t *testing.T) {
	k := bytes.Repeat([]byte{5}, 32)
	h := sha256.Sum256(k)
	if !InviteLinkKeyMatches(k, h[:]) || InviteLinkKeyMatches(k[:31], h[:]) || InviteLinkKeyMatches(append(k[:31], 6), h[:]) {
		t.Fatal("link-key check")
	}
}
