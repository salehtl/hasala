package keyproto

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"regexp"
	"slices"
)

// Step-up bytes, spec 01 §10.2 (adopted from spec 02 §8.3):
//
//	enc(T)      = for each field f of T, in order: u32be(|f|) ‖ f      (empty tuple → zero bytes)
//	params_hash = SHA256("hasala/v1/step-up-params" ‖ 00 ‖ action ‖ 00 ‖ enc(T))
//	C           = SHA256("hasala/v1/step-up" ‖ 00 ‖ nonce32 ‖ action ‖ 00 ‖ params_hash)
//
// The bytes are the same for every proof kind (anchor A11).

// Action is a step-up action name from the closed set of spec 01 §10.2.
type Action string

// The 20 actions (spec 01 §10.2, spec 02 §8.2).
const (
	ActionPasskeyAdd         Action = "passkey.add"
	ActionPasskeyDelete      Action = "passkey.delete"
	ActionKeysBootstrap      Action = "keys.bootstrap"
	ActionKeysWrapPut        Action = "keys.wrap.put"
	ActionKeysWrapDelete     Action = "keys.wrap.delete"
	ActionKeysRecoveryRotate Action = "keys.recovery.rotate"
	ActionKeysEpochRotate    Action = "keys.epoch.rotate"
	ActionWriterRevoke       Action = "writer.revoke"
	ActionMailboxLink        Action = "mailbox.link"
	ActionMailboxUnlink      Action = "mailbox.unlink"
	ActionSessionLogoutAll   Action = "session.logout_all"
	ActionAccountDelete      Action = "account.delete"
	ActionPasswordSet        Action = "password.set"
	ActionPasswordChange     Action = "password.change"
	ActionPasswordRemove     Action = "password.remove"
	ActionPasswordReset      Action = "password.reset"
	ActionEmailChange        Action = "email.change"
	ActionPhraseView         Action = "phrase.view"
	ActionAccountFreeze      Action = "account.freeze"
	ActionAccountUnfreeze    Action = "account.unfreeze"
)

// ProofKind is how a step-up proves the user approved C.
type ProofKind string

// The three proof kinds (spec 01 §10.2).
const (
	ProofPasskey    ProofKind = "passkey"
	ProofDevice     ProofKind = "device"
	ProofDeviceCode ProofKind = "device_code"
)

var (
	passkeyOnly = []ProofKind{ProofPasskey}
	passkeyDev  = []ProofKind{ProofPasskey, ProofDevice}
)

// proofKinds is the last column of spec 01 §10.2's table, in its row order.
var proofKinds = []struct {
	action Action
	kinds  []ProofKind
}{
	{ActionPasskeyAdd, passkeyDev},
	{ActionPasskeyDelete, passkeyDev},
	{ActionKeysBootstrap, passkeyOnly},
	{ActionKeysWrapPut, passkeyOnly},
	{ActionKeysWrapDelete, passkeyDev},
	{ActionKeysRecoveryRotate, passkeyDev},
	{ActionKeysEpochRotate, passkeyDev},
	{ActionWriterRevoke, passkeyDev},
	{ActionMailboxLink, passkeyDev},
	{ActionMailboxUnlink, passkeyDev},
	{ActionSessionLogoutAll, passkeyDev},
	{ActionAccountDelete, passkeyDev},
	{ActionPasswordSet, passkeyOnly},
	{ActionPasswordChange, passkeyDev},
	{ActionPasswordRemove, passkeyOnly},
	{ActionPasswordReset, []ProofKind{ProofDeviceCode}},
	{ActionEmailChange, passkeyDev},
	{ActionPhraseView, passkeyOnly},
	{ActionAccountFreeze, passkeyDev},
	{ActionAccountUnfreeze, passkeyDev},
}

// Actions returns the closed set of 20 actions, in spec 01 §10.2's order.
func Actions() []Action {
	out := make([]Action, len(proofKinds))
	for i, r := range proofKinds {
		out[i] = r.action
	}
	return out
}

// AllowedProofs returns the proof kinds an action accepts, or nil for a name
// outside the closed set.
func AllowedProofs(a Action) []ProofKind {
	for _, r := range proofKinds {
		if r.action == a {
			return append([]ProofKind(nil), r.kinds...)
		}
	}
	return nil
}

// ProofAllowed reports whether kind is one of action's proof kinds.
func ProofAllowed(a Action, kind ProofKind) bool { return slices.Contains(AllowedProofs(a), kind) }

var actionGrammar = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`)

// ValidAction reports whether a is in the closed set (which implies the
// §10.2 grammar and the 48-byte bound).
func ValidAction(a Action) bool { return AllowedProofs(a) != nil }

// EncTuple is enc(T): every field, in order, as u32be(len) ‖ bytes. An empty
// tuple is zero bytes; an empty field is u32be(0).
func EncTuple(fields ...[]byte) []byte {
	n := 0
	for _, f := range fields {
		n += 4 + len(f)
	}
	out := make([]byte, 0, n)
	for _, f := range fields {
		out = binary.BigEndian.AppendUint32(out, uint32(len(f)))
		out = append(out, f...)
	}
	return out
}

func checkAction(a Action) error {
	if len(a) == 0 || len(a) > 48 || !actionGrammar.MatchString(string(a)) {
		return fmt.Errorf("%w: action %q is not a step-up action name", ErrFieldLength, a)
	}
	return nil
}

// ParamsHash is SHA256("hasala/v1/step-up-params" ‖ 00 ‖ action ‖ 00 ‖ enc(T)).
// It accepts any name of the §10.2 grammar, so the vectors can pin the bytes
// of names outside the closed set too; the server's routes only ever pass
// their own action.
func ParamsHash(a Action, fields ...[]byte) ([32]byte, error) {
	if err := checkAction(a); err != nil {
		return [32]byte{}, err
	}
	enc := EncTuple(fields...)
	m := prefix(DomainStepUpParams, len(DomainStepUpParams)+2+len(a)+len(enc))
	m = append(m, a...)
	m = append(m, 0x00)
	m = append(m, enc...)
	return sha256.Sum256(m), nil
}

// StepUpChallenge is C = SHA256("hasala/v1/step-up" ‖ 00 ‖ nonce32 ‖ action ‖
// 00 ‖ params_hash): the 32 bytes a passkey asserts over and a DAK signs
// inside DeviceStepUpMessage.
func StepUpChallenge(nonce []byte, a Action, paramsHash [32]byte) ([32]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return [32]byte{}, err
	}
	if err := checkAction(a); err != nil {
		return [32]byte{}, err
	}
	m := prefix(DomainStepUp, len(DomainStepUp)+1+NonceSize+len(a)+1+32)
	m = append(m, nonce...)
	m = append(m, a...)
	m = append(m, 0x00)
	m = append(m, paramsHash[:]...)
	return sha256.Sum256(m), nil
}
