package auth

// Passkeys: the WebAuthn ceremonies (spec 02 §7 #3–#6, #10–#13; spec 01
// §10.3, §10.7). RP ID hasala.app, user verification required in every
// ceremony, discoverable credentials.
//
// # The handle a passkey names
//
// Every account has a user handle (users.user_handle): 32 bytes from
// crypto/rand, minted at signup and stored on every credential the account
// enrols. A discoverable credential returns it in each assertion, so sign-in
// needs no identifier; the credential row is looked up by its id and the
// handle is a tripwire that must name the same account.
//
// # What a passkey proves
//
// Possession of a key the authenticator holds, unlocked by its owner (UV). It
// proves nothing about the writer keys: a session, however it was obtained,
// never enrols a writer or changes an authenticator on its own (spec 02 §8).

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

// CeremonyTTL is how long a begun ceremony may be finished within.
//
// Five minutes, matching Writers.Challenge and the address-rotation challenge,
// because it bounds the same thing: how long a server-minted challenge stays
// spendable. It is generous enough for a user who has to fetch a security key
// from a drawer and short enough that an abandoned ceremony is not a row that
// lingers.
const CeremonyTTL = 5 * time.Minute

// userHandleBytes is the entropy in a user handle. 32 bytes is well inside
// WebAuthn's 64-byte cap and is the whole of what identifies an account: an
// attacker who could guess one could address somebody else's row.
const userHandleBytes = 32

// ceremonyIDBytes is the entropy in a ceremony id. It is not a credential — the
// challenge inside the ceremony is what authorizes anything — but it is a handle
// to server-side state reachable by an unauthenticated caller, so it is
// unguessable rather than sequential.
const ceremonyIDBytes = 32

// Rejection reasons. Everything except ErrNotInvited (which passes through from
// invite.go unchanged) wraps ErrPasskeyRejected, so a caller that only wants
// "did this ceremony establish anything" writes one errors.Is.
//
// The HTTP layer must answer ALL of them with an identical 401 apart from
// ErrNotInvited, which is a fact about this deployment's policy rather than about
// the credential — the same single carve-out the ID-token exchange makes.
var (
	// ErrPasskeyRejected is the umbrella: the ceremony did not establish an
	// identity.
	ErrPasskeyRejected = errors.New("auth: passkey ceremony rejected")

	// ErrCeremonyUnknown means there is no live ceremony under that id: never
	// existed, already spent, expired, or begun as a different kind. One error
	// for all four, because telling them apart is an oracle.
	ErrCeremonyUnknown = fmt.Errorf("%w: no such ceremony", ErrPasskeyRejected)

	// ErrCredentialUnknown means the assertion named a credential this
	// deployment has never enrolled.
	ErrCredentialUnknown = fmt.Errorf("%w: unknown credential", ErrPasskeyRejected)

	// ErrClonedAuthenticator means the signature counter did not increase.
	// Per §6.1.1 that is evidence that at least two copies of the private key
	// exist, or that the authenticator is malfunctioning. Neither is a sign-in.
	//
	// Note what this is NOT: a counter that stays at zero. Platform
	// authenticators (iCloud Keychain among them) report a permanent zero
	// precisely because the credential IS synced and a counter would be
	// meaningless; go-webauthn's UpdateCounter excludes that case, and so does
	// this.
	ErrClonedAuthenticator = fmt.Errorf("%w: signature counter did not increase", ErrPasskeyRejected)

	// ErrNoPasskeyIdentity means an add-a-passkey ceremony was asked for by an
	// account that has no user handle to bind one to. See beginAdd.
	ErrNoPasskeyIdentity = fmt.Errorf("%w: this account has no passkey identity", ErrPasskeyRejected)

	// ErrBadAuthorityKey is a register/begin whose authority_pubkey is not a
	// usable Ed25519 key. It is a malformed request (400), not a rejection.
	ErrBadAuthorityKey = errors.New("auth: passkey: authority_pubkey is not a usable Ed25519 key")
)

// Passkeys runs the three WebAuthn ceremonies and owns their server-side state.
//
// One instance per process, built by api.NewServer from the [auth] config. It is
// safe for concurrent use: it holds no per-ceremony state in memory at all — that
// is what the webauthn_ceremonies table is for.
type Passkeys struct {
	Pool *pgxpool.Pool
	// WA is go-webauthn's relying party. All cryptography, all of §7's
	// verification steps, and the whole attestation surface are its, not this
	// package's — the same division of labour idp.go draws with go-oidc, and for
	// the same reason: this is the one code path where a hand-rolled mistake is
	// an authentication bypass.
	WA *webauthn.WebAuthn
	// StepUp verifies the passkey.add and passkey.delete step-ups (spec 02
	// #10, #13). Nil refuses those routes; api.NewServer wires it.
	StepUp *StepUp
	// Mail receives the new-passkey alert; nil records events without mail.
	Mail *Mailer
	// Now defaults to time.Now. Ceremony expiry is evaluated against THIS clock
	// and never against Postgres's, so one clock decides both when a ceremony
	// was minted and when it dies (see 00022's note on the two-clock defect).
	Now    func() time.Time
	Record func(purgeledger.Entry)
}

func (p *Passkeys) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}

// RPID is the relying-party id these credentials were registered under — the
// PARENT domain (e.g. "example.com"), not the origin the app is served from
// (app.example.com). A ceremony that hand-builds its own assertion options, rather
// than taking them from a begin-endpoint, MUST pass this: without it the browser
// defaults rpId to the current origin, finds no credential registered there, and
// offers to CREATE one instead of asserting with an existing passkey. Account
// deletion hit exactly that. See internal/api/account.go.
func (p *Passkeys) RPID() string {
	return p.WA.Config.RPID
}

// NewPasskeys builds the relying party from config.
//
// It returns an error rather than a Passkeys that rejects everything, which is
// the opposite of NewOIDCVerifier's choice and deliberately so: an OIDC verifier
// with no client ids is a deployment that cannot verify Apple tokens, and the safe
// answer is "nobody signs in". A relying party with no RP id or no origin cannot
// be constructed at all — go-webauthn refuses it — and a nil Passkeys means
// api.Handler does not MOUNT the routes, which is the same failure stated at
// startup instead of at the first sign-in.
func NewPasskeys(pool *pgxpool.Pool, rpID, rpDisplayName string, origins []string) (*Passkeys, error) {
	if pool == nil {
		return nil, errors.New("auth: NewPasskeys: pool is nil")
	}
	if rpID == "" {
		return nil, errors.New("auth: NewPasskeys: rp_id is empty")
	}
	var clean []string
	for _, o := range origins {
		if o != "" {
			clean = append(clean, o)
		}
	}
	if len(clean) == 0 {
		// Not a nicety. The origin is what binds a ceremony to THIS site; with
		// none configured there is nothing to compare the client data against,
		// and go-webauthn would have to either refuse everything or accept
		// anything. It refuses, and saying so here names the missing key.
		return nil, errors.New("auth: NewPasskeys: auth.rp_origins is empty; " +
			"a ceremony cannot be bound to an origin that is not configured")
	}
	if rpDisplayName == "" {
		rpDisplayName = rpID
	}
	wa, err := webauthn.New(&webauthn.Config{
		RPID:          rpID,
		RPDisplayName: rpDisplayName,
		RPOrigins:     clean,
		AuthenticatorSelection: protocol.AuthenticatorSelection{
			// Required, because it is the mechanism rather than a preference:
			// only a discoverable credential returns the user handle in its
			// assertion, and without the handle there is no username-less
			// sign-in — the page would have to ask who you are first.
			ResidentKey: protocol.ResidentKeyRequirementRequired,
			// Required in every ceremony: registration, login, step-up and
			// recovery (spec 01 §10.2, spec 02 §8.1; replaces ledgerd's
			// VerificationPreferred, W15). A step-up's whole claim is that the
			// user approved this action with Face ID or the passcode.
			UserVerification: protocol.VerificationRequired,
		},
		// No attestation. The RP has no use for a signed statement of which
		// authenticator model was used — it enforces no allow-list of models —
		// and asking for one adds a privacy-relevant identifier to every
		// registration plus a browser consent prompt that says nothing useful.
		AttestationPreference: protocol.PreferNoAttestation,
	})
	if err != nil {
		return nil, fmt.Errorf("auth: NewPasskeys: %w", err)
	}
	return &Passkeys{Pool: pool, WA: wa}, nil
}

// ---------------------------------------------------------------------------
// The webauthn.User this package presents to the library
// ---------------------------------------------------------------------------

// passkeyUser is the library's view of an account. It carries NO personal data,
// and that is a requirement rather than an omission: v2 stores none, and
// WebAuthnName/WebAuthnDisplayName travel to the authenticator and are shown in
// the platform's passkey picker.
//
// The name is just the relying party's own name — no per-account suffix. It is
// not an email, not a username, and there is no field on `users` it could have
// come from. Earlier this appended a short prefix of the user handle so two
// accounts on one device would look different in a picker like Keychain; that
// made the RP display name and this name look like the same word twice with
// noise after it (e.g. "Ledger" over "Ledger YHeaynbu"). Dropped: two accounts
// on one device now render identically in Keychain, accepted for a closed
// beta. Login never depends on this string — see WebAuthnID.
type passkeyUser struct {
	handle      []byte
	credentials []webauthn.Credential
	rpName      string
}

// WebAuthnID is the actual identity: 32 random bytes minted once at
// registration (see BeginRegistration) and never derived from, or influenced
// by, WebAuthnName/WebAuthnDisplayName. Discoverable login resolves entirely
// off this handle (BeginDiscoverableLogin, handleSubject) — the display name
// is cosmetic and is never read back from an assertion.
func (u passkeyUser) WebAuthnID() []byte { return u.handle }

func (u passkeyUser) WebAuthnName() string { return u.rpName }

func (u passkeyUser) WebAuthnDisplayName() string { return u.rpName }

func (u passkeyUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

// passkeyUserName is user.name and user.displayName in every registration:
// never the address (spec 02 §10.7.2), so the passkey sheet shows "Hasala".
const passkeyUserName = "Hasala"

// ---------------------------------------------------------------------------
// Registration: a new account (C1, spec 02 §10.7.2)
// ---------------------------------------------------------------------------

// BeginRegistration is register/begin (#3): the signup must be verified or
// proven, unexpired and unclaimed (else ErrCodeRejected); a proven address
// already in use is ErrEmailInUse. The ceremony binds the AAK public key:
// C_reg = SHA256("hasala/v1/register" ‖ 00 ‖ nonce ‖ authority_pubkey) is the
// WebAuthn challenge. It answers the ceremony id, the options and the nonce.
func (p *Passkeys) BeginRegistration(ctx context.Context, signupID string, authorityPub []byte) (string, *protocol.CredentialCreation, []byte, error) {
	if p.Pool == nil || p.WA == nil {
		return "", nil, nil, errors.New("auth: Passkeys is not configured")
	}
	if err := keyproto.CheckEd25519PublicKey(authorityPub); err != nil {
		return "", nil, nil, fmt.Errorf("%w: %v", ErrBadAuthorityKey, err)
	}
	s, err := readySignup(ctx, p.Pool, signupID, p.now())
	if err != nil {
		return "", nil, nil, err
	}
	if err := addressFree(ctx, p.Pool, s); err != nil {
		return "", nil, nil, err
	}
	handle, err := randBytes(userHandleBytes)
	if err != nil {
		return "", nil, nil, err
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return "", nil, nil, err
	}
	creg, err := keyproto.RegisterChallenge(nonce, authorityPub)
	if err != nil {
		return "", nil, nil, err
	}
	user := passkeyUser{handle: handle, rpName: passkeyUserName}
	opts, session, err := p.WA.BeginRegistration(user, func(o *protocol.PublicKeyCredentialCreationOptions) {
		o.Challenge = protocol.URLEncodedBase64(creg[:])
	})
	if err != nil {
		return "", nil, nil, fmt.Errorf("auth: passkey: begin registration: %w", err)
	}
	id, err := newCeremonyIDN(ceremonyIDBytes)
	if err != nil {
		return "", nil, nil, err
	}
	if err := p.putCeremony(ctx, ceremony{
		ID: id, Kind: ceremonyRegister, UserHandle: handle, Session: *session, SignupID: signupID,
		AuthorityPubkey: authorityPub, RegisterNonce: nonce,
	}); err != nil {
		return "", nil, nil, err
	}
	return id, opts, nonce, nil
}

// Registered is what register/finish creates.
type Registered struct {
	UserID       uuid.UUID
	CredentialID []byte
	Session      Minted // zero when no Sessions was given
}

// FinishRegistration is register/finish without a session (fixtures).
func (p *Passkeys) FinishRegistration(ctx context.Context, ceremonyID string, response []byte) (uuid.UUID, []byte, error) {
	r, err := p.FinishRegistrationSession(ctx, ceremonyID, response, nil)
	return r.UserID, r.CredentialID, err
}

// FinishRegistrationSession is register/finish (#4): the attestation (UV,
// C_reg, origin) is verified, then ONE transaction claims the signup and
// creates the account under the reserved id, the credential with its
// attestation hash, the invite redemption and the join hook, the pending
// authority key, and (with sessions) the register session.
func (p *Passkeys) FinishRegistrationSession(ctx context.Context, ceremonyID string, response []byte, sessions *Sessions) (Registered, error) {
	if p.Pool == nil || p.WA == nil {
		return Registered{}, errors.New("auth: Passkeys is not configured")
	}
	c, err := p.claimCeremony(ctx, ceremonyID, ceremonyRegister)
	if err != nil {
		return Registered{}, err
	}
	user := passkeyUser{handle: c.UserHandle, rpName: passkeyUserName}
	made, err := p.createCredential(user, c, response)
	if err != nil {
		return Registered{}, err
	}
	now := p.now()
	tx, err := pgtx.BeginReadCommitted(ctx, p.Pool)
	if err != nil {
		return Registered{}, fmt.Errorf("auth: register: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	s, err := claimSignupTx(ctx, tx, c.SignupID, now)
	if err != nil {
		return Registered{}, err
	}
	if err := createAccountTx(ctx, tx, s, c.UserHandle, now); err != nil {
		return Registered{}, err
	}
	if err := insertCredential(ctx, tx, storedCredential{UserID: s.UserID, UserHandle: c.UserHandle,
		Credential: *made.Credential, AttestationSHA256: made.AttestationSHA256}, now); err != nil {
		return Registered{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET authority_pubkey_pending = $2 WHERE id = $1`, s.UserID, c.AuthorityPubkey); err != nil {
		return Registered{}, fmt.Errorf("auth: register: record the pending authority key: %w", err)
	}
	out := Registered{UserID: s.UserID, CredentialID: made.Credential.ID}
	if sessions != nil {
		if out.Session, err = sessions.IssueTx(ctx, tx, Mint{UserID: s.UserID, MintedBy: MintedRegister,
			CredentialID: made.Credential.ID}); err != nil {
			return Registered{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Registered{}, fmt.Errorf("auth: register: commit: %w", err)
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Login: an existing account, named by nobody
// ---------------------------------------------------------------------------

// BeginLogin is login/begin (#5): a discoverable-credential assertion, no
// account named.
func (p *Passkeys) BeginLogin(ctx context.Context) (string, *protocol.CredentialAssertion, error) {
	if p.Pool == nil || p.WA == nil {
		return "", nil, errors.New("auth: Passkeys is not configured")
	}
	opts, session, err := p.WA.BeginDiscoverableLogin()
	if err != nil {
		return "", nil, fmt.Errorf("auth: passkey: begin login: %w", err)
	}
	id, err := newCeremonyIDN(ceremonyIDBytes)
	if err != nil {
		return "", nil, err
	}
	if err := p.putCeremony(ctx, ceremony{ID: id, Kind: ceremonyLogin, Session: *session}); err != nil {
		return "", nil, err
	}
	return id, opts, nil
}

// LoginResult is a verified passkey sign-in.
type LoginResult struct {
	UserID       uuid.UUID
	CredentialID []byte
	// Challenge is the ceremony's 32 raw challenge bytes, which a
	// SessionBindMessage signs (spec 02 §9.4).
	Challenge []byte
}

// FinishLogin is FinishLoginResult's two-value form.
func (p *Passkeys) FinishLogin(ctx context.Context, ceremonyID string, response []byte) (uuid.UUID, []byte, error) {
	r, err := p.FinishLoginResult(ctx, ceremonyID, response)
	return r.UserID, r.CredentialID, err
}

// FinishLoginResult verifies login/finish's assertion (UV required, clone
// refused) and resolves the account from the database by the credential id,
// cross-checked against the handle. It mints no session.
func (p *Passkeys) FinishLoginResult(ctx context.Context, ceremonyID string, response []byte) (LoginResult, error) {
	if p.Pool == nil || p.WA == nil {
		return LoginResult{}, errors.New("auth: Passkeys is not configured")
	}
	c, err := p.claimCeremony(ctx, ceremonyID, ceremonyLogin)
	if err != nil {
		return LoginResult{}, err
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(response)
	if err != nil {
		return LoginResult{}, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	var stored storedCredential
	handler := func(rawID, userHandle []byte) (webauthn.User, error) {
		sc, err := p.credentialByID(ctx, p.Pool, rawID)
		if err != nil {
			return nil, err
		}
		stored = sc
		return passkeyUser{handle: sc.UserHandle, credentials: []webauthn.Credential{sc.Credential}, rpName: passkeyUserName}, nil
	}
	cred, err := p.WA.ValidateDiscoverableLogin(handler, c.Session, parsed)
	if err != nil {
		if errors.Is(err, ErrCredentialUnknown) {
			return LoginResult{}, ErrCredentialUnknown
		}
		return LoginResult{}, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	if !parsed.Response.AuthenticatorData.Flags.HasUserVerified() {
		return LoginResult{}, fmt.Errorf("%w: user verification flag is clear", ErrPasskeyRejected)
	}
	if cred.Authenticator.CloneWarning {
		return LoginResult{}, ErrClonedAuthenticator
	}
	byHandle, err := p.userIDForHandle(ctx, p.Pool, stored.UserHandle)
	if err != nil {
		return LoginResult{}, err
	}
	if byHandle != stored.UserID {
		return LoginResult{}, fmt.Errorf("%w: credential owner and user handle disagree", ErrPasskeyRejected)
	}
	if err := p.touchCredential(ctx, p.Pool, cred.ID, cred.Authenticator.SignCount, p.now().UTC()); err != nil {
		return LoginResult{}, err
	}
	challenge, err := base64.RawURLEncoding.DecodeString(c.Session.Challenge)
	if err != nil || len(challenge) != keyproto.NonceSize {
		return LoginResult{}, fmt.Errorf("auth: passkey: the login challenge is not 32 bytes")
	}
	return LoginResult{UserID: stored.UserID, CredentialID: cred.ID, Challenge: challenge}, nil
}

// ---------------------------------------------------------------------------
// Add: a second passkey for an account that already exists
// ---------------------------------------------------------------------------

// beginAdd mints a registration challenge for an account that is ALREADY
// signed in, so a user can enrol another passkey, and reads the account's
// credentials and records the ceremony through q with addNonce, the
// passkey.add step-up nonce the add/finish signature binds (spec 01 §10.7).
// Only AddBegin (passkey_guarded.go) reaches it from a request, inside that
// step-up's transaction, which it never steps outside.
//
// It reuses the account's existing handle rather than minting a new one, and that
// is not an optimisation: the handle IS the subject, so a second handle would
// hash to a second `users` row and the new credential would sign into a different,
// empty account. An account with no handle to reuse is refused with
// ErrNoPasskeyIdentity rather than silently given a passkey identity it did not
// have, which would be account linking.
//
// Existing credentials are sent as exclusions, so an authenticator that is already
// enrolled says so in the browser instead of minting a duplicate row.
func (p *Passkeys) beginAdd(ctx context.Context, q dbtx, userID uuid.UUID, addNonce []byte) (string, *protocol.CredentialCreation, error) {
	if p.Pool == nil || p.WA == nil {
		return "", nil, errors.New("auth: Passkeys is not configured")
	}
	if userID == uuid.Nil {
		return "", nil, errors.New("auth: passkey: beginAdd: user id is zero")
	}
	if len(addNonce) != keyproto.NonceSize {
		return "", nil, errors.New("auth: passkey: beginAdd: the add nonce is not 32 bytes")
	}
	creds, handle, err := p.credentialsForUser(ctx, q, userID)
	if err != nil {
		return "", nil, err
	}
	if len(handle) == 0 {
		return "", nil, ErrNoPasskeyIdentity
	}
	user := passkeyUser{handle: handle, credentials: creds, rpName: passkeyUserName}
	opts, session, err := p.WA.BeginRegistration(user,
		webauthn.WithExclusions(webauthn.Credentials(creds).CredentialDescriptors()))
	if err != nil {
		return "", nil, fmt.Errorf("auth: passkey: begin add: %w", err)
	}
	id, err := newCeremonyIDN(ceremonyIDBytes)
	if err != nil {
		return "", nil, err
	}
	if err := p.putCeremonyOn(ctx, q, ceremony{
		ID: id, Kind: ceremonyAdd, UserID: &userID, UserHandle: handle, Session: *session, AddNonce: addNonce,
	}); err != nil {
		return "", nil, err
	}
	return id, opts, nil
}

// verifyAdd claims an add ceremony and verifies the new credential's
// attestation (UV, the ceremony's challenge, origin). It stores nothing:
// AddFinish checks the DWK signature and then stores.
//
// userID comes from the SESSION on the request, and it is checked against the
// account the ceremony's handle names. Both are required: without the session
// check anyone holding a ceremony id could complete somebody else's enrolment,
// and without the handle check a session could finish a ceremony begun for a
// different account and bolt a credential onto it.
func (p *Passkeys) verifyAdd(ctx context.Context, ceremonyID string, userID uuid.UUID, response []byte) (created, ceremony, error) {
	if p.Pool == nil || p.WA == nil {
		return created{}, ceremony{}, errors.New("auth: Passkeys is not configured")
	}
	c, err := p.claimCeremony(ctx, ceremonyID, ceremonyAdd)
	if err != nil {
		return created{}, ceremony{}, err
	}
	// Checked twice, against two independently derived answers: the column the
	// ceremony was written with, and the account SubjectHash says the handle
	// names. Agreement is a real check rather than a restatement — a row where
	// they disagree was written by something that did not go through this file.
	owner, err := p.userIDForHandle(ctx, p.Pool, c.UserHandle)
	if err != nil {
		return created{}, ceremony{}, err
	}
	if owner != userID || c.UserID == nil || *c.UserID != userID {
		return created{}, ceremony{}, fmt.Errorf("%w: this ceremony belongs to a different account", ErrPasskeyRejected)
	}
	user := passkeyUser{handle: c.UserHandle, rpName: passkeyUserName}
	made, err := p.createCredential(user, c, response)
	if err != nil {
		return created{}, ceremony{}, err
	}
	return made, c, nil
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

// created is a verified new credential and the raw response bytes the
// signatures over it name (spec 01 §10.3.1, §10.7: the SHA-256 of each).
type created struct {
	Credential        *webauthn.Credential
	ClientDataJSON    []byte
	AttestationObject []byte
	AttestationSHA256 []byte
}

// createCredential is the verification both registration ceremonies share.
func (p *Passkeys) createCredential(user passkeyUser, c ceremony, response []byte) (created, error) {
	parsed, err := protocol.ParseCredentialCreationResponseBytes(response)
	if err != nil {
		return created{}, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	cred, err := p.WA.CreateCredential(user, c.Session, parsed)
	if err != nil {
		return created{}, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	if !parsed.Response.AttestationObject.AuthData.Flags.HasUserVerified() {
		return created{}, fmt.Errorf("%w: user verification flag is clear", ErrPasskeyRejected)
	}
	att := []byte(parsed.Raw.AttestationResponse.AttestationObject)
	return created{Credential: cred, ClientDataJSON: []byte(parsed.Raw.AttestationResponse.ClientDataJSON),
		AttestationObject: att, AttestationSHA256: AttestationHash(att)}, nil
}
