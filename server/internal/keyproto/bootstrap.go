package keyproto

import (
	"encoding/binary"
	"fmt"

	"github.com/google/uuid"
)

// BootstrapPayloadVersion is format_version / payload byte 0 (spec 01 §10.3.1).
const BootstrapPayloadVersion = 0x01

// BootstrapPayload is spec 01 §10.3.1's v1 payload, the bytes the AAK signs
// (inside BootstrapMessage) at account bootstrap and at password signup. The
// server never trusts a client's serialization of it: it rebuilds the bytes
// from the JSON fields of spec 02 §10.1 and the account's own user id, and
// verifies the AAK signature over what it built.
type BootstrapPayload struct {
	UserID          uuid.UUID // the session's user (C1) or the signup's reserved id (C1-P)
	AMKCommitment   []byte    // 32
	AuthorityPubkey []byte    // 32
	RecoveryPubkey  []byte    // 32
	RecoveryWrap    []byte    // 127, kdf 0x01
	PhraseBox       []byte    // 45
	EmailHash       []byte    // 32: SHA256(utf8(email_norm))
	AuthKind        byte      // 0x00 none, 0x01 passkey, 0x02 password
	AuthHash        []byte    // 32: 0^32, SHA256(attestationObject) or SHA256(S)
	WriterPubkey    []byte    // 32: the first writer's DWK
	WriterDAK       []byte    // 65: its DAK
	WriterID        string    // 40
	CredentialID    []byte    // nil, or 16–1023 bytes: the PRF wrap's credential
	PRFWrap         []byte    // nil, or 127 bytes with kdf 0x02
}

// Bytes builds the canonical payload: 501 + c + w bytes. It validates every
// length and header byte the server checks before signatures (spec 01
// §10.3.2 step 3), so a payload that builds is one whose shape the server
// accepts; key-level checks (small order, the DAK point, distinctness) are
// CheckKeys's.
func (p BootstrapPayload) Bytes() ([]byte, error) {
	if p.UserID == uuid.Nil {
		return nil, fmt.Errorf("%w: user_id is zero", ErrShape)
	}
	for _, f := range []struct {
		name string
		b    []byte
		n    int
	}{
		{"amk_commitment", p.AMKCommitment, 32},
		{"authority_pubkey", p.AuthorityPubkey, 32},
		{"recovery_pubkey", p.RecoveryPubkey, 32},
		{"email_hash", p.EmailHash, 32},
		{"auth_hash", p.AuthHash, 32},
		{"writer.pubkey", p.WriterPubkey, 32},
		{"writer.dak_pubkey", p.WriterDAK, DAKKeySize},
	} {
		if err := need(f.name, f.b, f.n); err != nil {
			return nil, err
		}
	}
	if err := CheckRecoveryWrap(p.RecoveryWrap); err != nil {
		return nil, err
	}
	if err := CheckPhraseBox(p.PhraseBox); err != nil {
		return nil, err
	}
	if p.AuthKind > AuthKindPassword {
		return nil, fmt.Errorf("%w: auth_kind 0x%02x", ErrShape, p.AuthKind)
	}
	if !ValidWriterID(p.WriterID) {
		return nil, fmt.Errorf("%w: writer_id does not match the §4.8 grammar", ErrShape)
	}
	c, w := len(p.CredentialID), len(p.PRFWrap)
	switch {
	case c == 0 && w == 0:
	case c == 0 || w == 0:
		return nil, fmt.Errorf("%w: a PRF wrap needs both its credential id and its wrap", ErrShape)
	default:
		if err := CheckCredentialID(p.CredentialID); err != nil {
			return nil, err
		}
		if err := CheckPRFWrap(p.PRFWrap); err != nil {
			return nil, err
		}
	}

	out := make([]byte, 0, 501+c+w)
	out = append(out, BootstrapPayloadVersion)
	out = append(out, p.UserID[:]...)
	out = append(out, p.AMKCommitment...)
	out = append(out, p.AuthorityPubkey...)
	out = append(out, p.RecoveryPubkey...)
	out = binary.BigEndian.AppendUint32(out, 1) // initial epoch
	out = binary.BigEndian.AppendUint16(out, WrapSize)
	out = append(out, p.RecoveryWrap...)
	out = binary.BigEndian.AppendUint16(out, PhraseBoxSize)
	out = append(out, p.PhraseBox...)
	out = append(out, p.EmailHash...)
	out = append(out, p.AuthKind)
	out = append(out, p.AuthHash...)
	out = append(out, 0x01) // writer.alg = "ed25519"
	out = append(out, p.WriterPubkey...)
	out = append(out, p.WriterDAK...)
	out = append(out, byte(WriterIDSize))
	out = append(out, p.WriterID...)
	out = binary.BigEndian.AppendUint16(out, uint16(c))
	out = append(out, p.CredentialID...)
	out = binary.BigEndian.AppendUint16(out, uint16(w))
	out = append(out, p.PRFWrap...)
	return out, nil
}

// CheckKeys is the key half of spec 01 §10.3.2 step 3: the authority,
// recovery and writer keys are not small-order and are pairwise distinct, and
// the DAK parses as an uncompressed P-256 point.
func (p BootstrapPayload) CheckKeys() error {
	for _, k := range []struct {
		name string
		b    []byte
	}{
		{"authority_pubkey", p.AuthorityPubkey},
		{"recovery_pubkey", p.RecoveryPubkey},
		{"writer.pubkey", p.WriterPubkey},
	} {
		if err := CheckEd25519PublicKey(k.b); err != nil {
			return fmt.Errorf("%s: %w", k.name, err)
		}
	}
	if !distinct(p.AuthorityPubkey, p.RecoveryPubkey, p.WriterPubkey) {
		return fmt.Errorf("%w: the authority, recovery and writer keys must differ", ErrShape)
	}
	if _, err := ParseDAK(p.WriterDAK); err != nil {
		return err
	}
	return nil
}
