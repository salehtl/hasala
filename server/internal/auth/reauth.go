package auth

// Re-authentication: proving a human is present, over a challenge THIS server
// issued for THIS action.
//
// # Why it is here and not in passkey.go
//
// passkey.go runs the three ceremonies that establish or extend an identity —
// register, login, add — and every one of them is two round trips with a
// webauthn_ceremonies row in the middle. This is not a ceremony in that sense
// and must not become one: the challenge already exists before anything here is
// called (a step-up's C, spec 02 §8, minted by step-up/begin into
// step_up_challenges), and it is single-use in that table. A second ceremony
// row would be a second piece of state with its own expiry, its own sweep and
// its own chance of disagreeing with the first about whether this attempt is
// still live.
//
// So: no row, no ceremony id, no begin step. The caller hands over the raw
// challenge it is holding and the assertion the authenticator produced over it.
//
// # What this proves, and what it does not
//
// It proves that an authenticator holding an enrolled credential of THIS
// account signed the exact bytes this server minted for this action, with user
// verification. It proves NOTHING about the account's writer keys: the
// guarded actions that need a device (deletion's signature, a revocation) check
// that factor themselves.
//
// # Freshness lives in the challenge, not here
//
// SessionData.Expires is deliberately left zero. The only thing that decides
// whether this attempt is in time is the step-up row, which StepUp spends
// exactly once and refuses past its own expiry against one clock. A second
// expiry here — evaluated against a different clock, from a different instant
// — would be a way for the two halves of one user gesture to disagree about
// whether the gesture is still happening.

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
)

// VerifyAssertion checks a passkey assertion over a server-issued challenge
// against an enrolled credential of userID.
//
// Every rejection wraps ErrPasskeyRejected, so a caller writes one errors.Is
// and answers all of them identically. Anything that is NOT a rejection — the
// database is unreachable, this deployment has no relying party — is a plain
// error, because reporting infrastructure trouble as "your credential is
// invalid" sends a user off to re-authenticate for a reason that does not
// exist.
//
// The checks, in the order they run and with the reason each is not redundant:
//
//  1. The credential id the assertion carries names a row this deployment has
//     enrolled. Unknown is a rejection, never a first enrolment.
//  2. That row belongs to userID. This is what stops one account's passkey
//     re-authenticating another's session — the assertion itself says nothing
//     about which account is being talked about.
//  3. The account the credential's user handle NAMES is the same one its
//     foreign key says. The two are derived independently (SubjectHash vs a
//     column), so agreement is a real check, and it is the same tripwire
//     FinishLogin and verifyAdd carry.
//  4. go-webauthn verifies the signature, the challenge, the origin, the RP id
//     hash and the user-verification flag. None of that is re-implemented here;
//     this is the one path where a hand-rolled mistake is an auth bypass.
//  5. A counter that did not advance is refused, not merely recorded — same
//     policy as FinishLogin, and see ErrClonedAuthenticator for why a permanent
//     zero is not that.
func (p *Passkeys) VerifyAssertion(ctx context.Context, userID uuid.UUID, challenge, response []byte) error {
	_, err := p.VerifyAssertionCredential(ctx, userID, challenge, response)
	return err
}

// VerifyAssertionCredential is VerifyAssertion, answering which of the
// account's credentials asserted (a keys.wrap.put step-up requires it to be the
// wrap's own, spec 01 §10.7).
func (p *Passkeys) VerifyAssertionCredential(ctx context.Context, userID uuid.UUID, challenge, response []byte) ([]byte, error) {
	if p == nil || p.Pool == nil {
		return nil, errors.New("auth: Passkeys is not configured")
	}
	return p.VerifyAssertionCredentialTx(ctx, p.Pool, userID, challenge, response)
}

// VerifyAssertionCredentialTx is VerifyAssertionCredential with every read
// and the counter update made through q: a caller that holds a transaction
// (StepUp.Run, which holds the nonce's row lock) passes it, so the check never
// needs a second connection while the first waits.
func (p *Passkeys) VerifyAssertionCredentialTx(ctx context.Context, q dbtx, userID uuid.UUID, challenge, response []byte) ([]byte, error) {
	if p == nil || p.WA == nil || q == nil {
		return nil, errors.New("auth: Passkeys is not configured")
	}
	if userID == uuid.Nil {
		return nil, fmt.Errorf("%w: user id is zero", ErrPasskeyRejected)
	}
	// A short challenge would be accepted by go-webauthn (it only compares the
	// echoed value) and would mean this server had authorized an assertion over
	// something it did not mint. The nonces it does mint are 32 bytes.
	if len(challenge) < 16 {
		return nil, fmt.Errorf("%w: challenge is %d bytes, too short to be one of ours", ErrPasskeyRejected, len(challenge))
	}
	if len(response) == 0 {
		// An absent assertion is a factor that was not presented. It is the
		// caller's job to answer it identically to a wrong one.
		return nil, fmt.Errorf("%w: no assertion presented", ErrPasskeyRejected)
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(response)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}

	stored, err := p.credentialByID(ctx, q, parsed.RawID)
	if err != nil {
		return nil, err
	}
	if stored.UserID != userID {
		// Deliberately the same sentinel as "no such credential": which of the
		// two it was tells a caller whether a credential id exists and whose it
		// is.
		return nil, fmt.Errorf("%w: credential belongs to a different account", ErrPasskeyRejected)
	}
	byHandle, err := p.userIDForHandle(ctx, q, stored.UserHandle)
	if err != nil {
		return nil, err
	}
	if byHandle != stored.UserID {
		return nil, fmt.Errorf("%w: credential owner and user handle disagree", ErrPasskeyRejected)
	}

	// The challenge as the authenticator saw it: WebAuthn puts base64url of the
	// raw bytes into clientDataJSON, and go-webauthn compares that string.
	session := webauthn.SessionData{
		Challenge:            base64.RawURLEncoding.EncodeToString(challenge),
		RelyingPartyID:       p.WA.Config.RPID,
		UserID:               stored.UserHandle,
		AllowedCredentialIDs: [][]byte{stored.Credential.ID},
		UserVerification:     p.WA.Config.AuthenticatorSelection.UserVerification,
	}
	user := passkeyUser{
		handle:      stored.UserHandle,
		credentials: []webauthn.Credential{stored.Credential},
		rpName:      p.WA.Config.RPDisplayName,
	}
	cred, err := p.WA.ValidateLogin(user, session, parsed)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	if cred.Authenticator.CloneWarning {
		return nil, ErrClonedAuthenticator
	}
	// UV is required in every ceremony (spec 02 §8.1); go-webauthn checks the
	// flag when the session says "required", and this repeats it so that a
	// configuration change cannot quietly drop it.
	if !parsed.Response.AuthenticatorData.Flags.HasUserVerified() {
		return nil, fmt.Errorf("%w: user verification flag is clear", ErrPasskeyRejected)
	}
	// Recorded on the same terms as a sign-in: the counter never goes backwards
	// and last_used_at moves regardless, because a synced passkey reports a
	// permanent zero and "it was used just now" is true anyway.
	if err := p.touchCredential(ctx, q, cred.ID, cred.Authenticator.SignCount, p.now().UTC()); err != nil {
		return nil, err
	}
	return cred.ID, nil
}
