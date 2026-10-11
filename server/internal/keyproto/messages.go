package keyproto

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/google/uuid"
)

// Signed messages, spec 01 §10.1. Each builder writes the exact bytes of its
// row: fixed-length fields plus at most one variable field, which is either
// last or pinned between fixed-length ones, so no two inputs encode to the same
// bytes. Builders refuse a field of the wrong length (ErrFieldLength) instead
// of encoding it, because a short nonce or key would make the encoding
// ambiguous; writer ids are checked against the §4.8 grammar by the callers
// that accept them from the wire (ValidWriterID), and here only for the
// absence of 0x00.

// Field sizes used by the messages.
const (
	NonceSize        = 32 // every server-issued nonce
	Ed25519KeySize   = 32
	Ed25519SigSize   = 64
	DAKKeySize       = 65 // X9.63 uncompressed P-256: 04 ‖ X ‖ Y
	DAKSigSize       = 64 // raw r ‖ s
	HashSize         = 32
	WriterIDSize     = 40 // "ios-" ‖ 36-char UUID (§4.8)
	UUIDStringSize   = 36
	RegistrationSize = 201
	RevocationSize   = 142
	SessionBindSize  = 96
	DeletionSize     = 94
	BootstrapMsgSize = 84
	RecoverySignSize = 155
	RecoveryRotSize  = 154
	EpochRotateSize  = 91
	HeadMessageSize  = 119
	PasskeyAddSize   = 150
	WrapPutSize      = 115
	DeviceStepUpSize = 98
	ResetApproveSize = 145
	ResetFinishSize  = 87
	EmailChangeSize  = 87
	DeviceFreezeSize = 113
)

// auth_kind values (spec 01 §10.1): closed; each message accepts only the
// values its row names.
const (
	AuthKindNone     byte = 0x00
	AuthKindPasskey  byte = 0x01
	AuthKindPassword byte = 0x02
)

// ErrFieldLength means a builder was handed a field of the wrong size.
var ErrFieldLength = errors.New("keyproto: field has the wrong length")

var zero32 = make([]byte, 32)

func need(name string, b []byte, n int) error {
	if len(b) != n {
		return fmt.Errorf("%w: %s is %d bytes, want %d", ErrFieldLength, name, len(b), n)
	}
	return nil
}

func needWriter(id string) error {
	if len(id) != WriterIDSize {
		return fmt.Errorf("%w: writer_id is %d bytes, want %d", ErrFieldLength, len(id), WriterIDSize)
	}
	for i := 0; i < len(id); i++ {
		if id[i] == 0 {
			return fmt.Errorf("%w: writer_id contains 0x00", ErrFieldLength)
		}
	}
	return nil
}

func prefix(domain string, capacity int) []byte {
	m := make([]byte, 0, capacity)
	m = append(m, domain...)
	return append(m, 0x00)
}

func sum(b []byte) []byte {
	s := sha256.Sum256(b)
	return s[:]
}

// RegisterChallenge is C_reg = SHA256("hasala/v1/register" ‖ 00 ‖ nonce32 ‖
// authority_pub32) (D01, spec 01 §10.3 step 5): the WebAuthn challenge of the
// account-creating registration, which binds the authority key into the UV
// ceremony.
func RegisterChallenge(nonce, authorityPub []byte) ([32]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return [32]byte{}, err
	}
	if err := need("authority_pubkey", authorityPub, Ed25519KeySize); err != nil {
		return [32]byte{}, err
	}
	m := prefix(DomainRegister, 19+NonceSize+Ed25519KeySize)
	m = append(m, nonce...)
	m = append(m, authorityPub...)
	return sha256.Sum256(m), nil
}

// RegistrationMessage (D13, 201 bytes): "hasala/v1/writer-registration" ‖ 00 ‖
// nonce32 ‖ 00 ‖ writer_id ‖ 00 ‖ dwk_pub32 ‖ dak_pub65. Signed by the AAK; it
// certifies both device keys.
func RegistrationMessage(nonce []byte, writerID string, dwkPub, dakPub []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	if err := need("pubkey", dwkPub, Ed25519KeySize); err != nil {
		return nil, err
	}
	if err := need("dak_pubkey", dakPub, DAKKeySize); err != nil {
		return nil, err
	}
	m := prefix(DomainWriterRegistration, RegistrationSize)
	m = append(m, nonce...)
	m = append(m, 0x00)
	m = append(m, writerID...)
	m = append(m, 0x00)
	m = append(m, dwkPub...)
	return append(m, dakPub...), nil
}

// RevocationMessage (D14, 142 bytes): "hasala/v1/writer-revocation" ‖ 00 ‖
// nonce32 ‖ 00 ‖ writer_id ‖ 00 ‖ u64be(final_counter) ‖ final_head32. Signed
// by a live writer's DWK; it pins the target's final head (R-02). An empty
// chain is (0, 0^32).
func RevocationMessage(nonce []byte, writerID string, finalCounter uint64, finalHead []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	if err := need("final_head", finalHead, HashSize); err != nil {
		return nil, err
	}
	m := prefix(DomainWriterRevocation, RevocationSize)
	m = append(m, nonce...)
	m = append(m, 0x00)
	m = append(m, writerID...)
	m = append(m, 0x00)
	m = binary.BigEndian.AppendUint64(m, finalCounter)
	return append(m, finalHead...), nil
}

// SessionBindMessage (D15, 96 bytes): "hasala/v1/session-bind" ‖ 00 ‖
// login_challenge32 ‖ 00 ‖ writer_id. Signed by the DWK at a bound sign-in.
func SessionBindMessage(loginChallenge []byte, writerID string) ([]byte, error) {
	if err := need("login_challenge", loginChallenge, NonceSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainSessionBind, SessionBindSize)
	m = append(m, loginChallenge...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}

// DeletionMessage (D16, 94 bytes): "hasala/v1/account-delete" ‖ 00 ‖ nonce32 ‖
// 00 ‖ uuid_str(user_id). Signed by a live writer's DWK over step_up.nonce.
func DeletionMessage(nonce []byte, userID uuid.UUID) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainAccountDelete, DeletionSize)
	m = append(m, nonce...)
	m = append(m, 0x00)
	return append(m, userID.String()...), nil
}

// BootstrapMessage (D17, 84 bytes): "hasala/v1/bootstrap" ‖ 00 ‖ nonce32 ‖
// SHA256(BootstrapPayload). Signed by the AAK.
func BootstrapMessage(nonce, payload []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainBootstrap, BootstrapMsgSize)
	m = append(m, nonce...)
	return append(m, sum(payload)...), nil
}

// RecoverySigninMessage (D18, 155 bytes): "hasala/v1/recovery-signin" ‖ 00 ‖
// nonce32 ‖ u8(auth_kind) ‖ H1 ‖ H2 ‖ H3, signed by RK. Passkey (0x01): H1 =
// SHA256(clientDataJSON), H2 = SHA256(attestationObject), H3 = SHA256(prf_wrap)
// or 0^32; password (0x02): H1 = SHA256(S_new), H2 = H3 = 0^32. The caller
// passes the three hashes.
func RecoverySigninMessage(nonce []byte, authKind byte, h1, h2, h3 []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if authKind != AuthKindPasskey && authKind != AuthKindPassword {
		return nil, fmt.Errorf("%w: auth_kind 0x%02x is not passkey or password", ErrFieldLength, authKind)
	}
	for i, h := range [][]byte{h1, h2, h3} {
		if err := need(fmt.Sprintf("H%d", i+1), h, HashSize); err != nil {
			return nil, err
		}
	}
	m := prefix(DomainRecoverySignin, RecoverySignSize)
	m = append(m, nonce...)
	m = append(m, authKind)
	m = append(m, h1...)
	m = append(m, h2...)
	return append(m, h3...), nil
}

// RecoverySigninPasskey builds the passkey variant from the raw bytes.
func RecoverySigninPasskey(nonce, clientDataJSON, attestationObject, prfWrap []byte) ([]byte, error) {
	h3 := zero32
	if prfWrap != nil {
		h3 = sum(prfWrap)
	}
	return RecoverySigninMessage(nonce, AuthKindPasskey, sum(clientDataJSON), sum(attestationObject), h3)
}

// RecoverySigninPassword builds the password variant from S_new.
func RecoverySigninPassword(nonce, sNew []byte) ([]byte, error) {
	return RecoverySigninMessage(nonce, AuthKindPassword, sum(sNew), zero32, zero32)
}

// RecoveryRotateMessage (D19, 154 bytes): "hasala/v1/recovery-rotate" ‖ 00 ‖
// nonce32 ‖ new_recovery_pub32 ‖ SHA256(new_recovery_wrap) ‖
// SHA256(new_phrase_box). Signed by the AAK over step_up.nonce.
func RecoveryRotateMessage(nonce, newRecoveryPub, newWrap, newBox []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := need("new_recovery_pubkey", newRecoveryPub, Ed25519KeySize); err != nil {
		return nil, err
	}
	m := prefix(DomainRecoveryRotate, RecoveryRotSize)
	m = append(m, nonce...)
	m = append(m, newRecoveryPub...)
	m = append(m, sum(newWrap)...)
	return append(m, sum(newBox)...), nil
}

// EpochRotateMessage (D20, 91 bytes) [P]: "hasala/v1/epoch-rotate" ‖ 00 ‖
// nonce32 ‖ u32be(new_epoch) ‖ SHA256(keyring). Reserved: no route uses it.
func EpochRotateMessage(nonce []byte, newEpoch uint32, keyring []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainEpochRotate, EpochRotateSize)
	m = append(m, nonce...)
	m = binary.BigEndian.AppendUint32(m, newEpoch)
	return append(m, sum(keyring)...), nil
}

// HeadMessage (D32, 119 bytes): "hasala/v1/writer-head" ‖ 00 ‖ uuid_raw(user_id)
// ‖ u64be(counter) ‖ blob_hash32 ‖ 00 ‖ writer_id. One per upload batch, over
// its last row, signed by that writer's DWK (spec 01 §7.1, R-02).
func HeadMessage(userID uuid.UUID, counter uint64, blobHash []byte, writerID string) ([]byte, error) {
	if err := need("blob_hash", blobHash, HashSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainWriterHead, HeadMessageSize)
	m = append(m, userID[:]...)
	m = binary.BigEndian.AppendUint64(m, counter)
	m = append(m, blobHash...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}

// PasskeyAddMessage (D33, 150 bytes): "hasala/v1/passkey-add" ‖ 00 ‖ nonce32 ‖
// SHA256(clientDataJSON) ‖ SHA256(attestationObject) ‖ (SHA256(prf_wrap) or
// 0^32). Signed by the session writer's DWK at add/finish. A nil prfWrap means
// none.
func PasskeyAddMessage(nonce, clientDataJSON, attestationObject, prfWrap []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainPasskeyAdd, PasskeyAddSize)
	m = append(m, nonce...)
	m = append(m, sum(clientDataJSON)...)
	m = append(m, sum(attestationObject)...)
	if prfWrap == nil {
		return append(m, zero32...), nil
	}
	return append(m, sum(prfWrap)...), nil
}

// WrapPutMessage (D34, 115 bytes): "hasala/v1/wrap-put" ‖ 00 ‖ nonce32 ‖
// SHA256(credential_id) ‖ SHA256(wrap). Signed by the session writer's DWK
// over the keys.wrap.put step-up nonce (N-11).
func WrapPutMessage(nonce, credentialID, wrap []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainWrapPut, WrapPutSize)
	m = append(m, nonce...)
	m = append(m, sum(credentialID)...)
	return append(m, sum(wrap)...), nil
}

// DeviceStepUpMessage (D31, 98 bytes): "hasala/v1/step-up-device" ‖ 00 ‖ C32 ‖
// 00 ‖ writer_id. Signed by the bound writer's DAK (P-256).
func DeviceStepUpMessage(c [32]byte, writerID string) ([]byte, error) {
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainStepUpDevice, DeviceStepUpSize)
	m = append(m, c[:]...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}

// ResetApproveMessage (D38, 145 bytes): "hasala/v1/reset-approve" ‖ 00 ‖ nonce32
// ‖ uuid_raw(user_id) ‖ SHA256(ek_pub32) ‖ 00 ‖ writer_id. Signed by the
// approving writer's DAK.
func ResetApproveMessage(nonce []byte, userID uuid.UUID, ekPub []byte, writerID string) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := need("ek_pub", ekPub, Ed25519KeySize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainResetApprove, ResetApproveSize)
	m = append(m, nonce...)
	m = append(m, userID[:]...)
	m = append(m, sum(ekPub)...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}

// ResetFinishMessage (D39, 87 bytes): "hasala/v1/reset-finish" ‖ 00 ‖ nonce32 ‖
// SHA256(S_new). Signed by the new iPhone's ephemeral key.
func ResetFinishMessage(nonce, sNew []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainResetFinish, ResetFinishSize)
	m = append(m, nonce...)
	return append(m, sum(sNew)...), nil
}

// EmailChangeMessage (D40, 87 bytes): "hasala/v1/email-change" ‖ 00 ‖ nonce32 ‖
// SHA256(utf8(new_email_norm)). Signed by RK in place of the old-address code.
func EmailChangeMessage(nonce []byte, newEmailNorm string) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainEmailChange, EmailChangeSize)
	m = append(m, nonce...)
	return append(m, sum([]byte(newEmailNorm))...), nil
}

// DeviceFreezeMessage (D42, 113 bytes): "hasala/v1/device-freeze" ‖ 00 ‖ nonce32
// ‖ uuid_raw(user_id) ‖ 00 ‖ writer_id. Signed by a live writer's DAK with no
// session (spec 01 §10.18, review 2 F-02).
func DeviceFreezeMessage(nonce []byte, userID uuid.UUID, writerID string) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainDeviceFreeze, DeviceFreezeSize)
	m = append(m, nonce...)
	m = append(m, userID[:]...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}
