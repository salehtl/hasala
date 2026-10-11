package auth

// Storage for passkey.go: the two tables 00025_passkeys.sql adds, and nothing
// else. It is a separate file for the same reason the SQL is a separate
// migration — the WebAuthn ceremony logic is intricate enough without the
// queries inlined through it, and every statement that touches a credential or a
// ceremony being in one place is what makes "is this single use?" answerable by
// reading rather than by grepping.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ceremonyKind is the closed vocabulary the CHECK constraint on
// webauthn_ceremonies.kind enforces. A ceremony is bound to its kind at mint
// time and claimed by kind at finish, so a registration ceremony can never be
// spent as a login: the two carry different authority (one creates an account)
// and a shared handle would be the way to launder that difference.
type ceremonyKind string

const (
	ceremonyRegister ceremonyKind = "register"
	ceremonyLogin    ceremonyKind = "login"
	ceremonyAdd      ceremonyKind = "add"
)

// ceremony is one row of webauthn_ceremonies, as read back by claimCeremony.
type ceremony struct {
	ID         string
	Kind       ceremonyKind
	UserID     *uuid.UUID
	UserHandle []byte
	Session    webauthn.SessionData
	SignupID   string
	// AuthorityPubkey and RegisterNonce bind a registration ceremony to the
	// account's authority key: its challenge is C_reg = SHA256(
	// "hasala/v1/register" ‖ 00 ‖ register_nonce ‖ authority_pubkey) (spec 01
	// §10.3, D01). Set for kind register only (the CHECK enforces it).
	AuthorityPubkey []byte
	RegisterNonce   []byte
	// AddNonce binds an add ceremony to the passkey.add step-up that opened
	// it: PasskeyAddMessage at add/finish signs this nonce (spec 01 §10.7,
	// D33). Set for kind add only (the CHECK enforces it).
	AddNonce    []byte
	ExpiresAt   time.Time
	sessionJSON []byte
}

// putCeremony records a ceremony that has just begun, on the pool.
func (p *Passkeys) putCeremony(ctx context.Context, c ceremony) error {
	return p.putCeremonyOn(ctx, p.Pool, c)
}

// putCeremonyOn records a ceremony through q: add/begin writes it inside the
// passkey.add step-up's transaction, so the nonce is spent exactly when the
// ceremony exists.
func (p *Passkeys) putCeremonyOn(ctx context.Context, q execer, c ceremony) error {
	raw, err := json.Marshal(c.Session)
	if err != nil {
		return fmt.Errorf("auth: passkey: marshal session data: %w", err)
	}
	now := p.now()
	var handle, signup, authority, regNonce, addNonce any
	if len(c.UserHandle) > 0 {
		handle = c.UserHandle
	}
	if c.SignupID != "" {
		signup = c.SignupID
	}
	if len(c.AuthorityPubkey) > 0 {
		authority, regNonce = c.AuthorityPubkey, c.RegisterNonce
	}
	if len(c.AddNonce) > 0 {
		addNonce = c.AddNonce
	}
	if _, err := q.Exec(ctx,
		`INSERT INTO webauthn_ceremonies (id, kind, user_id, user_handle, session_data, signup_id,
		   authority_pubkey, register_nonce, add_nonce, created_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		c.ID, string(c.Kind), c.UserID, handle, raw, signup, authority, regNonce, addNonce, now, now.Add(CeremonyTTL)); err != nil {
		return fmt.Errorf("auth: passkey: record ceremony: %w", err)
	}
	return nil
}

// claimCeremony consumes a ceremony: it is read and DELETED in one statement, so
// a replay of the same id finds nothing.
//
// The delete is the claim, not a cleanup that follows one. A read-then-delete
// would leave a window in which two concurrent finishes both see the row, and
// the whole point of the challenge inside it is that it is spendable once.
//
// Expiry is evaluated in Go against p.now() rather than in the WHERE clause
// against Postgres's now(), because expires_at was written from p.now() too —
// two clocks deciding one fact is the defect 00022 exists to record. A row that
// is claimed and found expired stays deleted: it was single-use and it has now
// been used, which is the right outcome for a caller who took too long.
func (p *Passkeys) claimCeremony(ctx context.Context, id string, kind ceremonyKind) (ceremony, error) {
	if id == "" {
		return ceremony{}, ErrCeremonyUnknown
	}
	var (
		c        ceremony
		signupID *string
	)
	err := p.Pool.QueryRow(ctx,
		`DELETE FROM webauthn_ceremonies WHERE id = $1 AND kind = $2
		 RETURNING id, kind, user_id, user_handle, session_data, signup_id, authority_pubkey, register_nonce,
		           add_nonce, expires_at`,
		id, string(kind)).Scan(&c.ID, &c.Kind, &c.UserID, &c.UserHandle, &c.sessionJSON, &signupID,
		&c.AuthorityPubkey, &c.RegisterNonce, &c.AddNonce, &c.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		// Unknown, already spent, or begun as a different kind. All one answer:
		// which of the three it was is an oracle in a response and is in the
		// operator log instead.
		return ceremony{}, ErrCeremonyUnknown
	}
	if err != nil {
		return ceremony{}, fmt.Errorf("auth: passkey: claim ceremony: %w", err)
	}
	if !c.ExpiresAt.After(p.now()) {
		return ceremony{}, fmt.Errorf("%w: ceremony expired at %s", ErrCeremonyUnknown, c.ExpiresAt.UTC())
	}
	if err := json.Unmarshal(c.sessionJSON, &c.Session); err != nil {
		return ceremony{}, fmt.Errorf("auth: passkey: decode session data: %w", err)
	}
	if signupID != nil {
		c.SignupID = *signupID
	}
	return c, nil
}

// ReapExpiredCeremonies deletes ceremonies past their expiry and reports how
// many it removed.
//
// It is called from cmd/hasalad's sweep loop and NOT from the finish path, on
// the same reasoning as Sessions.ReapDeletedAccountTombstones: a sweep on a path
// an unauthenticated caller can reach is a way to make this server write. The
// bound is p.now(), the clock claimCeremony compares against.
func (p *Passkeys) ReapExpiredCeremonies(ctx context.Context) (int64, error) {
	if p.Pool == nil {
		return 0, errors.New("auth: Passkeys.Pool is nil")
	}
	tag, err := p.Pool.Exec(ctx, `DELETE FROM webauthn_ceremonies WHERE expires_at < $1`, p.now())
	if err != nil {
		return 0, fmt.Errorf("auth: passkey: reap ceremonies: %w", err)
	}
	return tag.RowsAffected(), nil
}

// storedCredential is one row of webauthn_credentials, in the shape the
// library's verification needs plus the two facts it does not carry (which
// account owns it, and under which handle).
type storedCredential struct {
	UserID     uuid.UUID
	UserHandle []byte
	Credential webauthn.Credential
	// AttestationSHA256 is SHA-256 of the raw attestationObject posted when the
	// credential was registered (spec 01 §9, R-01): bootstrap's auth_kind 0x01
	// compares it, so a credential a TLS terminator swapped in is visible.
	AttestationSHA256 []byte
}

// credentialByID looks a credential up by the rawId an assertion carried. It is
// the login path's entire "who is this": everything else — the handle, the
// account — hangs off this row.
func (p *Passkeys) credentialByID(ctx context.Context, q querier, credentialID []byte) (storedCredential, error) {
	var (
		sc         storedCredential
		signCount  int64
		aaguid     []byte
		transports *string
		be, bs     bool
	)
	err := q.QueryRow(ctx,
		`SELECT user_id, user_handle, public_key, sign_count, aaguid, transports, backup_eligible, backup_state
		   FROM webauthn_credentials WHERE credential_id = $1`, credentialID).
		Scan(&sc.UserID, &sc.UserHandle, &sc.Credential.PublicKey, &signCount, &aaguid, &transports, &be, &bs)
	if errors.Is(err, pgx.ErrNoRows) {
		return storedCredential{}, ErrCredentialUnknown
	}
	if err != nil {
		return storedCredential{}, fmt.Errorf("auth: passkey: load credential: %w", err)
	}
	sc.Credential.ID = credentialID
	sc.Credential.Authenticator = webauthn.Authenticator{
		AAGUID: aaguid,
		// The column is bigint because Postgres has no unsigned types; the wire
		// value is a uint32 and is stored as-is, so the narrowing is exact.
		SignCount: uint32(signCount),
	}
	sc.Credential.Flags = webauthn.CredentialFlags{BackupEligible: be, BackupState: bs}
	if transports != nil {
		for _, t := range strings.Split(*transports, ",") {
			if t = strings.TrimSpace(t); t != "" {
				sc.Credential.Transport = append(sc.Credential.Transport, protocol.AuthenticatorTransport(t))
			}
		}
	}
	return sc, nil
}

// credentialsForUser is what the add ceremony excludes, so an authenticator that
// is already enrolled says so in the browser rather than minting a duplicate.
func (p *Passkeys) credentialsForUser(ctx context.Context, q dbtx, userID uuid.UUID) ([]webauthn.Credential, []byte, error) {
	var handle []byte
	if err := q.QueryRow(ctx, `SELECT user_handle FROM users WHERE id = $1`, userID).Scan(&handle); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, nil
		}
		return nil, nil, fmt.Errorf("auth: passkey: read user handle: %w", err)
	}
	rows, err := q.Query(ctx,
		`SELECT credential_id FROM webauthn_credentials WHERE user_id = $1 ORDER BY created_at, credential_id`, userID)
	if err != nil {
		return nil, nil, fmt.Errorf("auth: passkey: list credentials: %w", err)
	}
	defer rows.Close()
	var creds []webauthn.Credential
	for rows.Next() {
		var id []byte
		if err := rows.Scan(&id); err != nil {
			return nil, nil, fmt.Errorf("auth: passkey: list credentials: %w", err)
		}
		creds = append(creds, webauthn.Credential{ID: id})
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("auth: passkey: list credentials: %w", err)
	}
	return creds, handle, nil
}

// dbtx is what both *pgxpool.Pool and pgx.Tx offer. A helper that reads or
// writes on behalf of a caller holding a transaction takes one, so the caller
// passes its transaction: a helper that went to the pool instead would hold a
// second connection while the first waits on it, and enough concurrent
// requests exhaust the pool (each holds one connection and waits for a
// second).
type dbtx interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// execer is satisfied by both *pgxpool.Pool and pgx.Tx, which is what lets the
// registration path (a statement inside the account's own transaction) and the
// add path (one statement on its own) share a single insert.
type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// insertCredential stores a freshly created credential.
//
// On the registration path the execer is the pgx.Tx that also creates the
// account and spends the invite, so an account is never
// committed without the credential that is the only way to sign into it — and,
// just as importantly, a failure here rolls the invite redemption back rather
// than burning the code. On the add path it is the pool, because there is
// nothing else in that statement's fate to share.
func insertCredential(ctx context.Context, q execer, sc storedCredential, now time.Time) error {
	var transports any
	if ts := transportsString(sc.Credential.Transport); ts != "" {
		transports = ts
	}
	var aaguid any
	if len(sc.Credential.Authenticator.AAGUID) > 0 {
		aaguid = sc.Credential.Authenticator.AAGUID
	}
	_, err := q.Exec(ctx,
		`INSERT INTO webauthn_credentials
		   (credential_id, user_id, user_handle, public_key, sign_count, aaguid, transports,
		    backup_eligible, backup_state, attestation_sha256, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		sc.Credential.ID, sc.UserID, sc.UserHandle, sc.Credential.PublicKey,
		int64(sc.Credential.Authenticator.SignCount), aaguid, transports,
		sc.Credential.Flags.BackupEligible, sc.Credential.Flags.BackupState, sc.AttestationSHA256, now)
	if err != nil {
		return fmt.Errorf("auth: passkey: store credential: %w", err)
	}
	return nil
}

func transportsString(ts []protocol.AuthenticatorTransport) string {
	if len(ts) == 0 {
		return ""
	}
	out := make([]string, 0, len(ts))
	for _, t := range ts {
		if s := strings.TrimSpace(string(t)); s != "" {
			out = append(out, s)
		}
	}
	return strings.Join(out, ",")
}

// touchCredential records a successful assertion: the new signature counter and
// when it was last used.
//
// The counter is guarded in SQL as well as in Go. The Go check (CloneWarning) is
// the one that REFUSES a clone; GREATEST here is belt, and it is what keeps two
// concurrent sign-ins from committing the lower of two counters.
//
// GREATEST rather than a `WHERE sign_count < $2` predicate, which is what this
// was and was wrong for the COMMON case: an authenticator that reports a
// permanent zero — iCloud Keychain and every other synced passkey provider, i.e.
// most users — never satisfies it, so the whole UPDATE matched no row and
// last_used_at stayed NULL for ever. Splitting the two facts is the fix: the
// counter must never go backwards, and "this credential was used just now" is
// true regardless of what the counter says.
func (p *Passkeys) touchCredential(ctx context.Context, q execer, credentialID []byte, signCount uint32, now time.Time) error {
	if _, err := q.Exec(ctx,
		`UPDATE webauthn_credentials
		    SET sign_count = GREATEST(sign_count, $2), last_used_at = $3
		  WHERE credential_id = $1`,
		credentialID, int64(signCount), now); err != nil {
		return fmt.Errorf("auth: passkey: update credential: %w", err)
	}
	return nil
}

// userIDForHandle resolves a user handle to the account it names, WITHOUT
// creating anything.
//
// users.user_handle is UNIQUE, so a handle names at most one account.
func (p *Passkeys) userIDForHandle(ctx context.Context, q querier, handle []byte) (uuid.UUID, error) {
	var id uuid.UUID
	err := q.QueryRow(ctx,
		`SELECT id FROM users WHERE user_handle = $1`, handle).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, ErrCredentialUnknown
	}
	if err != nil {
		return uuid.Nil, fmt.Errorf("auth: passkey: resolve user handle: %w", err)
	}
	return id, nil
}
