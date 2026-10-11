package vectors

import (
	"crypto/ed25519"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authkeys"
	. "github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// ---------------------------------------------------------------------------
// phrase.json: spec 01 §4.3.
// ---------------------------------------------------------------------------

type phraseVector struct {
	Entropy H      `json:"entropy"`
	Words   string `json:"words"`
}

type phraseError struct {
	Kind  string `json:"kind"`
	Count *int   `json:"count,omitempty"`
	Index *int   `json:"index,omitempty"`
	Word  string `json:"word,omitempty"`
}

type phraseCase struct {
	Name       string       `json:"name"`
	Input      string       `json:"input"`
	Normalized []string     `json:"normalized"`
	Entropy    H            `json:"entropy,omitempty"`
	Error      *phraseError `json:"error,omitempty"`
}

// published are BIP-39's own 128-bit English vectors (the Trezor reference
// set); the generator checks Words reproduces each.
var published = []phraseVector{
	{Hex("00000000000000000000000000000000"), "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"},
	{Hex("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f"), "legal winner thank year wave sausage worth useful legal winner thank yellow"},
	{Hex("80808080808080808080808080808080"), "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"},
	{Hex("ffffffffffffffffffffffffffffffff"), "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong"},
	{Hex("9e885d952ad362caeb4efe34a8e91bd2"), "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"},
	{Hex("c0ba5a8e914111210f2bd131f3d5e08d"), "scheme spot photo card baby mountain device kick cradle pact join borrow"},
	{Hex("77c2b00716cec7213839159e404db50d"), "jelly better achieve collect unaware mountain thought cargo oxygen act hood bridge"},
}

func phraseCaseFor(name, input string) phraseCase {
	c := phraseCase{Name: name, Input: input, Normalized: NormalizePhrase(input)}
	if c.Normalized == nil {
		c.Normalized = []string{}
	}
	e, err := ParsePhrase(input)
	if err == nil {
		c.Entropy = e
		return c
	}
	var pe *PhraseError
	if !errors.As(err, &pe) {
		panic(err)
	}
	c.Error = &phraseError{Kind: pe.Kind}
	switch pe.Kind {
	case "length":
		n := pe.Count
		c.Error.Count = &n
	case "unknownWord":
		i := pe.Index
		c.Error.Index, c.Error.Word = &i, pe.Word
	}
	return c
}

func genPhrase(f Files, _ string) error {
	for _, p := range published {
		if got := strings.Join(Words(p.Entropy), " "); got != p.Words {
			return fmt.Errorf("phrase.json: BIP-39 vector %x gives %q, want %q", []byte(p.Entropy), got, p.Words)
		}
	}
	s := newStream("phrase.json")
	var rt []phraseVector
	for i := 0; i < 20; i++ {
		e := s.bytes(16)
		rt = append(rt, phraseVector{e, strings.Join(Words(e), " ")})
	}
	w := Words(AnchorE)
	join := func(sep string) string { return strings.Join(w, sep) }
	var cs []phraseCase
	add := func(name, input string) { cs = append(cs, phraseCaseFor(name, input)) }
	add("canonical", join(" "))
	add("uppercase", strings.ToUpper(join(" ")))
	add("mixed case", "Ozone DRILL grab Fiber curtain grace pudding thank cruise elder eight PICNIC")
	add("NBSP separators", join("\u00a0"))
	add("U+202F separators", join("\u202f"))
	add("full-width letters", "ｏｚｏｎｅ ｄｒｉｌｌ "+strings.Join(w[2:], " "))
	add("ligature fi (U+FB01) folds by NFKD", strings.Replace(join(" "), "fiber", "ﬁber", 1))
	add("tabs and newlines", strings.Join(w[:6], "\t")+"\n"+strings.Join(w[6:], "\r\n"))
	add("U+FEFF before and between", "\ufeff"+join(" \ufeff"))
	add("leading and trailing whitespace", "  \t"+join(" ")+" \n ")
	add("runs of spaces", join("   "))
	add("U+3000 ideographic space", join("\u3000"))
	add("U+2028 and U+2029", strings.Join(w[:6], "\u2028")+"\u2029"+strings.Join(w[6:], "\u2028"))
	add("U+1680 ogham space", join("\u1680"))
	add("U+2003 em space", join("\u2003"))
	add("U+205F medium mathematical space", join("\u205f"))
	add("vertical tab and form feed", strings.Join(w[:6], "\v")+"\f"+strings.Join(w[6:], "\v"))
	add("U+2000 and U+200A", strings.Join(w[:6], "\u2000")+"\u200a"+strings.Join(w[6:], "\u2000"))
	add("combining accent (e + U+0301) is not a word", strings.Replace(join(" "), "ozone", "ozone\u0301", 1))
	add("precomposed é decomposes and is not a word", strings.Replace(join(" "), "elder", "eldér", 1))
	add("U+200B zero-width space is not whitespace", join("\u200b"))
	add("zero-width space inside a word", strings.Replace(join(" "), "thank", "th\u200bank", 1))
	add("trailing period", join(" ")+".")
	add("empty", "")
	add("whitespace only", " \t\u00a0\n")
	add("11 words", strings.Join(w[:11], " "))
	add("13 words", join(" ")+" zoo")
	add("prefix of a word is not the word", strings.Replace(join(" "), "curtain", "curt", 1))
	for i := 0; i < 12; i++ {
		x := append([]string(nil), w...)
		x[i] = "hasala"
		add(fmt.Sprintf("unknown word at index %d", i), strings.Join(x, " "))
	}
	nCk := 0
	for _, cand := range Wordlist() {
		if nCk == 12 {
			break
		}
		x := append([]string(nil), w...)
		x[11] = cand
		c := phraseCaseFor("checksum failure: last word "+cand, strings.Join(x, " "))
		if c.Error != nil && c.Error.Kind == "checksum" {
			cs = append(cs, c)
			nCk++
		}
	}
	return f.json(CryptoDir+"/phrase.json", struct {
		Note          string         `json:"note"`
		WordlistSHA   string         `json:"wordlist_sha256"`
		Published     []phraseVector `json:"published"`
		RoundTrip     []phraseVector `json:"round_trip"`
		Normalization []phraseCase   `json:"cases"`
	}{
		Note: "spec 01 §4.3: checksum = SHA256(E)[0] >> 4; twelve 11-bit indices, MSB first. Typed input: NFKD, lowercase, " +
			"every run of W to one U+0020, trim, split; then count (length), exact word match (unknownWord with the 0-based index " +
			"and the normalized word), checksum. normalized is the word list after normalization, before validation.",
		WordlistSHA: "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda",
		Published:   published, RoundTrip: rt, Normalization: cs,
	})
}

// ---------------------------------------------------------------------------
// password.json: spec 01 §4.10, §4.11 (A19, A19-K).
// ---------------------------------------------------------------------------

type emailCase struct {
	Input string `json:"input"`
	Norm  string `json:"email_norm,omitempty"`
	Error string `json:"error,omitempty"`
}

type serverKeys struct {
	Name      string `json:"name"`
	SaltKey   H      `json:"salt_key"`
	AuthKey   H      `json:"auth_key_generation_1"`
	KSalt     H      `json:"k_salt"`
	KPepper   H      `json:"k_pepper_1"`
	KCode     H      `json:"k_code"`
	KTag      H      `json:"k_tag"`
	SaltKeyID string `json:"salt_key_id"`
	AuthKeyID string `json:"auth_key_id"`
}

type stretchCase struct {
	Name       string `json:"name"`
	Password   string `json:"password"`
	Scalars    int    `json:"scalars_after_nfc"`
	EmailNorm  string `json:"email_norm"`
	SSrv       H      `json:"s_srv"`
	SaltC      H      `json:"salt_c"`
	Iterations int    `json:"iterations"`
	S          H      `json:"s"`
	SHA256S    H      `json:"sha256_s"`
}

type verifierCase struct {
	Keys       string `json:"keys"`
	S          H      `json:"s"`
	PWSalt     H      `json:"pw_salt"`
	Generation int    `json:"generation"`
	Pepper     H      `json:"hmac_k_pepper_s"`
	PWHash     H      `json:"pw_hash"`
}

type nameCase struct {
	Name string `json:"name"`
	OK   bool   `json:"name_ok"`
	Why  string `json:"why"`
}

func keysFor(t string, auth []byte) (*authkeys.Keys, serverKeys) {
	k, err := authkeys.New(AnchorSaltKey, map[int][]byte{1: auth}, 1)
	if err != nil {
		panic(err)
	}
	z := make([]byte, 32)
	return k, serverKeys{
		Name: t, SaltKey: AnchorSaltKey, AuthKey: auth,
		KSalt:     HKDF(AnchorSaltKey, z, []byte(keyproto.DomainServerPasswordSalt)),
		KPepper:   HKDF(auth, z, []byte(keyproto.DomainServerPasswordPeppr)),
		KCode:     HKDF(auth, z, []byte(keyproto.DomainServerEmailCode)),
		KTag:      HKDF(auth, z, []byte(keyproto.DomainServerEmailTag)),
		SaltKeyID: k.SaltKeyID, AuthKeyID: k.AuthKeyID[1],
	}
}

func genPassword(f Files, _ string) error {
	valid := []string{
		"  Maya.Rahman+Hasala@Gmail.COM ", "maya@example.ae", "MAYA@EXAMPLE.AE", "\tmaya@example.ae\t",
		" \t maya@example.ae \t ", "a@b.co", "A@B.CO", "first.last@sub.domain.example", "x+y+z@example.com",
		"under_score@example.com", "dash-ed@ex-ample.com", "o'brien@example.ie", "digits123@456.example",
		"UPPER.lower@MiXeD.Example.ORG", "a.b.c.d@e.f", "user%tag@example.com", "!#$&*=?^`{|}~@example.com",
		"maya@xn--mgbh0fb.example", strings.Repeat("l", 64) + "@example.com", "m@" + strings.Repeat("d", 60) + ".example",
		"Maya.Rahman+Hasala@Gmail.COM", strings.Repeat("l", 64) + "@" + strings.Repeat("d", 185) + ".com", // 254 bytes
	}
	invalid := []string{
		"maya@exämple.com", "mäya@example.com", "maya@@example.com", "maya@ex@ample.com", "maya@example",
		"maya@.example.com", "maya@example.com.", "maya rahman@example.com", "@example.com", "maya@",
		strings.Repeat("l", 65) + "@example.com", strings.Repeat("l", 64) + "@" + strings.Repeat("d", 186) + ".com",
		"", "a@", "maya\x00@example.com", "maya@example.com\r",
	}
	var emails []emailCase
	for _, in := range valid {
		n, err := keyproto.EmailNorm(in)
		if err != nil {
			return fmt.Errorf("password.json: %q should normalize: %v", in, err)
		}
		emails = append(emails, emailCase{Input: in, Norm: n})
	}
	for _, in := range invalid {
		if _, err := keyproto.EmailNorm(in); err == nil {
			return fmt.Errorf("password.json: %q should be refused", in)
		}
		emails = append(emails, emailCase{Input: in, Error: "bad_email"})
	}

	k19, sk19 := keysFor("A19 (auth_key = salt_key = 11..30)", AnchorAuthKeyA19)
	k19k, sk19k := keysFor("A19-K (salt_key 11..30, auth_key 31..50)", AnchorAuthKeyA19K)
	norm, _ := keyproto.EmailNorm(AnchorEmailInput)
	sSrv := k19.PasswordSalt(norm)
	if !bytesEq(sSrv, k19k.PasswordSalt(norm)) {
		return errors.New("password.json: s_srv depends on auth_key")
	}
	pw12 := "abcdefghijk" + "é"                   // 12 scalars after NFC
	pw128 := strings.Repeat("Hasala ", 18) + "ab" // 128 scalars
	var stretches []stretchCase
	for _, p := range []struct{ name, pw string }{
		{"ASCII", "correct horse battery staple"},
		{"A19 (NFD input)", AnchorPasswordNFD},
		{"A19's NFC twin gives the same S", NFC(AnchorPasswordNFD)},
		{"12 scalars, the policy minimum", pw12},
		{"128 scalars, the policy maximum", pw128},
	} {
		sc := utf8.RuneCountInString(NFC(p.pw))
		s := Stretch(p.pw, sSrv, norm)
		stretches = append(stretches, stretchCase{p.name, p.pw, sc, norm, sSrv, PasswordSaltC(sSrv, norm),
			StretchIterations, s, sum(s)})
	}
	if !bytesEq(stretches[1].S, stretches[2].S) {
		return errors.New("password.json: NFD and NFC inputs stretch differently")
	}
	if stretches[3].Scalars != 12 || stretches[4].Scalars != 128 {
		return errors.New("password.json: the policy-bound passwords have the wrong length")
	}
	s := stretches[1].S
	var verifiers []verifierCase
	for _, v := range []struct {
		name string
		k    *authkeys.Keys
	}{{"A19", k19}, {"A19-K", k19k}} {
		p, _ := v.k.Pepper(s, 1)
		h, _ := v.k.VerifierHash(s, AnchorPWSalt, 1)
		verifiers = append(verifiers, verifierCase{v.name, s, AnchorPWSalt, 1, p, h})
	}
	names := []nameCase{
		{"Maya Rahman", true, "ASCII"}, {"مايا رحمن", true, "Arabic"}, {strings.Repeat("م", 64), true, "64 scalars"},
		{"O’Neil-Ahmed", true, "punctuation is graphic"}, {"J. Smith", true, "period"},
		{"", false, "empty"}, {strings.Repeat("a", 65), false, "65 scalars"}, {" Maya", false, "leading space"},
		{"Maya ", false, "trailing space"}, {"Maya  Rahman", false, "doubled space"}, {"Maya\u202eRahman", false, "U+202E (Cf)"},
		{"Maya\u200bRahman", false, "U+200B (Cf)"}, {"Maya\u00a0Rahman", false, "U+00A0 (Zs)"}, {"Maya\tRahman", false, "tab (Cc)"},
		{"Maya\u3000Rahman", false, "U+3000 (Zs)"},
	}
	for _, n := range names {
		if keyproto.NameOK(n.Name) != n.OK {
			return fmt.Errorf("password.json: name_ok(%q) disagrees with the table", n.Name)
		}
	}
	return f.json(CryptoDir+"/password.json", struct {
		Note      string         `json:"note"`
		Emails    []emailCase    `json:"email_norm"`
		Keys      []serverKeys   `json:"server_keys"`
		Address   string         `json:"anchor_email_norm"`
		EmailHash H              `json:"anchor_email_hash"`
		SSrv      H              `json:"anchor_s_srv"`
		Stretch   []stretchCase  `json:"stretch"`
		Verifiers []verifierCase `json:"verifiers"`
		NameOK    []nameCase     `json:"name_ok"`
	}{
		Note: "spec 01 §4.10–§4.11. Server keys: K_salt = HKDF(salt_key, 0^32, D27); K_pepper_g, K_code, K_tag = HKDF(auth_key, 0^32, " +
			"D28/D29/D30); key_id = hex(HMAC(k, D41)[0:8]). s_srv = HMAC(K_salt, email_norm) depends on salt_key only (A19-K). " +
			"S = PBKDF2-HMAC-SHA256(utf8(NFC(password)), \"hasala/v1/password\" ‖ 00 ‖ s_srv ‖ email_norm, 600000, 32). " +
			"pw_hash = PBKDF2(HMAC(K_pepper_g, S), pw_salt, 100000, 32). name_ok is the §4.11 floor.",
		Emails: emails, Keys: []serverKeys{sk19, sk19k}, Address: norm, EmailHash: sumStr(norm), SSrv: sSrv,
		Stretch: stretches, Verifiers: verifiers, NameOK: names,
	})
}

func sumStr(s string) H { return sum([]byte(s)) }

func bytesEq(a, b []byte) bool { return string(a) == string(b) }

// ---------------------------------------------------------------------------
// codes.json: spec 01 §10.14.
// ---------------------------------------------------------------------------

type codeCase struct {
	Keys     string    `json:"keys"`
	Purpose  string    `json:"purpose"`
	CodeID   uuid.UUID `json:"code_id"`
	Email    string    `json:"email_norm"`
	EmailTag H         `json:"email_tag"`
	Code     string    `json:"code"`
	CodeMAC  H         `json:"code_mac"`
}

type codeMismatch struct {
	Name     string    `json:"name"`
	Stored   H         `json:"stored_code_mac"`
	Keys     string    `json:"keys"`
	Purpose  string    `json:"purpose"`
	CodeID   uuid.UUID `json:"code_id"`
	EmailTag H         `json:"email_tag"`
	Code     string    `json:"code"`
	Verifies bool      `json:"verifies"`
}

func genCodes(f Files, _ string) error {
	k19, _ := keysFor("A19", AnchorAuthKeyA19)
	k19k, _ := keysFor("A19-K", AnchorAuthKeyA19K)
	keys := map[string]*authkeys.Keys{"A19": k19, "A19-K": k19k}
	norm, _ := keyproto.EmailNorm(AnchorEmailInput)
	var cases []codeCase
	for _, kn := range []string{"A19", "A19-K"} {
		k := keys[kn]
		for _, p := range authkeys.CodePurposes() {
			tag := k.EmailTag(norm)
			m, err := k.CodeMAC(p, AnchorCodeID, tag, AnchorCode)
			if err != nil {
				return err
			}
			cases = append(cases, codeCase{kn, p, AnchorCodeID, norm, tag, AnchorCode, m})
		}
	}
	base, _ := k19.CodeMAC(AnchorCodePurpose, AnchorCodeID, k19.EmailTag(norm), AnchorCode)
	other := uuid.MustParse("1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")
	newNorm, _ := keyproto.EmailNorm(AnchorNewEmailInput)
	mis := []codeMismatch{
		{"the A19 code itself", base, "A19", AnchorCodePurpose, AnchorCodeID, k19.EmailTag(norm), AnchorCode, true},
		{"another purpose", base, "A19", "recovery", AnchorCodeID, k19.EmailTag(norm), AnchorCode, false},
		{"another code id", base, "A19", AnchorCodePurpose, other, k19.EmailTag(norm), AnchorCode, false},
		{"another address", base, "A19", AnchorCodePurpose, AnchorCodeID, k19.EmailTag(newNorm), AnchorCode, false},
		{"another key generation (A19-K)", base, "A19-K", AnchorCodePurpose, AnchorCodeID, k19k.EmailTag(norm), AnchorCode, false},
		{"other digits", base, "A19", AnchorCodePurpose, AnchorCodeID, k19.EmailTag(norm), "042818", false},
	}
	for _, m := range mis {
		if keys[m.Keys].CodeMatches(m.Stored, m.Purpose, m.CodeID, m.EmailTag, m.Code) != m.Verifies {
			return fmt.Errorf("codes.json: %s", m.Name)
		}
	}
	return f.json(CryptoDir+"/codes.json", struct {
		Note       string         `json:"note"`
		Purposes   []string       `json:"purposes"`
		Cases      []codeCase     `json:"cases"`
		Mismatches []codeMismatch `json:"verification"`
	}{
		Note: "spec 01 §10.14: email_tag = HMAC(K_tag, email_norm); code_mac = HMAC(K_code, purpose ‖ 00 ‖ uuid_raw(code_id) ‖ " +
			"email_tag ‖ code). Keys are password.json's server_keys (A19, A19-K).",
		Purposes: authkeys.CodePurposes(), Cases: cases, Mismatches: mis,
	})
}

// ---------------------------------------------------------------------------
// approval.json: spec 01 §10.16 (C9), A25.
// ---------------------------------------------------------------------------

type approvalCase struct {
	Name       string    `json:"name"`
	EKSeed     H         `json:"ek_seed"`
	EKPub      H         `json:"ek_pub"`
	Code80     H         `json:"code80"`
	Code       string    `json:"code"`
	ResetNonce H         `json:"reset_nonce"`
	UserID     uuid.UUID `json:"user_id"`
	WriterID   string    `json:"approver_writer_id"`
	SNew       H         `json:"s_new"`
	ApproveMsg H         `json:"reset_approve_message"`
	DAKPub     H         `json:"dak_pubkey,omitempty"`
	DAKSig     H         `json:"dak_sig_sample,omitempty"`
	FinishMsg  H         `json:"reset_finish_message"`
	EKSig      H         `json:"ek_sig"`
}

func genApproval(f Files, _ string) error {
	k19, _ := keysFor("A19", AnchorAuthKeyA19)
	norm, _ := keyproto.EmailNorm(AnchorEmailInput)
	sNew := Stretch(AnchorPasswordNFD, k19.PasswordSalt(norm), norm)
	s := newStream("approval.json")
	seeds := [][]byte{AnchorEKSeed, s.bytes(32), s.bytes(32), s.bytes(32)}
	var cases []approvalCase
	for i, seed := range seeds {
		ek := ed25519.NewKeyFromSeed(seed)
		pub := ek.Public().(ed25519.PublicKey)
		c80, code, err := keyproto.ResetCode(pub)
		if err != nil {
			return err
		}
		ra, err := keyproto.ResetApproveMessage(AnchorResetNonce, AnchorUser, pub, AnchorWriterID)
		if err != nil {
			return err
		}
		rf, err := keyproto.ResetFinishMessage(AnchorResetNonce, sNew)
		if err != nil {
			return err
		}
		c := approvalCase{Name: fmt.Sprintf("stream EK %d", i), EKSeed: seed, EKPub: H(pub), Code80: c80, Code: code,
			ResetNonce: AnchorResetNonce, UserID: AnchorUser, WriterID: AnchorWriterID, SNew: sNew,
			ApproveMsg: ra, FinishMsg: rf, EKSig: ed25519.Sign(ek, rf)}
		if i == 0 {
			c.Name = "A25"
			c.DAKPub, c.DAKSig = AnchorDAKPub(), Hex(Anchors["A25 DAK sig ResetApprove"])
			if !keyproto.VerifyDAKBytes(c.DAKPub, ra, c.DAKSig) {
				return errors.New("approval.json: A25's DAK sample does not verify")
			}
		}
		cases = append(cases, c)
	}
	return f.json(CryptoDir+"/approval.json", struct {
		Note  string         `json:"note"`
		Cases []approvalCase `json:"cases"`
	}{
		Note: "spec 01 §10.16 (C9): code80 = SHA256(\"hasala/v1/reset-code\" ‖ 00 ‖ ek_pub)[0:10], shown as base32 (RFC 4648, " +
			"uppercase, no padding, 16 characters). ResetApprove is signed by the approver's DAK (P-256, verify-only: the A25 sample); " +
			"ResetFinish by the ephemeral key (Ed25519, deterministic in Go).",
		Cases: cases,
	})
}
