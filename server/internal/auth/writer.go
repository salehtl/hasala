package auth

// Writers: registration, revocation, the roster and the key-history log
// (spec 01 §4.8, §10.5, §10.6, §10.13; spec 02 §9.4, §9.5, §10.2).
//
// # Who may enrol a writer
//
// Only the account's authority key (AAK). A RegistrationMessage
//
//	"hasala/v1/writer-registration" ‖ 00 ‖ nonce32 ‖ 00 ‖ writer_id ‖ 00 ‖ dwk_pub32 ‖ dak_pub65
//
// signed by the AAK over a server-issued, single-use nonce certifies both
// device keys: the DWK (Ed25519, signs batch heads, revocations and bindings)
// and the DAK (Secure Enclave P-256, approves step-ups). The AAK exists only in
// memory after account creation, a PRF unlock or the phrase, so a stolen
// session cannot produce one, and there is no step-up, no device authorizer,
// no trust-on-first-use and no recovery-key branch (spec 01 DEV-3; ledgerd's
// TOFU bootstrap and recovery authorizer are gone). The first writer is
// registered by the bootstrap (accountkeys.go) with the same message.
//
// # Who may revoke one
//
// Any live writer of the account (the target included), by a DWK signature
// over a RevocationMessage that pins the target's final head
//
//	"hasala/v1/writer-revocation" ‖ 00 ‖ nonce32 ‖ 00 ‖ writer_id ‖ 00 ‖ u64be(final_counter) ‖ final_head32
//
// plus step-up writer.revoke. The server requires the pinned head to be the
// target's current head, under the target's row lock that uploads share, so no
// row can land between the check and the revocation (R-02); readers then accept
// none of the revoked writer's rows past that head.
//
// # key_history
//
// Every row carries the signature that authorized it and the nonce it was
// over, so a device verifies the log itself instead of trusting the server's
// account of it (spec 01 §10.13): registrations under the AAK, revocations
// under a writer that was live at that point. The table is append-only by
// trigger, and the runtime role holds no UPDATE or DELETE on it; the owner
// (hasala_migrate) could disable the trigger, which is why hasalad never
// serves as the owner (spec 02 §5.6).

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

// AlgEd25519 is the only writers.alg (spec 01 §4.8: 0x01; 0x02 is reserved).
const AlgEd25519 = "ed25519"

// key_history vocabulary, matching its CHECKs.
const (
	EventRegistered     = "registered"
	EventRevoked        = "revoked"
	AuthorizedAuthority = "authority"
	AuthorizedDevice    = "device"
)

const (
	// ChallengeNonceBytes is the writer-challenge nonce (32 bytes).
	ChallengeNonceBytes = keyproto.NonceSize
	// ChallengeTTL bounds how long a captured challenge is worth anything.
	ChallengeTTL = 5 * time.Minute
	// MaxLiveWriters is spec 01 §10.5's cap.
	MaxLiveWriters = 20
	// challengeRetention is how long a spent challenge is kept before the
	// opportunistic sweep removes it; what refuses a replay is used_at.
	challengeRetention = 24 * time.Hour
)

// Writer errors. The HTTP layer maps each to spec 02 §6.3's code; the reason
// inside is for the operator log.
var (
	ErrKeysRequired       = errors.New("auth: the account has no keys yet")                           // 403 keys_required
	ErrBadWriterID        = errors.New("auth: writer id does not match the §4.8 grammar")             // 400 bad_writer_id
	ErrWriterMalformed    = errors.New("auth: writer request is malformed")                           // 400 bad_request
	ErrBadSignature       = errors.New("auth: signature or nonce did not verify")                     // 400 bad_signature
	ErrTooManyDevices     = errors.New("auth: the account has the maximum of live writers")           // 409 too_many_devices
	ErrHeadMoved          = errors.New("auth: the target's head is not the pinned one")               // 409 head_moved
	ErrNoSuchWriter       = errors.New("auth: no such writer")                                        // 404 not_found
	ErrWriterRevoked      = errors.New("auth: the writer is revoked")                                 // 403 writer_revoked
	ErrDeviceOtherAccount = errors.New("auth: the signing-in device is not a writer of this account") // 409 other_account_device
)

// Writer is one row of a user's roster.
type Writer struct {
	UserID       uuid.UUID
	WriterID     string
	Alg          string
	PubKey       []byte // Ed25519 DWK, 32 bytes
	DAKPubkey    []byte // P-256 X9.63, 65 bytes
	RegisteredAt time.Time
	RevokedAt    time.Time // zero while live
}

// Live reports whether the writer may still sign anything.
func (w Writer) Live() bool { return w.RevokedAt.IsZero() }

// Writers owns writer registration, revocation and the key-history log.
type Writers struct {
	Pool *pgxpool.Pool
	// Mail receives the device_removed alert; nil records events without mail.
	Mail *Mailer
	// StepUp verifies the writer.revoke step-up.
	StepUp *StepUp
	// Now defaults to time.Now; one clock decides minting and expiry.
	Now    func() time.Time
	Record func(purgeledger.Entry)
}

func (w *Writers) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now()
}

// Challenge mints a single-use writer-challenge nonce (#23). It serves
// registration, revocation and the bootstrap.
func (w *Writers) Challenge(ctx context.Context, userID uuid.UUID) ([]byte, time.Time, error) {
	if w.Pool == nil {
		return nil, time.Time{}, errors.New("auth: Writers.Pool is nil")
	}
	if userID == uuid.Nil {
		return nil, time.Time{}, errors.New("auth: writer challenge: user id is zero")
	}
	nonce := make([]byte, ChallengeNonceBytes)
	if _, err := rand.Read(nonce); err != nil {
		return nil, time.Time{}, fmt.Errorf("auth: writer challenge: read random: %w", err)
	}
	now := w.now()
	exp := now.Add(ChallengeTTL)
	if _, err := w.Pool.Exec(ctx,
		`INSERT INTO writer_challenges (nonce, user_id, issued_at, expires_at) VALUES ($1,$2,$3,$4)`,
		nonce, userID, now, exp); err != nil {
		return nil, time.Time{}, fmt.Errorf("auth: writer challenge for user %s: %w", userID, err)
	}
	_, _ = w.Pool.Exec(ctx, `DELETE FROM writer_challenges WHERE expires_at < $1`, now.Add(-challengeRetention))
	return nonce, exp, nil
}

// consumeChallenge spends a writer challenge exactly once, OUTSIDE any
// transaction the caller opens: it is spent by the attempt, not the success,
// so one nonce buys one attempt. Unknown, foreign, used and expired nonces are
// all ErrBadSignature (spec 02 §6.3).
func consumeChallenge(ctx context.Context, pool *pgxpool.Pool, now time.Time, userID uuid.UUID, nonce []byte) error {
	if len(nonce) != ChallengeNonceBytes {
		return fmt.Errorf("%w: nonce is %d bytes", ErrBadSignature, len(nonce))
	}
	var expires time.Time
	err := pool.QueryRow(ctx,
		`UPDATE writer_challenges SET used_at = $3
		  WHERE nonce = $1 AND user_id = $2 AND used_at IS NULL
		 RETURNING expires_at`, nonce, userID, now).Scan(&expires)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: unknown, foreign or used writer challenge", ErrBadSignature)
	}
	if err != nil {
		return fmt.Errorf("auth: consume writer challenge: %w", err)
	}
	if !expires.After(now) {
		return fmt.Errorf("%w: writer challenge expired", ErrBadSignature)
	}
	return nil
}

// Registration is POST /api/v1/writers/register's request (spec 02 §10.2),
// decoded.
type Registration struct {
	WriterID  string
	Alg       string
	PubKey    []byte
	DAKPubkey []byte
	Nonce     []byte
	Sig       []byte
}

// checkShape is the stateless half of the registration checks.
func (r Registration) checkShape() error {
	if !keyproto.ValidWriterID(r.WriterID) {
		return ErrBadWriterID
	}
	if r.Alg != AlgEd25519 {
		return fmt.Errorf("%w: alg is not Ed25519", ErrWriterMalformed)
	}
	if err := keyproto.CheckEd25519PublicKey(r.PubKey); err != nil {
		return fmt.Errorf("%w: pubkey: %v", ErrWriterMalformed, err)
	}
	if _, err := keyproto.ParseDAK(r.DAKPubkey); err != nil {
		return fmt.Errorf("%w: dak_pubkey: %v", ErrWriterMalformed, err)
	}
	if len(r.Sig) != keyproto.Ed25519SigSize {
		return fmt.Errorf("%w: sig is %d bytes", ErrBadSignature, len(r.Sig))
	}
	return nil
}

// authorityKey reads account_keys.authority_pubkey; ErrKeysRequired when the
// account has not bootstrapped.
func authorityKey(ctx context.Context, q querier, userID uuid.UUID) ([]byte, error) {
	var k []byte
	err := q.QueryRow(ctx, `SELECT authority_pubkey FROM account_keys WHERE user_id = $1`, userID).Scan(&k)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrKeysRequired
	}
	if err != nil {
		return nil, fmt.Errorf("auth: read authority key: %w", err)
	}
	return k, nil
}

// Register enrols a writer under the AAK (#24, spec 02 §10.2's order) and binds
// the calling, unbound session to it.
func (w *Writers) Register(ctx context.Context, userID uuid.UUID, sessionHash []byte, r Registration) error {
	if w.Pool == nil {
		return errors.New("auth: Writers.Pool is nil")
	}
	aak, err := authorityKey(ctx, w.Pool, userID)
	if err != nil {
		return err
	}
	if err := r.checkShape(); err != nil {
		return err
	}
	// Already enrolled (key, DAK or id): a malformed request, refused before
	// the nonce is spent. The caller holds this account's session and can read
	// the roster anyway, so this discloses nothing.
	var taken bool
	if err := w.Pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM writers WHERE user_id = $1 AND (writer_id = $2 OR pubkey = $3 OR dak_pubkey = $4))`,
		userID, r.WriterID, r.PubKey, r.DAKPubkey).Scan(&taken); err != nil {
		return fmt.Errorf("auth: register writer: %w", err)
	}
	if taken {
		return fmt.Errorf("%w: the writer id, key or DAK is already enrolled", ErrWriterMalformed)
	}
	if err := consumeChallenge(ctx, w.Pool, w.now(), userID, r.Nonce); err != nil {
		return err
	}
	msg, err := keyproto.RegistrationMessage(r.Nonce, r.WriterID, r.PubKey, r.DAKPubkey)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrWriterMalformed, err)
	}
	if !keyproto.VerifyEd25519(aak, msg, r.Sig) {
		return fmt.Errorf("%w: the RegistrationMessage does not verify under the authority key", ErrBadSignature)
	}

	tx, err := pgtx.BeginReadCommitted(ctx, w.Pool)
	if err != nil {
		return fmt.Errorf("auth: register writer: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	if err := lockUser(ctx, tx, userID); err != nil {
		return err
	}
	var live int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM writers WHERE user_id = $1 AND revoked_at IS NULL`, userID).Scan(&live); err != nil {
		return fmt.Errorf("auth: register writer: count: %w", err)
	}
	if live >= MaxLiveWriters {
		return ErrTooManyDevices
	}
	if err := insertWriterTx(ctx, tx, userID, r, w.now()); err != nil {
		return err
	}
	if err := recordEventTx(ctx, tx, w.Mail, userID, AuthEvent{Kind: EventDeviceAdded, WriterID: r.WriterID}, w.now()); err != nil {
		return err
	}
	if err := bindSessionTx(ctx, tx, sessionHash, userID, r.WriterID); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("auth: register writer: commit: %w", err)
	}
	return nil
}

// insertWriterTx inserts the writer and its key_history registration (with
// the AAK's RegistrationMessage signature over its own nonce, spec 01 §9 (a)).
func insertWriterTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, r Registration, now time.Time) error {
	if _, err := tx.Exec(ctx,
		`INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at) VALUES ($1,$2,$3,$4,$5,$6)`,
		userID, r.WriterID, r.Alg, r.PubKey, r.DAKPubkey, now); err != nil {
		var pg *pgconn.PgError
		if errors.As(err, &pg) && pg.Code == "23505" {
			return fmt.Errorf("%w: the writer id, key or DAK is already enrolled", ErrWriterMalformed)
		}
		return fmt.Errorf("auth: insert writer %s: %w", r.WriterID, err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO key_history (user_id, writer_id, alg, pubkey, dak_pubkey, event, authorized_by, nonce, signature, at)
		 VALUES ($1,$2,$3,$4,$5,'registered','authority',$6,$7,$8)`,
		userID, r.WriterID, r.Alg, r.PubKey, r.DAKPubkey, r.Nonce, r.Sig, now); err != nil {
		return fmt.Errorf("auth: append key history (registered %s): %w", r.WriterID, err)
	}
	return nil
}

func lockUser(ctx context.Context, tx pgx.Tx, userID uuid.UUID) error {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: no such user", ErrWriterMalformed)
	}
	if err != nil {
		return fmt.Errorf("auth: lock user %s: %w", userID, err)
	}
	return nil
}

// Revocation is POST /api/v1/writers/revoke's request (spec 02 §9.5), decoded.
type Revocation struct {
	WriterID       string
	SignerWriterID string
	Nonce          []byte
	FinalCounter   int64
	FinalHead      []byte
	Sig            []byte
	StepUp         *StepUpObject
}

// Revoke retires a writer (#25): the writer challenge is spent first; then,
// in one transaction under step-up writer.revoke: the target's row locked FOR
// UPDATE, its current head compared with the pinned one, the RevocationMessage
// verified under a live signer's DWK, the writer revoked, key_history appended,
// its sessions revoked and its APNs token deleted.
func (w *Writers) Revoke(ctx context.Context, userID uuid.UUID, session SessionInfo, r Revocation) error {
	if w.Pool == nil || w.StepUp == nil {
		return errors.New("auth: Writers is not configured")
	}
	if !keyproto.ValidWriterID(r.WriterID) || !keyproto.ValidWriterID(r.SignerWriterID) {
		return ErrBadWriterID
	}
	if r.FinalCounter < 0 || len(r.FinalHead) != keyproto.HashSize || len(r.Sig) != keyproto.Ed25519SigSize {
		return fmt.Errorf("%w: final_counter, final_head or sig is malformed", ErrWriterMalformed)
	}
	if r.StepUp == nil {
		return ErrStepUpRequired
	}
	if err := consumeChallenge(ctx, w.Pool, w.now(), userID, r.Nonce); err != nil {
		return err
	}
	if _, err := keyproto.RevocationMessage(r.Nonce, r.WriterID, uint64(r.FinalCounter), r.FinalHead); err != nil {
		return fmt.Errorf("%w: %v", ErrWriterMalformed, err)
	}
	ph, err := keyproto.ParamsHash(keyproto.ActionWriterRevoke, []byte(r.WriterID))
	if err != nil {
		return err
	}
	g := Guarded{UserID: userID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: keyproto.ActionWriterRevoke, ParamsHash: ph, StepUp: r.StepUp}
	var revokedAt time.Time
	err = w.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		var revoked *time.Time
		err := tx.QueryRow(ctx,
			`SELECT revoked_at FROM writers WHERE user_id = $1 AND writer_id = $2 FOR UPDATE`,
			userID, r.WriterID).Scan(&revoked)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoSuchWriter
		}
		if err != nil {
			return fmt.Errorf("auth: revoke: lock target: %w", err)
		}
		if revoked != nil {
			return ErrWriterRevoked
		}
		counter, head, err := writerHead(ctx, tx, userID, r.WriterID)
		if err != nil {
			return err
		}
		if counter != r.FinalCounter || !bytes.Equal(head, r.FinalHead) {
			// The error is logged: the counter, never the head hash (spec 02 §20).
			return fmt.Errorf("%w: the writer's counter is %d", ErrHeadMoved, counter)
		}
		wr := writerRevocation{UserID: userID, WriterID: r.WriterID, SignerWriterID: r.SignerWriterID,
			FinalCounter: r.FinalCounter, FinalHead: r.FinalHead, Nonce: r.Nonce, Sig: r.Sig}
		if ok, err := wr.verifiesTx(ctx, tx); err != nil || !ok {
			return fmt.Errorf("%w: the RevocationMessage does not verify under a live signer", ErrBadSignature)
		}
		now := w.now()
		so, err := revokeWriterTx(ctx, tx, wr, true, now, now)
		if err != nil {
			return err
		}
		if so.unlinked {
			if err := RecordQuietEventTx(ctx, tx, userID, AuthEvent{Kind: EventMailboxUnlinked,
				WriterID: session.WriterID, CredentialID: p.CredentialID}, now); err != nil {
				return err
			}
		}
		revokedAt = now
		return recordEventTx(ctx, tx, w.Mail, userID, AuthEvent{Kind: EventDeviceRemoved, WriterID: r.WriterID}, now)
	})
	if err != nil {
		return err
	}
	if w.Record != nil {
		w.Record(purgeledger.Entry{ID: userID, At: revokedAt, Kind: purgeledger.KindDevice, Device: &purgeledger.Device{
			WriterID: r.WriterID, SignerWriterID: r.SignerWriterID, FinalCounter: r.FinalCounter,
			FinalHead: r.FinalHead, Nonce: r.Nonce, Sig: r.Sig}})
	}
	return nil
}

type writerRevocation struct {
	UserID         uuid.UUID
	WriterID       string
	SignerWriterID string
	FinalCounter   int64
	FinalHead      []byte
	Nonce          []byte
	Sig            []byte
}

func (r writerRevocation) verifiesTx(ctx context.Context, tx pgx.Tx) (bool, error) {
	var (
		signerKey  []byte
		signerLive bool
	)
	err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		r.UserID, r.SignerWriterID).Scan(&signerKey, &signerLive)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	msg, err := keyproto.RevocationMessage(r.Nonce, r.WriterID, uint64(r.FinalCounter), r.FinalHead)
	if err != nil {
		return false, nil
	}
	return signerLive && keyproto.VerifyEd25519(signerKey, msg, r.Sig), nil
}

type writerSignOut struct {
	changed  bool
	unlinked bool
}

func revokeWriterTx(ctx context.Context, tx pgx.Tx, r writerRevocation, retire bool, at, now time.Time) (writerSignOut, error) {
	var so writerSignOut
	if retire {
		if _, err := tx.Exec(ctx,
			`UPDATE writers SET revoked_at = $3 WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL`,
			r.UserID, r.WriterID, at); err != nil {
			return so, fmt.Errorf("auth: revoke writer %s: %w", r.WriterID, err)
		}
		var pub []byte
		if err := tx.QueryRow(ctx, `SELECT pubkey FROM writers WHERE user_id = $1 AND writer_id = $2`, r.UserID, r.WriterID).Scan(&pub); err != nil {
			return so, fmt.Errorf("auth: revoke: read key: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO key_history (user_id, writer_id, alg, pubkey, event, authorized_by, authorizer_writer_id,
			   final_counter, final_head, nonce, signature, at)
			 VALUES ($1,$2,'ed25519',$3,'revoked','device',$4,$5,$6,$7,$8,$9)`,
			r.UserID, r.WriterID, pub, r.SignerWriterID, r.FinalCounter, r.FinalHead, r.Nonce, r.Sig, at); err != nil {
			return so, fmt.Errorf("auth: append key history (revoked %s): %w", r.WriterID, err)
		}
	}
	tag, err := tx.Exec(ctx,
		`UPDATE sessions SET revoked_at = $3, revoked_reason = 'writer'
		  WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL`,
		r.UserID, r.WriterID, now)
	if err != nil {
		return so, fmt.Errorf("auth: revoke the writer's sessions: %w", err)
	}
	so.changed = tag.RowsAffected() > 0
	tag, err = tx.Exec(ctx, `DELETE FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, r.UserID, r.WriterID)
	if err != nil {
		return so, fmt.Errorf("auth: forget push tokens: %w", err)
	}
	so.changed = so.changed || tag.RowsAffected() > 0
	tag, err = tx.Exec(ctx,
		`DELETE FROM password_reset_ceremonies WHERE user_id = $1 AND approved_by_writer = $2 AND consumed_at IS NULL`,
		r.UserID, r.WriterID)
	if err != nil {
		return so, fmt.Errorf("auth: revoke: drop the writer's pending approvals: %w", err)
	}
	so.changed = so.changed || tag.RowsAffected() > 0
	if so.unlinked, err = dropHeldMailboxLinkTx(ctx, tx, r.UserID, r.WriterID); err != nil {
		return so, err
	}
	return so, nil
}

func dropHeldMailboxLinkTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, writerID string) (bool, error) {
	tag, err := tx.Exec(ctx, `DELETE FROM mailbox_links WHERE user_id = $1 AND holder_writer_id = $2`, userID, writerID)
	if err != nil {
		return false, fmt.Errorf("auth: revoke: drop the writer's mailbox link: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

// writerHead is the target's current (counter, blob_hash), or (0, 0^32).
func writerHead(ctx context.Context, tx pgx.Tx, userID uuid.UUID, writerID string) (int64, []byte, error) {
	var (
		c int64
		h []byte
	)
	err := tx.QueryRow(ctx,
		`SELECT writer_counter, blob_hash FROM op_log
		  WHERE user_id = $1 AND writer_id = $2 AND stream = 'hot'
		  ORDER BY writer_counter DESC LIMIT 1`, userID, writerID).Scan(&c, &h)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, make([]byte, 32), nil
	}
	if err != nil {
		return 0, nil, fmt.Errorf("auth: read the writer's head: %w", err)
	}
	return c, h, nil
}

// Roster returns every writer of a user, revoked ones included.
func (w *Writers) Roster(ctx context.Context, userID uuid.UUID) ([]Writer, error) {
	if w.Pool == nil {
		return nil, errors.New("auth: Writers.Pool is nil")
	}
	rows, err := w.Pool.Query(ctx,
		`SELECT user_id, writer_id, alg, pubkey, dak_pubkey, registered_at, revoked_at
		   FROM writers WHERE user_id = $1 ORDER BY registered_at, writer_id`, userID)
	if err != nil {
		return nil, fmt.Errorf("auth: roster for user %s: %w", userID, err)
	}
	defer rows.Close()
	var out []Writer
	for rows.Next() {
		var (
			wr      Writer
			revoked *time.Time
		)
		if err := rows.Scan(&wr.UserID, &wr.WriterID, &wr.Alg, &wr.PubKey, &wr.DAKPubkey, &wr.RegisteredAt, &revoked); err != nil {
			return nil, fmt.Errorf("auth: scan writer: %w", err)
		}
		if revoked != nil {
			wr.RevokedAt = *revoked
		}
		out = append(out, wr)
	}
	return out, rows.Err()
}
