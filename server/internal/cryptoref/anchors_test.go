package cryptoref_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	. "github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// Every anchor of spec 01 §15.5 (A01–A26) reproduced byte for byte from the
// inputs table. Go's Ed25519 signatures are deterministic, so the printed ones
// are compared as well as verified; P-256 signatures are randomized and are
// verify-only (spec 01 §1).

func want(t *testing.T, key string, got []byte) {
	t.Helper()
	exp, ok := Anchors[key]
	if !ok {
		t.Fatalf("no anchor %q", key)
	}
	if !bytes.Equal(got, Hex(exp)) {
		t.Errorf("%s:\n got %x\nwant %s", key, got, strings.Join(strings.Fields(exp), ""))
	}
}

func wantStr(t *testing.T, key, got string) {
	t.Helper()
	if got != Anchors[key] {
		t.Errorf("%s: got %q, want %q", key, got, Anchors[key])
	}
}

func h(b []byte) []byte { s := sha256.Sum256(b); return s[:] }

func must[T any](t *testing.T) func(T, error) T {
	return func(v T, err error) T {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
}

func sign(seed, msg []byte) []byte { return ed25519.Sign(ed25519.NewKeyFromSeed(seed), msg) }

func wantSig(t *testing.T, key string, seed, msg []byte) {
	t.Helper()
	sig := sign(seed, msg)
	want(t, key, sig)
	if !keyproto.VerifyEd25519(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey), msg, Hex(Anchors[key])) {
		t.Errorf("%s does not verify", key)
	}
}

func wantDAK(t *testing.T, key string, msg []byte) {
	t.Helper()
	if !keyproto.VerifyDAKBytes(AnchorDAKPub(), msg, Hex(Anchors[key])) {
		t.Errorf("%s: the sample P-256 signature does not verify under A13's DAK", key)
	}
}

func a19Keys(t *testing.T, authKey []byte) *authkeys.Keys {
	t.Helper()
	k, err := authkeys.New(AnchorSaltKey, map[int][]byte{1: authKey}, 1)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// a19S is S of A19 (600,000 iterations).
func a19S(t *testing.T) []byte {
	t.Helper()
	norm := must[string](t)(keyproto.EmailNorm(AnchorEmailInput))
	return Stretch(AnchorPasswordNFD, a19Keys(t, AnchorAuthKeyA19).PasswordSalt(norm), norm)
}

func TestAnchorsA01ToA08(t *testing.T) {
	salt := PRFSalt()
	want(t, "A01 PRF_SALT", salt[:])
	wantStr(t, "A02 phrase", strings.Join(Words(AnchorE), " "))
	want(t, "A03 RK_seed", RKSeed(AnchorE))
	want(t, "A03 RK_seed", HKDF(AnchorE, nil, []byte(keyproto.DomainRecoveryKey))) // "same with an empty salt"
	want(t, "A03 RK.pub", RKPub(AnchorE))
	want(t, "A04 AAK.pub", AAKPub(AnchorAAKSeed))
	want(t, "A04 DWK.pub", AAKPub(AnchorDWKSeed))
	want(t, "A05 amk_commit", AMKCommit(AnchorAMK, AnchorUser))
	want(t, "A06 K_1", EpochKey1(AnchorAMK, AnchorUser))
	want(t, "A07 RWK", RWK(AnchorE, AnchorRecoverySalt))
	body := Body(AnchorAMK, AnchorAAKSeed)
	want(t, "A07 recovery_wrap", SealRecoveryWrap(AnchorE, AnchorRecoverySalt, AnchorRecoveryNonce, body, AnchorUser))
	want(t, "A08 PWK", PWK(AnchorP, AnchorPRFSalt))
	want(t, "A08 prf_wrap", SealPRFWrap(AnchorP, AnchorPRFSalt, AnchorPRFNonce, body, AnchorUser, AnchorCredentialID))
}

// AnchorRegion is the synthetic R of A09/A10: u32be(16) ‖ 00..0f ‖ zeros.
func anchorRegion(n int) []byte {
	r := make([]byte, n)
	binary.BigEndian.PutUint32(r, 16)
	copy(r[4:], Range(0x00, 0x0f))
	return r
}

func TestAnchorsA09A10Frames(t *testing.T) {
	k1 := EpochKey1(AnchorAMK, AnchorUser)
	env := blob.Envelope{UserID: AnchorUser, Stream: blob.StreamHot, WriterID: AnchorWriterID, WriterCounter: 1}
	header := must[[]byte](t)(blob.Header3(env, 1))
	want(t, "A09 header", header)
	if l := len(header) - blob.FixedHeaderSize; l != 83 {
		t.Fatalf("L = %d, want 83", l)
	}
	region := anchorRegion(1024 - 35 - 83)
	if len(region) != 906 {
		t.Fatalf("|R| = %d", len(region))
	}
	ad := append(append(append([]byte(keyproto.DomainBlob), 0), header...), make([]byte, 32)...)
	want(t, "A09 SHA256(AD)", h(ad))
	want(t, "A09 K_blob", must[[]byte](t)(blobtest.BlobKey3(k1, header, blob.ZeroHash, AnchorFrameNonce1)))
	f1 := must[[]byte](t)(blobtest.SealRegion3(k1, header, blob.ZeroHash, AnchorFrameNonce1, region))
	if len(f1) != 1024 {
		t.Fatalf("frame is %d bytes", len(f1))
	}
	want(t, "A09 ct[0:16]", f1[len(header)+12:len(header)+28])
	want(t, "A09 tag", f1[1008:])
	want(t, "A09 SHA256(frame)", h(f1))
	h1 := blob.Hash(blob.ZeroHash, blob.Sealed{Bytes: f1, SizeBucket: 1024})
	want(t, "A09 blob_hash", h1[:])

	env.WriterCounter = 2
	header2 := must[[]byte](t)(blob.Header3(env, 1))
	want(t, "A10 K_blob", must[[]byte](t)(blobtest.BlobKey3(k1, header2, h1, AnchorFrameNonce2)))
	f2 := must[[]byte](t)(blobtest.SealRegion3(k1, header2, h1, AnchorFrameNonce2, anchorRegion(1024-35-83)))
	want(t, "A10 tag", f2[1008:])
	want(t, "A10 SHA256(frame)", h(f2))
	h2 := blob.Hash(h1, blob.Sealed{Bytes: f2, SizeBucket: 1024})
	want(t, "A10 blob_hash", h2[:])
}

func TestAnchorsA11A12A23StepUp(t *testing.T) {
	n := AnchorStepUpNonce
	want(t, "A11 enc(cred)", keyproto.EncTuple(AnchorCredentialID))
	cases := []struct {
		key    string
		action keyproto.Action
		fields [][]byte
	}{
		{"passkey.delete", keyproto.ActionPasskeyDelete, [][]byte{AnchorCredentialID}},
		{"session.logout_all", keyproto.ActionSessionLogoutAll, nil},
		{"keys.bootstrap", keyproto.ActionKeysBootstrap, [][]byte{AAKPub(AnchorAAKSeed)}},
		{"account.delete", keyproto.ActionAccountDelete, [][]byte{[]byte(AnchorUser.String())}},
	}
	for _, c := range cases {
		p := must[[32]byte](t)(keyproto.ParamsHash(c.action, c.fields...))
		want(t, "A11 params "+c.key, p[:])
		cc := must[[32]byte](t)(keyproto.StepUpChallenge(n, c.action, p))
		want(t, "A11 C "+c.key, cc[:])
	}
	creg := must[[32]byte](t)(keyproto.RegisterChallenge(AnchorRegisterNonce, AAKPub(AnchorAAKSeed)))
	want(t, "A12 C_reg", creg[:])

	s := a19S(t)
	addr := h([]byte(must[string](t)(keyproto.EmailNorm(AnchorNewEmailInput))))
	for _, c := range []struct {
		key    string
		action keyproto.Action
		fields [][]byte
	}{
		{"password.set", keyproto.ActionPasswordSet, [][]byte{h(s)}},
		{"password.change", keyproto.ActionPasswordChange, [][]byte{h(s)}},
		{"password.remove", keyproto.ActionPasswordRemove, nil},
		{"password.reset", keyproto.ActionPasswordReset, [][]byte{h(s)}},
		{"email.change", keyproto.ActionEmailChange, [][]byte{addr, h(s)}},
		{"email.change empty", keyproto.ActionEmailChange, [][]byte{addr, {}}},
		{"phrase.view", keyproto.ActionPhraseView, nil},
		{"account.freeze", keyproto.ActionAccountFreeze, nil},
		{"account.unfreeze", keyproto.ActionAccountUnfreeze, nil},
	} {
		p := must[[32]byte](t)(keyproto.ParamsHash(c.action, c.fields...))
		want(t, "A23 params "+c.key, p[:])
		cc := must[[32]byte](t)(keyproto.StepUpChallenge(n, c.action, p))
		want(t, "A23 C "+c.key, cc[:])
	}
}

func TestAnchorsA13ToA18Messages(t *testing.T) {
	dwk, dak := AAKPub(AnchorDWKSeed), AnchorDAKPub()
	want(t, "A13 DAK.pub", dak)
	reg := must[[]byte](t)(keyproto.RegistrationMessage(AnchorWriterNonce, AnchorWriterID, dwk, dak))
	if len(reg) != keyproto.RegistrationSize {
		t.Fatalf("RegistrationMessage is %d bytes", len(reg))
	}
	want(t, "A13 SHA256", h(reg))
	wantSig(t, "A13 AAK sig", AnchorAAKSeed, reg)

	s := a19S(t)
	norm := must[string](t)(keyproto.EmailNorm(AnchorEmailInput))
	eh := keyproto.EmailHash(norm)
	body := Body(AnchorAMK, AnchorAAKSeed)
	rwrap := SealRecoveryWrap(AnchorE, AnchorRecoverySalt, AnchorRecoveryNonce, body, AnchorUser)
	pwrap := SealPRFWrap(AnchorP, AnchorPRFSalt, AnchorPRFNonce, body, AnchorUser, AnchorCredentialID)
	box := SealPhraseBox(AnchorAMK, AnchorUser, RKPub(AnchorE), AnchorBoxNonce, AnchorE)
	pl := keyproto.BootstrapPayload{
		UserID: AnchorUser, AMKCommitment: AMKCommit(AnchorAMK, AnchorUser),
		AuthorityPubkey: AAKPub(AnchorAAKSeed), RecoveryPubkey: RKPub(AnchorE),
		RecoveryWrap: rwrap, PhraseBox: box, EmailHash: eh[:],
		AuthKind: keyproto.AuthKindPasskey, AuthHash: h(AnchorAttestation),
		WriterPubkey: dwk, WriterDAK: dak, WriterID: AnchorWriterID,
		CredentialID: AnchorCredentialID, PRFWrap: pwrap,
	}
	if err := pl.CheckKeys(); err != nil {
		t.Fatal(err)
	}
	payload := must[[]byte](t)(pl.Bytes())
	if len(payload) != 644 {
		t.Fatalf("A14 payload is %d bytes, want 644", len(payload))
	}
	want(t, "A14 SHA256(payload)", h(payload))
	bm := must[[]byte](t)(keyproto.BootstrapMessage(AnchorWriterNonce, payload))
	want(t, "A14 SHA256(BootstrapMessage)", h(bm))
	wantSig(t, "A14 AAK sig", AnchorAAKSeed, bm)

	pl.AuthKind, pl.AuthHash, pl.CredentialID, pl.PRFWrap = keyproto.AuthKindPassword, h(s), nil, nil
	payloadP := must[[]byte](t)(pl.Bytes())
	if len(payloadP) != 501 {
		t.Fatalf("A14-P payload is %d bytes, want 501", len(payloadP))
	}
	want(t, "A14-P SHA256(payload)", h(payloadP))
	bmP := must[[]byte](t)(keyproto.BootstrapMessage(AnchorWriterNonce, payloadP))
	want(t, "A14-P SHA256(BootstrapMessage)", h(bmP))
	wantSig(t, "A14-P AAK sig", AnchorAAKSeed, bmP)

	a10 := Hex(Anchors["A10 blob_hash"])
	rev := must[[]byte](t)(keyproto.RevocationMessage(AnchorStepUpNonce, AnchorWriterID, 2, a10))
	if len(rev) != keyproto.RevocationSize {
		t.Fatalf("RevocationMessage is %d bytes", len(rev))
	}
	want(t, "A15 SHA256", h(rev))
	wantSig(t, "A15 DWK sig", AnchorDWKSeed, rev)
	del := must[[]byte](t)(keyproto.DeletionMessage(AnchorStepUpNonce, AnchorUser))
	want(t, "A15 SHA256(DeletionMessage)", h(del))

	sb := must[[]byte](t)(keyproto.SessionBindMessage(AnchorLoginChallenge, AnchorWriterID))
	want(t, "A16 SHA256", h(sb))
	wantSig(t, "A16 DWK sig", AnchorDWKSeed, sb)

	rs := must[[]byte](t)(keyproto.RecoverySigninPasskey(AnchorRecoverNonce, AnchorClientDataJSON, AnchorAttestation, pwrap))
	want(t, "A17 SHA256", h(rs))
	wantSig(t, "A17 RK sig", RKSeed(AnchorE), rs)
	rsNo := must[[]byte](t)(keyproto.RecoverySigninPasskey(AnchorRecoverNonce, AnchorClientDataJSON, AnchorAttestation, nil))
	want(t, "A17 SHA256 no PRF wrap", h(rsNo))
	rsP := must[[]byte](t)(keyproto.RecoverySigninPassword(AnchorRecoverNonce, s))
	want(t, "A17 SHA256 password", h(rsP))
	wantSig(t, "A17 RK sig password", RKSeed(AnchorE), rsP)

	rkp := RKPub(AnchorRotateE)
	want(t, "A18 RK'.pub", rkp)
	newBox := SealPhraseBox(AnchorAMK, AnchorUser, rkp, AnchorBoxNonce, AnchorRotateE)
	want(t, "A18 new phrase_box", newBox)
	if len(AnchorRotateWrap) != 127 {
		t.Fatalf("A18 wrap is %d bytes", len(AnchorRotateWrap))
	}
	rot := must[[]byte](t)(keyproto.RecoveryRotateMessage(AnchorStepUpNonce, rkp, AnchorRotateWrap, newBox))
	want(t, "A18 SHA256", h(rot))
	wantSig(t, "A18 AAK sig", AnchorAAKSeed, rot)
	ph := must[[32]byte](t)(keyproto.ParamsHash(keyproto.ActionKeysRecoveryRotate, rkp))
	want(t, "A18 params recovery-rotate", ph[:])
}

func TestAnchorsA19ServerKeysAndPassword(t *testing.T) {
	norm := must[string](t)(keyproto.EmailNorm(AnchorEmailInput))
	wantStr(t, "A19 email_norm", norm)
	eh := keyproto.EmailHash(norm)
	want(t, "A19 email_hash", eh[:])
	if hex.EncodeToString([]byte(NFC(AnchorPasswordNFD))) != AnchorPasswordNFCHex {
		t.Fatalf("NFC of the anchor password is wrong")
	}

	for _, c := range []struct {
		pfx string
		key []byte
	}{{"A19 ", AnchorAuthKeyA19}, {"A19-K ", AnchorAuthKeyA19K}} {
		k := a19Keys(t, c.key)
		// The subkeys themselves, from the spec's HKDF construction.
		if c.pfx == "A19 " {
			want(t, "A19 K_salt", HKDF(AnchorSaltKey, make([]byte, 32), []byte(keyproto.DomainServerPasswordSalt)))
			wantStr(t, "A19 auth_key_id", k.AuthKeyID[1])
			want(t, "A19 s_srv", k.PasswordSalt(norm))
		} else {
			want(t, "A19-K s_srv", k.PasswordSalt(norm))
			wantStr(t, "A19-K salt_key_id", k.SaltKeyID)
			wantStr(t, "A19-K auth_key_id", k.AuthKeyID[1])
		}
		want(t, c.pfx+"K_pepper", HKDF(c.key, make([]byte, 32), []byte(keyproto.DomainServerPasswordPeppr)))
		want(t, c.pfx+"K_code", HKDF(c.key, make([]byte, 32), []byte(keyproto.DomainServerEmailCode)))
		want(t, c.pfx+"K_tag", HKDF(c.key, make([]byte, 32), []byte(keyproto.DomainServerEmailTag)))
		tag := k.EmailTag(norm)
		want(t, c.pfx+"email_tag", tag)
		s := a19S(t)
		if c.pfx == "A19 " {
			want(t, "A19 S", s)
			want(t, "A19 SHA256(S)", h(s))
		}
		want(t, c.pfx+"HMAC(K_pepper, S)", must[[]byte](t)(k.Pepper(s, 1)))
		want(t, c.pfx+"pw_hash", must[[]byte](t)(k.VerifierHash(s, AnchorPWSalt, 1)))
		want(t, c.pfx+"code_mac", must[[]byte](t)(k.CodeMAC(AnchorCodePurpose, AnchorCodeID, tag, AnchorCode)))
	}
	want(t, "A19 K_pv", KPV(AnchorAMK, AnchorUser))
	want(t, "A19 phrase_box", SealPhraseBox(AnchorAMK, AnchorUser, RKPub(AnchorE), AnchorBoxNonce, AnchorE))
}

func TestAnchorsA20ToA26Messages(t *testing.T) {
	n := AnchorStepUpNonce
	body := Body(AnchorAMK, AnchorAAKSeed)
	pwrap := SealPRFWrap(AnchorP, AnchorPRFSalt, AnchorPRFNonce, body, AnchorUser, AnchorCredentialID)
	pa := must[[]byte](t)(keyproto.PasskeyAddMessage(n, AnchorClientDataJSON, AnchorAttestation, pwrap))
	want(t, "A20 SHA256 PasskeyAdd", h(pa))
	wantSig(t, "A20 DWK sig PasskeyAdd", AnchorDWKSeed, pa)
	wp := must[[]byte](t)(keyproto.WrapPutMessage(n, AnchorCredentialID, pwrap))
	want(t, "A20 SHA256 WrapPut", h(wp))
	wantSig(t, "A20 DWK sig WrapPut", AnchorDWKSeed, wp)

	hm := must[[]byte](t)(keyproto.HeadMessage(AnchorUser, 2, Hex(Anchors["A10 blob_hash"]), AnchorWriterID))
	if len(hm) != keyproto.HeadMessageSize {
		t.Fatalf("HeadMessage is %d bytes", len(hm))
	}
	want(t, "A21 SHA256", h(hm))
	wantSig(t, "A21 DWK sig", AnchorDWKSeed, hm)

	pd := must[[32]byte](t)(keyproto.ParamsHash(keyproto.ActionPasskeyDelete, AnchorCredentialID))
	c := must[[32]byte](t)(keyproto.StepUpChallenge(n, keyproto.ActionPasskeyDelete, pd))
	ds := must[[]byte](t)(keyproto.DeviceStepUpMessage(c, AnchorWriterID))
	want(t, "A22 SHA256", h(ds))
	wantDAK(t, "A22 DAK sig", ds)

	newNorm := must[string](t)(keyproto.EmailNorm(AnchorNewEmailInput))
	ec := must[[]byte](t)(keyproto.EmailChangeMessage(n, newNorm))
	want(t, "A24 SHA256", h(ec))
	wantSig(t, "A24 RK sig", RKSeed(AnchorE), ec)

	ek := AAKPub(AnchorEKSeed)
	want(t, "A25 EK.pub", ek)
	c80, code := must2(t)(keyproto.ResetCode(ek))
	want(t, "A25 code80", c80)
	wantStr(t, "A25 code", code)
	ra := must[[]byte](t)(keyproto.ResetApproveMessage(AnchorResetNonce, AnchorUser, ek, AnchorWriterID))
	want(t, "A25 SHA256 ResetApprove", h(ra))
	wantDAK(t, "A25 DAK sig ResetApprove", ra)
	rf := must[[]byte](t)(keyproto.ResetFinishMessage(AnchorResetNonce, a19S(t)))
	want(t, "A25 SHA256 ResetFinish", h(rf))
	wantSig(t, "A25 EK sig", AnchorEKSeed, rf)

	df := must[[]byte](t)(keyproto.DeviceFreezeMessage(n, AnchorUser, AnchorWriterID))
	want(t, "A26 bytes", df)
	want(t, "A26 SHA256", h(df))
	wantDAK(t, "A26 DAK sig", df)
}

func must2(t *testing.T) func([]byte, string, error) ([]byte, string) {
	return func(b []byte, s string, err error) ([]byte, string) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return b, s
	}
}

func TestWordlistDigest(t *testing.T) {
	w := Wordlist()
	if len(w) != 2048 {
		t.Fatalf("%d words", len(w))
	}
	d := sha256.Sum256([]byte(strings.Join(w, "\n") + "\n"))
	if hex.EncodeToString(d[:]) != "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda" {
		t.Fatalf("wordlist digest %x", d)
	}
}
