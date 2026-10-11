package vectors

import (
	"bytes"
	"fmt"

	"github.com/google/uuid"

	. "github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func registry() []keyproto.Domain { return keyproto.Registry() }

// ---------------------------------------------------------------------------
// derive.json: spec 01 §4 derivations, reproducing A01–A08.
// ---------------------------------------------------------------------------

type deriveSet struct {
	Name          string    `json:"name"`
	UserID        uuid.UUID `json:"user_id"`
	E             H         `json:"e"`
	AMK           H         `json:"amk"`
	AAKSeed       H         `json:"aak_seed"`
	DWKSeed       H         `json:"dwk_seed"`
	P             H         `json:"p"`
	RecoverySalt  H         `json:"recovery_wrap_salt"`
	PRFSalt       H         `json:"prf_wrap_salt"`
	RKSeed        H         `json:"rk_seed"`
	RKPub         H         `json:"rk_pub"`
	RWK           H         `json:"rwk"`
	PWK           H         `json:"pwk"`
	AMKCommitment H         `json:"amk_commitment"`
	K1            H         `json:"k_1"`
	KPV           H         `json:"k_pv"`
	AAKPub        H         `json:"aak_pub"`
	DWKPub        H         `json:"dwk_pub"`
}

type blobKeyCase struct {
	KE        H      `json:"k_e"`
	Nonce     H      `json:"nonce"`
	AD        H      `json:"ad"`
	SHA256AD  H      `json:"sha256_ad"`
	KBlob     H      `json:"k_blob"`
	Construct string `json:"construction"`
}

func deriveFor(name string, user uuid.UUID, e, amk, aak, dwk, p, rs, ps []byte) deriveSet {
	return deriveSet{
		Name: name, UserID: user, E: e, AMK: amk, AAKSeed: aak, DWKSeed: dwk, P: p,
		RecoverySalt: rs, PRFSalt: ps,
		RKSeed: RKSeed(e), RKPub: RKPub(e), RWK: RWK(e, rs), PWK: PWK(p, ps),
		AMKCommitment: AMKCommit(amk, user), K1: EpochKey1(amk, user), KPV: KPV(amk, user),
		AAKPub: AAKPub(aak), DWKPub: AAKPub(dwk),
	}
}

func genDerive(f Files, _ string) error {
	s := newStream("derive.json")
	sets := []deriveSet{deriveFor("anchors A03–A08 (spec 01 §15.5)", AnchorUser, AnchorE, AnchorAMK,
		AnchorAAKSeed, AnchorDWKSeed, AnchorP, AnchorRecoverySalt, AnchorPRFSalt)}
	for i := 1; i <= 3; i++ {
		u, _ := uuid.FromBytes(s.bytes(16))
		u[6] = u[6]&0x0f | 0x40
		u[8] = u[8]&0x3f | 0x80
		sets = append(sets, deriveFor(fmt.Sprintf("stream set %d", i), u, s.bytes(16), s.bytes(32),
			s.bytes(32), s.bytes(32), s.bytes(32), s.bytes(32), s.bytes(32)))
	}
	// K_blob for 3 nonces × 2 ADs (spec 01 §15.1).
	k1 := EpochKey1(AnchorAMK, AnchorUser)
	var bks []blobKeyCase
	for _, ad := range [][]byte{[]byte("hasala/v1/blob\x00ad-one"), s.bytes(150)} {
		for _, n := range [][]byte{AnchorFrameNonce1, AnchorFrameNonce2, s.bytes(12)} {
			info := append([]byte(keyproto.DomainBlobKey+"\x00"), sum(ad)...)
			bks = append(bks, blobKeyCase{KE: k1, Nonce: n, AD: ad, SHA256AD: sum(ad),
				KBlob: HKDF(k1, n, info), Construct: "HKDF(k_e, salt = nonce, info = \"hasala/v1/blob-key\" ‖ 00 ‖ SHA256(ad))"})
		}
	}
	salt := PRFSalt()
	return f.json(CryptoDir+"/derive.json", struct {
		Note     string        `json:"note"`
		PRFSalt  H             `json:"prf_salt_unlock"`
		Phrase   string        `json:"phrase_of_anchor_e"`
		Sets     []deriveSet   `json:"sets"`
		BlobKeys []blobKeyCase `json:"blob_keys"`
	}{
		Note: "spec 01 §4: RK_seed = HKDF(E, 0^32, D04); RWK = HKDF(E, salt, D05); PWK = HKDF(P, salt, D06); " +
			"amk_commitment = HMAC(AMK, D09 ‖ 00 ‖ uuid_raw); K_1 = HKDF(AMK, uuid_raw, D10 ‖ 00 ‖ u32be(1)); " +
			"K_pv = HKDF(AMK, uuid_raw, D35). The first set is the anchor set (A01–A08, A19's K_pv).",
		PRFSalt: salt[:], Phrase: joinWords(Words(AnchorE)), Sets: sets, BlobKeys: bks,
	})
}

func joinWords(w []string) string {
	var b bytes.Buffer
	for i, x := range w {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(x)
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// wraps.json: spec 01 §5.2, §5.3 and W01–W10.
// ---------------------------------------------------------------------------

type wrapVector struct {
	Name         string    `json:"name"`
	Kind         string    `json:"kind"` // recovery | prf
	UserID       uuid.UUID `json:"user_id"`
	Secret       H         `json:"secret"` // E (recovery) or P (prf)
	Salt         H         `json:"salt"`
	Nonce        H         `json:"nonce"`
	Body         H         `json:"body"`
	CredentialID H         `json:"credential_id"`
	Wrap         H         `json:"wrap"`
}

type wrapCase struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Kind         string    `json:"kind"`
	UserID       uuid.UUID `json:"user_id"`
	Secret       H         `json:"secret"`
	CredentialID H         `json:"credential_id"`
	Wrap         H         `json:"wrap"`
	// The account's published values the unwrap checks against.
	AMKCommitment   H      `json:"amk_commitment"`
	AuthorityPubkey H      `json:"authority_pubkey"`
	RecoveryPubkey  H      `json:"recovery_pubkey"`
	Outcome         string `json:"outcome"` // opens | unwrapFailed | notThisAccountsPhrase | integrityAlarm(accountKeysMismatch)
	AMK             H      `json:"amk,omitempty"`
	AAKSeed         H      `json:"aak_seed,omitempty"`
}

func outcomeName(err error) string {
	if err == nil {
		return "opens"
	}
	return err.Error()
}

func flip(b []byte, i int) []byte {
	c := append([]byte(nil), b...)
	c[i] ^= 0x01
	return c
}

func genWraps(f Files, _ string) error {
	body := Body(AnchorAMK, AnchorAAKSeed)
	acct := AccountKeys{User: AnchorUser, AMKCommitment: AMKCommit(AnchorAMK, AnchorUser),
		AuthorityPubkey: AAKPub(AnchorAAKSeed), RecoveryPubkey: RKPub(AnchorE)}
	rw := SealRecoveryWrap(AnchorE, AnchorRecoverySalt, AnchorRecoveryNonce, body, AnchorUser)
	pw := SealPRFWrap(AnchorP, AnchorPRFSalt, AnchorPRFNonce, body, AnchorUser, AnchorCredentialID)
	s := newStream("wraps.json")
	otherBody := Body(s.bytes(32), s.bytes(32))
	vecs := []wrapVector{
		{"A07 recovery wrap", "recovery", AnchorUser, AnchorE, AnchorRecoverySalt, AnchorRecoveryNonce, body, nil, rw},
		{"A08 PRF wrap", "prf", AnchorUser, AnchorP, AnchorPRFSalt, AnchorPRFNonce, body, AnchorCredentialID, pw},
	}
	{
		e, salt, nonce := s.bytes(16), s.bytes(32), s.bytes(12)
		u := uuid.MustParse("3b0e5c1a-7d2f-4e8a-9b6c-1f2e3d4c5b6a")
		vecs = append(vecs, wrapVector{"stream recovery wrap", "recovery", u, e, salt, nonce, otherBody, nil,
			SealRecoveryWrap(e, salt, nonce, otherBody, u)})
		p, salt2, nonce2, cred := s.bytes(32), s.bytes(32), s.bytes(12), s.bytes(64)
		vecs = append(vecs, wrapVector{"stream PRF wrap, 64-byte credential", "prf", u, p, salt2, nonce2, otherBody, cred,
			SealPRFWrap(p, salt2, nonce2, otherBody, u, cred)})
	}

	var cases []wrapCase
	add := func(id, name, kind string, secret, cred, wrap []byte, a AccountKeys, user uuid.UUID) {
		c := wrapCase{ID: id, Name: name, Kind: kind, UserID: user, Secret: secret, CredentialID: cred, Wrap: wrap,
			AMKCommitment: a.AMKCommitment, AuthorityPubkey: a.AuthorityPubkey, RecoveryPubkey: a.RecoveryPubkey}
		a.User = user
		var u Unwrapped
		var err error
		if kind == "recovery" {
			u, err = OpenRecoveryWrap(secret, wrap, a)
		} else {
			u, err = OpenPRFWrap(secret, wrap, a, cred)
		}
		c.Outcome = outcomeName(err)
		if err == nil {
			c.AMK, c.AAKSeed = u.AMK, u.AAKSeed
		}
		cases = append(cases, c)
	}
	add("W01", "valid recovery wrap + E", "recovery", AnchorE, nil, rw, acct, AnchorUser)
	add("W01", "valid PRF wrap + P", "prf", AnchorP, AnchorCredentialID, pw, acct, AnchorUser)
	for i := 0; i < 46; i++ {
		add("W02", fmt.Sprintf("recovery wrap header byte %d XOR 01", i), "recovery", AnchorE, nil, flip(rw, i), acct, AnchorUser)
	}
	for i := 0; i < 46; i++ {
		add("W02", fmt.Sprintf("PRF wrap header byte %d XOR 01", i), "prf", AnchorP, AnchorCredentialID, flip(pw, i), acct, AnchorUser)
	}
	for _, i := range []int{46, 46 + 32, 46 + 64} {
		add("W03", fmt.Sprintf("ciphertext byte %d XOR 01", i), "recovery", AnchorE, nil, flip(rw, i), acct, AnchorUser)
	}
	for i := 111; i < 127; i++ {
		add("W03", fmt.Sprintf("tag byte %d XOR 01", i), "recovery", AnchorE, nil, flip(rw, i), acct, AnchorUser)
	}
	other := uuid.MustParse("3b0e5c1a-7d2f-4e8a-9b6c-1f2e3d4c5b6a")
	acctOther := acct
	acctOther.AMKCommitment = AMKCommit(AnchorAMK, other)
	add("W04", "recovery wrap opened with another user_id in the AD", "recovery", AnchorE, nil, rw, acctOther, other)
	add("W04", "PRF wrap opened with another user_id in the AD", "prf", AnchorP, AnchorCredentialID, pw, acctOther, other)
	add("W05", "PRF wrap opened under another credential_id", "prf", AnchorP, Range(0x02, 0x11), pw, acct, AnchorUser)
	add("W06", "a different valid phrase", "recovery", AnchorRotateE, nil, rw, acct, AnchorUser)
	add("W07", "wrong P", "prf", Range(0xc1, 0xe0), AnchorCredentialID, pw, acct, AnchorUser)
	add("W08", "126 bytes", "recovery", AnchorE, nil, rw[:126], acct, AnchorUser)
	add("W08", "128 bytes", "recovery", AnchorE, nil, append(append([]byte(nil), rw...), 0), acct, AnchorUser)
	{
		// kdf 0x02 in a recovery wrap: built honestly under RWK with kdf 0x02 in its header.
		w := append([]byte(nil), rw...)
		w[1] = keyproto.KDFPRF
		add("W08", "kdf 0x02 in a recovery wrap", "recovery", AnchorE, nil, w, acct, AnchorUser)
	}
	{
		b2 := append([]byte{0x02}, body[1:]...)
		w := SealRecoveryWrap(AnchorE, AnchorRecoverySalt, AnchorRecoveryNonce, b2, AnchorUser)
		add("W08", "body version 0x02 (authenticated)", "recovery", AnchorE, nil, w, acct, AnchorUser)
	}
	{
		w := SealRecoveryWrap(AnchorE, AnchorRecoverySalt, AnchorRecoveryNonce, Body(Range(0x41, 0x60), AnchorAAKSeed), AnchorUser)
		add("W09", "wrap opens, the AMK differs from the committed one", "recovery", AnchorE, nil, w, acct, AnchorUser)
		w2 := SealRecoveryWrap(AnchorE, AnchorRecoverySalt, AnchorRecoveryNonce, Body(AnchorAMK, Range(0x61, 0x80)), AnchorUser)
		add("W10", "wrap opens, the AAK seed differs from authority_pubkey", "recovery", AnchorE, nil, w2, acct, AnchorUser)
	}
	want := map[string]string{
		"W01": "opens", "W02": "unwrapFailed", "W03": "unwrapFailed", "W04": "unwrapFailed",
		"W05": "unwrapFailed", "W06": "notThisAccountsPhrase", "W07": "unwrapFailed", "W08": "unwrapFailed",
		"W09": "integrityAlarm(accountKeysMismatch)", "W10": "integrityAlarm(accountKeysMismatch)",
	}
	for _, c := range cases {
		if c.Outcome != want[c.ID] {
			return fmt.Errorf("wraps.json %s %q: the reference opener says %s, spec 01 §15.3 says %s", c.ID, c.Name, c.Outcome, want[c.ID])
		}
	}
	return f.json(CryptoDir+"/wraps.json", struct {
		Note  string       `json:"note"`
		Wraps []wrapVector `json:"wraps"`
		Cases []wrapCase   `json:"cases"`
	}{
		Note: "spec 01 §5: wrap = 01 ‖ kdf ‖ salt32 ‖ nonce12 ‖ ct65 ‖ tag16 (127 bytes); AD = \"hasala/v1/wrap\" ‖ 00 ‖ wrap[0:46] ‖ uuid_raw(user_id) " +
			"[‖ credential_id]. Cases W01–W10 (spec 01 §15.3) name the client outcome of §5.4; a recovery case runs the RK.pub check first.",
		Wraps: vecs, Cases: cases,
	})
}

// ---------------------------------------------------------------------------
// phrase-box.json: spec 01 §5.5, A18 and A19, W11–W13.
// ---------------------------------------------------------------------------

type boxVector struct {
	Name           string    `json:"name"`
	UserID         uuid.UUID `json:"user_id"`
	AMK            H         `json:"amk"`
	RecoveryPubkey H         `json:"recovery_pubkey"`
	Nonce          H         `json:"nonce"`
	E              H         `json:"e"`
	KPV            H         `json:"k_pv"`
	Box            H         `json:"box"`
}

type boxCase struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	UserID         uuid.UUID `json:"user_id"`
	AMK            H         `json:"amk"`
	RecoveryPubkey H         `json:"recovery_pubkey"`
	Box            H         `json:"box"`
	Outcome        string    `json:"outcome"`
	E              H         `json:"e,omitempty"`
}

func genPhraseBox(f Files, _ string) error {
	rk := RKPub(AnchorE)
	box := SealPhraseBox(AnchorAMK, AnchorUser, rk, AnchorBoxNonce, AnchorE)
	rk2 := RKPub(AnchorRotateE)
	box2 := SealPhraseBox(AnchorAMK, AnchorUser, rk2, AnchorBoxNonce, AnchorRotateE)
	vecs := []boxVector{
		{"A19 phrase box", AnchorUser, AnchorAMK, rk, AnchorBoxNonce, AnchorE, KPV(AnchorAMK, AnchorUser), box},
		{"A18 new phrase box (E' = 80×16)", AnchorUser, AnchorAMK, rk2, AnchorBoxNonce, AnchorRotateE, KPV(AnchorAMK, AnchorUser), box2},
	}
	var cases []boxCase
	add := func(id, name string, user uuid.UUID, rp, b []byte) {
		e, err := OpenPhraseBox(AnchorAMK, user, rp, b)
		c := boxCase{ID: id, Name: name, UserID: user, AMK: AnchorAMK, RecoveryPubkey: rp, Box: b, Outcome: outcomeName(err)}
		if err == nil {
			c.E = e
		}
		cases = append(cases, c)
	}
	add("W11", "valid box opens", AnchorUser, rk, box)
	for i := 0; i < 13; i++ {
		add("W11", fmt.Sprintf("header byte %d XOR 01", i), AnchorUser, rk, flip(box, i))
	}
	for i := 29; i < 45; i++ {
		add("W11", fmt.Sprintf("tag byte %d XOR 01", i), AnchorUser, rk, flip(box, i))
	}
	add("W11", "44 bytes", AnchorUser, rk, box[:44])
	add("W11", "46 bytes", AnchorUser, rk, append(append([]byte(nil), box...), 0))
	add("W12", "another user_id in the AD", uuid.MustParse("3b0e5c1a-7d2f-4e8a-9b6c-1f2e3d4c5b6a"), rk, box)
	add("W12", "another recovery_pubkey in the AD", AnchorUser, rk2, box)
	// W13: a box built for another phrase with a matching AD (recovery_pubkey of E, content E').
	forged := SealPhraseBox(AnchorAMK, AnchorUser, rk, AnchorBoxNonce, AnchorRotateE)
	add("W13", "opens, but RK of its E is not recovery_pubkey", AnchorUser, rk, forged)
	for _, c := range cases {
		w := map[string]string{"W12": "unwrapFailed", "W13": "integrityAlarm(phraseBoxMismatch)"}[c.ID]
		if c.ID == "W11" {
			w = "unwrapFailed"
			if c.Name == "valid box opens" {
				w = "opens"
			}
		}
		if c.Outcome != w {
			return fmt.Errorf("phrase-box.json %s %q: %s, want %s", c.ID, c.Name, c.Outcome, w)
		}
	}
	return f.json(CryptoDir+"/phrase-box.json", struct {
		Note  string      `json:"note"`
		Boxes []boxVector `json:"boxes"`
		Cases []boxCase   `json:"cases"`
	}{
		Note: "spec 01 §5.5: K_pv = HKDF(AMK, uuid_raw, D35); box = 01 ‖ nonce12 ‖ AEAD(K_pv, nonce, E, AD) (45 bytes); " +
			"AD = \"hasala/v1/phrase-box\" ‖ 00 ‖ uuid_raw ‖ recovery_pubkey ‖ box[0:1]. Open order: version, AEAD, then RK(E).pub = recovery_pubkey.",
		Boxes: vecs, Cases: cases,
	})
}
