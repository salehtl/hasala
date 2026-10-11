package vectors

import (
	"crypto/ed25519"
	"encoding/binary"
	"fmt"

	"github.com/salehtl/hasala/server/internal/authkeys"
	. "github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// conformance/api-v1/messages.json and stepup.json (spec 02 §22): every
// signed message of spec 01 §10.1 and every step-up action of §10.2, from the
// anchor inputs, reproducing A11–A26.

type messageVector struct {
	Name      string         `json:"name"`
	Domain    string         `json:"domain"`
	Anchor    string         `json:"anchor,omitempty"`
	Fields    map[string]any `json:"fields"`
	Bytes     H              `json:"bytes"`
	Length    int            `json:"length"`
	SHA256    H              `json:"sha256"`
	Signer    string         `json:"signer,omitempty"` // which key signs it
	Seed      H              `json:"seed,omitempty"`   // Ed25519 signers: the 32-byte seed
	Pubkey    H              `json:"pubkey,omitempty"`
	Signature H              `json:"signature,omitempty"` // Ed25519: Go's deterministic signature; P-256: a sample that verifies
	Alg       string         `json:"alg,omitempty"`       // ed25519 | p256
	Extra     map[string]H   `json:"extra,omitempty"`
}

func ed(name, domain, anchor string, fields map[string]any, msg []byte, signer string, seed []byte) messageVector {
	k := ed25519.NewKeyFromSeed(seed)
	return messageVector{Name: name, Domain: domain, Anchor: anchor, Fields: fields, Bytes: msg, Length: len(msg),
		SHA256: sum(msg), Signer: signer, Seed: seed, Pubkey: H(k.Public().(ed25519.PublicKey)), Signature: ed25519.Sign(k, msg), Alg: "ed25519"}
}

func p256(name, domain, anchor string, fields map[string]any, msg []byte, sampleKey string) (messageVector, error) {
	sig := Hex(Anchors[sampleKey])
	if !keyproto.VerifyDAKBytes(AnchorDAKPub(), msg, sig) {
		return messageVector{}, fmt.Errorf("messages.json %s: the P-256 sample does not verify", name)
	}
	return messageVector{Name: name, Domain: domain, Anchor: anchor, Fields: fields, Bytes: msg, Length: len(msg),
		SHA256: sum(msg), Signer: "DAK", Pubkey: AnchorDAKPub(), Signature: sig, Alg: "p256"}, nil
}

func must(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

func anchorS() []byte {
	k, _ := authkeys.New(AnchorSaltKey, map[int][]byte{1: AnchorAuthKeyA19}, 1)
	norm, _ := keyproto.EmailNorm(AnchorEmailInput)
	return Stretch(AnchorPasswordNFD, k.PasswordSalt(norm), norm)
}

func genMessages(f Files, _ string) error {
	dwk, dak := AAKPub(AnchorDWKSeed), AnchorDAKPub()
	aak := AAKPub(AnchorAAKSeed)
	rk := RKPub(AnchorE)
	body := Body(AnchorAMK, AnchorAAKSeed)
	rwrap := SealRecoveryWrap(AnchorE, AnchorRecoverySalt, AnchorRecoveryNonce, body, AnchorUser)
	pwrap := SealPRFWrap(AnchorP, AnchorPRFSalt, AnchorPRFNonce, body, AnchorUser, AnchorCredentialID)
	box := SealPhraseBox(AnchorAMK, AnchorUser, rk, AnchorBoxNonce, AnchorE)
	norm, _ := keyproto.EmailNorm(AnchorEmailInput)
	eh := keyproto.EmailHash(norm)
	s := anchorS()
	a10 := Hex(Anchors["A10 blob_hash"])
	n := AnchorStepUpNonce

	var out []messageVector
	creg, _ := keyproto.RegisterChallenge(AnchorRegisterNonce, aak)
	out = append(out, messageVector{Name: "register C_reg", Domain: keyproto.DomainRegister, Anchor: "A12",
		Fields: map[string]any{"nonce": H(AnchorRegisterNonce), "authority_pubkey": H(aak)},
		Bytes:  append(append([]byte(keyproto.DomainRegister+"\x00"), AnchorRegisterNonce...), aak...),
		Length: 19 + 32 + 32, SHA256: creg[:]})
	out[0].Extra = map[string]H{"c_reg": creg[:]}

	reg := must(keyproto.RegistrationMessage(AnchorWriterNonce, AnchorWriterID, dwk, dak))
	out = append(out, ed("writer-registration", keyproto.DomainWriterRegistration, "A13",
		map[string]any{"nonce": H(AnchorWriterNonce), "writer_id": AnchorWriterID, "dwk_pub": H(dwk), "dak_pub": H(dak)}, reg, "AAK", AnchorAAKSeed))
	rev := must(keyproto.RevocationMessage(n, AnchorWriterID, 2, a10))
	out = append(out, ed("writer-revocation", keyproto.DomainWriterRevocation, "A15",
		map[string]any{"nonce": H(n), "writer_id": AnchorWriterID, "final_counter": "2", "final_head": H(a10)}, rev, "DWK", AnchorDWKSeed))
	rev0 := must(keyproto.RevocationMessage(n, AnchorWriterID, 0, make([]byte, 32)))
	out = append(out, ed("writer-revocation, empty chain (0, 0^32)", keyproto.DomainWriterRevocation, "",
		map[string]any{"nonce": H(n), "writer_id": AnchorWriterID, "final_counter": "0", "final_head": H(make([]byte, 32))}, rev0, "DWK", AnchorDWKSeed))
	sb := must(keyproto.SessionBindMessage(AnchorLoginChallenge, AnchorWriterID))
	out = append(out, ed("session-bind, passkey login (options.challenge)", keyproto.DomainSessionBind, "A16",
		map[string]any{"login_challenge": H(AnchorLoginChallenge), "writer_id": AnchorWriterID}, sb, "DWK", AnchorDWKSeed))
	sbp := must(keyproto.SessionBindMessage(AnchorWriterNonce, AnchorWriterID))
	out = append(out, ed("session-bind, password login (password/login/begin nonce)", keyproto.DomainSessionBind, "",
		map[string]any{"login_challenge": H(AnchorWriterNonce), "writer_id": AnchorWriterID}, sbp, "DWK", AnchorDWKSeed))
	del := must(keyproto.DeletionMessage(n, AnchorUser))
	out = append(out, ed("account-delete", keyproto.DomainAccountDelete, "A15",
		map[string]any{"nonce": H(n), "user_id": AnchorUser.String()}, del, "DWK", AnchorDWKSeed))

	for _, b := range []struct {
		name, anchor string
		kind         byte
		hash         []byte
		cred, wrap   []byte
	}{
		{"bootstrap, auth_kind 0 (step-up path)", "", keyproto.AuthKindNone, make([]byte, 32), AnchorCredentialID, pwrap},
		{"bootstrap, auth_kind 1 (passkey)", "A14", keyproto.AuthKindPasskey, sum(AnchorAttestation), AnchorCredentialID, pwrap},
		{"bootstrap, auth_kind 2 (password signup)", "A14-P", keyproto.AuthKindPassword, sum(s), nil, nil},
	} {
		pl := keyproto.BootstrapPayload{UserID: AnchorUser, AMKCommitment: AMKCommit(AnchorAMK, AnchorUser),
			AuthorityPubkey: aak, RecoveryPubkey: rk, RecoveryWrap: rwrap, PhraseBox: box, EmailHash: eh[:],
			AuthKind: b.kind, AuthHash: b.hash, WriterPubkey: dwk, WriterDAK: dak, WriterID: AnchorWriterID,
			CredentialID: b.cred, PRFWrap: b.wrap}
		payload, err := pl.Bytes()
		if err != nil {
			return err
		}
		bm := must(keyproto.BootstrapMessage(AnchorWriterNonce, payload))
		v := ed(b.name, keyproto.DomainBootstrap, b.anchor, map[string]any{
			"nonce": H(AnchorWriterNonce), "user_id": AnchorUser.String(), "amk_commitment": H(pl.AMKCommitment),
			"authority_pubkey": H(aak), "recovery_pubkey": H(rk), "recovery_wrap": H(rwrap), "phrase_box": H(box),
			"email_hash": H(eh[:]), "auth_kind": int(b.kind), "auth_hash": H(b.hash),
			"writer":   map[string]any{"writer_id": AnchorWriterID, "alg": "ed25519", "pubkey": H(dwk), "dak_pubkey": H(dak)},
			"prf_wrap": map[string]any{"credential_id": H(b.cred), "wrap": H(b.wrap)},
		}, bm, "AAK", AnchorAAKSeed)
		v.Extra = map[string]H{"payload": payload, "sha256_payload": sum(payload)}
		out = append(out, v)
	}

	rs := must(keyproto.RecoverySigninPasskey(AnchorRecoverNonce, AnchorClientDataJSON, AnchorAttestation, pwrap))
	out = append(out, ed("recovery-signin, passkey with PRF wrap", keyproto.DomainRecoverySignin, "A17",
		map[string]any{"nonce": H(AnchorRecoverNonce), "auth_kind": 1, "client_data_json": H(AnchorClientDataJSON),
			"attestation_object": H(AnchorAttestation), "prf_wrap": H(pwrap)}, rs, "RK", RKSeed(AnchorE)))
	rs0 := must(keyproto.RecoverySigninPasskey(AnchorRecoverNonce, AnchorClientDataJSON, AnchorAttestation, nil))
	out = append(out, ed("recovery-signin, passkey without a PRF wrap", keyproto.DomainRecoverySignin, "A17",
		map[string]any{"nonce": H(AnchorRecoverNonce), "auth_kind": 1, "client_data_json": H(AnchorClientDataJSON),
			"attestation_object": H(AnchorAttestation), "prf_wrap": nil}, rs0, "RK", RKSeed(AnchorE)))
	rsp := must(keyproto.RecoverySigninPassword(AnchorRecoverNonce, s))
	out = append(out, ed("recovery-signin, password", keyproto.DomainRecoverySignin, "A17",
		map[string]any{"nonce": H(AnchorRecoverNonce), "auth_kind": 2, "s_new": H(s)}, rsp, "RK", RKSeed(AnchorE)))

	rk2 := RKPub(AnchorRotateE)
	box2 := SealPhraseBox(AnchorAMK, AnchorUser, rk2, AnchorBoxNonce, AnchorRotateE)
	rot := must(keyproto.RecoveryRotateMessage(n, rk2, AnchorRotateWrap, box2))
	out = append(out, ed("recovery-rotate", keyproto.DomainRecoveryRotate, "A18",
		map[string]any{"nonce": H(n), "new_recovery_pubkey": H(rk2), "new_recovery_wrap": H(AnchorRotateWrap), "new_phrase_box": H(box2)},
		rot, "AAK", AnchorAAKSeed))
	ep := must(keyproto.EpochRotateMessage(n, 2, []byte("keyring")))
	out = append(out, ed("epoch-rotate [P, reserved]", keyproto.DomainEpochRotate, "",
		map[string]any{"nonce": H(n), "new_epoch": 2, "keyring": H([]byte("keyring"))}, ep, "AAK", AnchorAAKSeed))
	hm := must(keyproto.HeadMessage(AnchorUser, 2, a10, AnchorWriterID))
	out = append(out, ed("writer-head", keyproto.DomainWriterHead, "A21",
		map[string]any{"user_id": AnchorUser.String(), "counter": "2", "blob_hash": H(a10), "writer_id": AnchorWriterID}, hm, "DWK", AnchorDWKSeed))
	pa := must(keyproto.PasskeyAddMessage(n, AnchorClientDataJSON, AnchorAttestation, pwrap))
	out = append(out, ed("passkey-add", keyproto.DomainPasskeyAdd, "A20",
		map[string]any{"nonce": H(n), "client_data_json": H(AnchorClientDataJSON), "attestation_object": H(AnchorAttestation), "prf_wrap": H(pwrap)},
		pa, "DWK", AnchorDWKSeed))
	pa0 := must(keyproto.PasskeyAddMessage(n, AnchorClientDataJSON, AnchorAttestation, nil))
	out = append(out, ed("passkey-add without a PRF wrap", keyproto.DomainPasskeyAdd, "",
		map[string]any{"nonce": H(n), "client_data_json": H(AnchorClientDataJSON), "attestation_object": H(AnchorAttestation), "prf_wrap": nil},
		pa0, "DWK", AnchorDWKSeed))
	wp := must(keyproto.WrapPutMessage(n, AnchorCredentialID, pwrap))
	out = append(out, ed("wrap-put", keyproto.DomainWrapPut, "A20",
		map[string]any{"nonce": H(n), "credential_id": H(AnchorCredentialID), "wrap": H(pwrap)}, wp, "DWK", AnchorDWKSeed))

	pd, _ := keyproto.ParamsHash(keyproto.ActionPasskeyDelete, AnchorCredentialID)
	c, _ := keyproto.StepUpChallenge(n, keyproto.ActionPasskeyDelete, pd)
	ds := must(keyproto.DeviceStepUpMessage(c, AnchorWriterID))
	v, err := p256("step-up-device over C(passkey.delete)", keyproto.DomainStepUpDevice, "A22",
		map[string]any{"c": H(c[:]), "writer_id": AnchorWriterID}, ds, "A22 DAK sig")
	if err != nil {
		return err
	}
	out = append(out, v)
	ek := AAKPub(AnchorEKSeed)
	ra := must(keyproto.ResetApproveMessage(AnchorResetNonce, AnchorUser, ek, AnchorWriterID))
	if v, err = p256("reset-approve", keyproto.DomainResetApprove, "A25",
		map[string]any{"nonce": H(AnchorResetNonce), "user_id": AnchorUser.String(), "ek_pub": H(ek), "writer_id": AnchorWriterID}, ra, "A25 DAK sig ResetApprove"); err != nil {
		return err
	}
	out = append(out, v)
	rf := must(keyproto.ResetFinishMessage(AnchorResetNonce, s))
	out = append(out, ed("reset-finish", keyproto.DomainResetFinish, "A25",
		map[string]any{"nonce": H(AnchorResetNonce), "s_new": H(s)}, rf, "EK", AnchorEKSeed))
	newNorm, _ := keyproto.EmailNorm(AnchorNewEmailInput)
	ec := must(keyproto.EmailChangeMessage(n, newNorm))
	out = append(out, ed("email-change", keyproto.DomainEmailChange, "A24",
		map[string]any{"nonce": H(n), "new_email_norm": newNorm}, ec, "RK", RKSeed(AnchorE)))
	df := must(keyproto.DeviceFreezeMessage(n, AnchorUser, AnchorWriterID))
	if v, err = p256("device-freeze", keyproto.DomainDeviceFreeze, "A26",
		map[string]any{"nonce": H(n), "user_id": AnchorUser.String(), "writer_id": AnchorWriterID}, df, "A26 DAK sig"); err != nil {
		return err
	}
	out = append(out, v)

	return f.json(APIDir+"/messages.json", struct {
		Note     string          `json:"note"`
		Messages []messageVector `json:"messages"`
	}{
		Note: "spec 01 §10.1, every signed message from the anchor inputs of §15.5 (spec 02 §22). Ed25519 signatures are Go's " +
			"(deterministic) and must VERIFY under pubkey; never compare a Swift signature's bytes. P-256 (DAK) signatures are " +
			"the spec's verify-only samples under A13's DAK public key. writer_id and uuid strings are ASCII; binary fields are hex.",
		Messages: out,
	})
}

type stepUpVector struct {
	Action       string   `json:"action"`
	ProofKinds   []string `json:"proof_kinds"`
	Fields       []H      `json:"fields"`
	FieldsNote   string   `json:"fields_note"`
	Nonce        H        `json:"nonce"`
	Enc          H        `json:"enc"`
	ParamsHash   H        `json:"params_hash"`
	Challenge    H        `json:"c"`
	DeviceMsg    H        `json:"device_step_up_message,omitempty"`
	DeviceWriter string   `json:"device_writer_id,omitempty"`
	Synthetic    bool     `json:"synthetic,omitempty"`
}

func genStepUp(f Files, _ string) error {
	s := anchorS()
	newNorm, _ := keyproto.EmailNorm(AnchorNewEmailInput)
	addr := sum([]byte(newNorm))
	idToken := sum([]byte("header.claims.signature"))
	fields := map[keyproto.Action]struct {
		f    [][]byte
		note string
	}{
		keyproto.ActionPasskeyAdd:         {nil, "()"},
		keyproto.ActionPasskeyDelete:      {[][]byte{AnchorCredentialID}, "(credential_id raw)"},
		keyproto.ActionKeysBootstrap:      {[][]byte{AAKPub(AnchorAAKSeed)}, "(authority_pubkey)"},
		keyproto.ActionKeysWrapPut:        {[][]byte{AnchorCredentialID}, "(credential_id raw)"},
		keyproto.ActionKeysWrapDelete:     {[][]byte{AnchorCredentialID}, "(credential_id raw)"},
		keyproto.ActionKeysRecoveryRotate: {[][]byte{RKPub(AnchorRotateE)}, "(new_recovery_pubkey)"},
		keyproto.ActionKeysEpochRotate:    {[][]byte{binary.BigEndian.AppendUint32(nil, 2)}, "(u32be(new_epoch = 2))"},
		keyproto.ActionWriterRevoke:       {[][]byte{[]byte(AnchorWriterID)}, "(writer_id UTF-8)"},
		keyproto.ActionMailboxLink:        {[][]byte{idToken}, "(SHA256(id_token ASCII)), id_token = \"header.claims.signature\""},
		keyproto.ActionMailboxUnlink:      {nil, "()"},
		keyproto.ActionSessionLogoutAll:   {nil, "()"},
		keyproto.ActionAccountDelete:      {[][]byte{[]byte(AnchorUser.String())}, "(uuid_str(user_id) UTF-8)"},
		keyproto.ActionPasswordSet:        {[][]byte{sum(s)}, "(SHA256(S_new)), S of A19"},
		keyproto.ActionPasswordChange:     {[][]byte{sum(s)}, "(SHA256(S_new)), S of A19"},
		keyproto.ActionPasswordRemove:     {nil, "()"},
		keyproto.ActionPasswordReset:      {[][]byte{sum(s)}, "(SHA256(S_new)), S of A19"},
		keyproto.ActionEmailChange:        {[][]byte{addr, sum(s)}, "(SHA256(utf8(new_email_norm)), SHA256(S_new)), new address maya@example.ae"},
		keyproto.ActionPhraseView:         {nil, "()"},
		keyproto.ActionAccountFreeze:      {nil, "()"},
		keyproto.ActionAccountUnfreeze:    {nil, "()"},
	}
	var out []stepUpVector
	mk := func(a keyproto.Action, fs [][]byte, note string, synthetic bool) error {
		ph, err := keyproto.ParamsHash(a, fs...)
		if err != nil {
			return err
		}
		c, err := keyproto.StepUpChallenge(AnchorStepUpNonce, a, ph)
		if err != nil {
			return err
		}
		v := stepUpVector{Action: string(a), Fields: []H{}, FieldsNote: note, Nonce: AnchorStepUpNonce,
			Enc: keyproto.EncTuple(fs...), ParamsHash: ph[:], Challenge: c[:], Synthetic: synthetic}
		for _, x := range fs {
			v.Fields = append(v.Fields, H(append([]byte{}, x...)))
		}
		for _, k := range keyproto.AllowedProofs(a) {
			v.ProofKinds = append(v.ProofKinds, string(k))
			if k == keyproto.ProofDevice || k == keyproto.ProofDeviceCode {
				v.DeviceMsg = must(keyproto.DeviceStepUpMessage(c, AnchorWriterID))
				v.DeviceWriter = AnchorWriterID
			}
		}
		out = append(out, v)
		return nil
	}
	for _, a := range keyproto.Actions() {
		x := fields[a]
		if err := mk(a, x.f, x.note, false); err != nil {
			return err
		}
	}
	if err := mk(keyproto.ActionEmailChange, [][]byte{addr, {}}, "(SHA256(new address), the empty field): no password", false); err != nil {
		return err
	}
	if err := mk("test.three_fields", [][]byte{{1}, {}, Range(0x00, 0x2f)}, "a synthetic three-field tuple: (01, empty, 00..2f)", true); err != nil {
		return err
	}
	return f.json(APIDir+"/stepup.json", struct {
		Note    string         `json:"note"`
		Actions []stepUpVector `json:"actions"`
	}{
		Note: "spec 01 §10.2 / spec 02 §8.3: enc(T) = for each field u32be(len) ‖ field; params_hash = SHA256(\"hasala/v1/step-up-params\" ‖ 00 ‖ " +
			"action ‖ 00 ‖ enc(T)); C = SHA256(\"hasala/v1/step-up\" ‖ 00 ‖ nonce32 ‖ action ‖ 00 ‖ params_hash); DeviceStepUpMessage = " +
			"\"hasala/v1/step-up-device\" ‖ 00 ‖ C ‖ 00 ‖ writer_id (98 bytes), present for actions with a device proof kind. " +
			"All 20 actions, the empty-field email.change, and one synthetic 3-field tuple (not an action). Reproduces A11, A18's params hash, A22 and A23.",
		Actions: out,
	})
}
