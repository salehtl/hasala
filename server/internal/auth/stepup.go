package auth

// Step-up (spec 01 §10.2, spec 02 §8): an action-bound, single-use proof that
// the user approved one operation with its exact parameters.
//
//	begin(action, params_hash, proof_kind) → nonce, C = SHA256("hasala/v1/step-up" ‖ 00 ‖ nonce ‖ action ‖ 00 ‖ params_hash)
//	the guarded request carries {nonce, proof}; the server recomputes params_hash
//	from the ACTUAL request, checks the row, verifies the proof, and spends the
//	nonce in the same transaction as the action.
//
// Proof kinds:
//   - passkey: a UV WebAuthn assertion over C by one of the account's
//     credentials (Passkeys.VerifyAssertionCredential);
//   - device: the bound writer's DAK over DeviceStepUpMessage(C, writer_id),
//     then the password. The DAK is checked first, so only an enrolled iPhone
//     with its owner present can submit a password here. This tree has no
//     password columns yet (the password work is separate), so an account
//     never has one and a device proof with a valid DAK signature fails at the
//     password step, as spec 02 §8.1 says it must for an account without one;
//   - device_code: only for password.reset, whose route and email codes are not
//     built here; Begin refuses it (ErrStepUpUnsupported).
//
// A failed proof burns the nonce in its own statement (spec 02 §8.1 step 4),
// committed even though the guarded action rolls back; an action that fails
// after a good proof leaves the nonce usable until it expires (§8.1 5.5).

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// StepUpTTL is the challenge row's lifetime (spec 02 §8.1, the CHECK's bound).
const StepUpTTL = 5 * time.Minute

// Step-up errors. The HTTP layer answers ErrStepUpRequired with 403
// step_up_required and every failure with one 403 step_up_failed.
var (
	ErrStepUpRequired    = errors.New("auth: step-up required")
	ErrStepUpFailed      = errors.New("auth: step-up failed")
	ErrStepUpBadRequest  = errors.New("auth: step-up request is malformed")
	ErrStepUpUnsupported = errors.New("auth: this proof kind is not available in this build")
	ErrWriterUnbound     = errors.New("auth: the session is not bound to a live writer")
)

// StepUpProof is the step_up.proof object (spec 02 §7).
type StepUpProof struct {
	Kind      string          `json:"kind"`
	Assertion json.RawMessage `json:"assertion,omitempty"` // passkey: the PublicKeyCredential
	WriterID  string          `json:"writer_id,omitempty"` // device kinds
	Sig       []byte          `json:"sig,omitempty"`       // device kinds: P-256 r ‖ s (b64)
	Verifier  []byte          `json:"verifier,omitempty"`  // device: S (b64)
	Code      string          `json:"code,omitempty"`      // device_code
}

// StepUpObject is the step_up field of a guarded request.
type StepUpObject struct {
	Nonce []byte      `json:"-"`
	Proof StepUpProof `json:"proof"`
}

// Proven says how a step-up was proved, for the guarded action's own checks
// (keys.wrap.put requires the asserting credential to be the wrap's).
type Proven struct {
	Kind         keyproto.ProofKind
	CredentialID []byte // passkey
	WriterID     string // device kinds
	Nonce        []byte
}

// StepUp owns step_up_challenges.
type StepUp struct {
	Pool     *pgxpool.Pool
	Passkeys *Passkeys
	Now      func() time.Time
}

func (s *StepUp) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Begun is what step-up/begin answers.
type Begun struct {
	Nonce            []byte
	Challenge        [32]byte
	ExpiresAt        time.Time
	AllowCredentials [][]byte // passkey only: every credential of the account
}

// Begin issues a challenge for one action. boundWriter is the session's bound
// writer ("" when unbound); a device proof needs it to be live and to hold a
// DAK.
func (s *StepUp) Begin(ctx context.Context, userID uuid.UUID, sessionHash []byte, boundWriter string,
	action keyproto.Action, paramsHash []byte, kind keyproto.ProofKind) (Begun, error) {
	if s == nil || s.Pool == nil {
		return Begun{}, errors.New("auth: StepUp is not configured")
	}
	if !keyproto.ProofAllowed(action, kind) || len(paramsHash) != 32 || len(sessionHash) != 32 {
		return Begun{}, ErrStepUpBadRequest
	}
	switch kind {
	case keyproto.ProofDeviceCode:
		return Begun{}, ErrStepUpUnsupported
	case keyproto.ProofDevice:
		live, err := liveWriterWithDAK(ctx, s.Pool, userID, boundWriter)
		if err != nil {
			return Begun{}, err
		}
		if !live {
			return Begun{}, ErrWriterUnbound
		}
	}
	nonce := make([]byte, keyproto.NonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return Begun{}, fmt.Errorf("auth: step-up nonce: %w", err)
	}
	c, err := keyproto.StepUpChallenge(nonce, action, [32]byte(paramsHash))
	if err != nil {
		return Begun{}, err
	}
	now := s.now()
	b := Begun{Nonce: nonce, Challenge: c, ExpiresAt: now.Add(StepUpTTL)}
	if _, err := s.Pool.Exec(ctx,
		`INSERT INTO step_up_challenges (nonce, user_id, session_hash, action, params_hash, proof_kind, issued_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		nonce, userID, sessionHash, string(action), paramsHash, string(kind), now, b.ExpiresAt); err != nil {
		return Begun{}, fmt.Errorf("auth: record step-up: %w", err)
	}
	if kind == keyproto.ProofPasskey {
		rows, err := s.Pool.Query(ctx,
			`SELECT credential_id FROM webauthn_credentials WHERE user_id = $1 ORDER BY created_at, credential_id`, userID)
		if err != nil {
			return Begun{}, fmt.Errorf("auth: step-up allow list: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var id []byte
			if err := rows.Scan(&id); err != nil {
				return Begun{}, err
			}
			b.AllowCredentials = append(b.AllowCredentials, id)
		}
		if err := rows.Err(); err != nil {
			return Begun{}, err
		}
	}
	// Opportunistic sweep of rows long past use; what refuses a replay is
	// used_at and expires_at on the row, never its absence.
	_, _ = s.Pool.Exec(ctx, `DELETE FROM step_up_challenges WHERE expires_at < $1`, now.Add(-24*time.Hour))
	return b, nil
}

// liveWriterWithDAK reports whether writerID is a live writer of userID with a
// DAK (every writer has one by the schema).
func liveWriterWithDAK(ctx context.Context, q querier, userID uuid.UUID, writerID string) (bool, error) {
	if writerID == "" {
		return false, nil
	}
	var live bool
	err := q.QueryRow(ctx,
		`SELECT revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`, userID, writerID).Scan(&live)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("auth: read writer %s: %w", writerID, err)
	}
	return live, nil
}

// querier is the read surface of a pool and a transaction.
type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// Guarded describes one guarded request: who, which session, which action,
// and the params hash the server recomputed from the request itself.
type Guarded struct {
	UserID      uuid.UUID
	SessionHash []byte
	BoundWriter string
	Action      keyproto.Action
	ParamsHash  [32]byte
	StepUp      *StepUpObject // nil: none was sent
}

// Run verifies g's step-up and runs action in the same transaction, spending
// the nonce only if action succeeds. A failed proof rolls back, burns the
// nonce in its own statement and returns ErrStepUpFailed; a missing step-up
// returns ErrStepUpRequired and touches nothing.
func (s *StepUp) Run(ctx context.Context, g Guarded, action func(ctx context.Context, tx pgx.Tx, p Proven) error) error {
	if g.StepUp == nil || len(g.StepUp.Nonce) == 0 {
		return ErrStepUpRequired
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return fmt.Errorf("auth: step-up: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	p, err := s.verify(ctx, tx, g)
	if err != nil {
		pgtx.Rollback(ctx, tx)
		if errors.Is(err, ErrStepUpFailed) {
			s.burn(ctx, g.StepUp.Nonce)
		}
		return err
	}
	if err := action(ctx, tx, p); err != nil {
		// An action may refuse the proof itself (keys.wrap.put: the asserting
		// credential is not the wrap's); that is a failed proof and burns.
		if errors.Is(err, ErrStepUpFailed) {
			pgtx.Rollback(ctx, tx)
			s.burn(ctx, g.StepUp.Nonce)
		}
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE step_up_challenges SET used_at = $2 WHERE nonce = $1`, g.StepUp.Nonce, s.now()); err != nil {
		return fmt.Errorf("auth: step-up: spend: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("auth: step-up: commit: %w", err)
	}
	return nil
}

func (s *StepUp) burn(ctx context.Context, nonce []byte) {
	_, _ = s.Pool.Exec(ctx, `UPDATE step_up_challenges SET used_at = $2 WHERE nonce = $1 AND used_at IS NULL`, nonce, s.now())
}

// verify is spec 02 §8.1 step 5.1–5.3 inside tx: the row, then the proof.
func (s *StepUp) verify(ctx context.Context, tx pgx.Tx, g Guarded) (Proven, error) {
	var (
		user         uuid.UUID
		session, ph  []byte
		action, kind string
		expires      time.Time
		used         *time.Time
	)
	err := tx.QueryRow(ctx,
		`SELECT user_id, session_hash, action, params_hash, proof_kind, expires_at, used_at
		   FROM step_up_challenges WHERE nonce = $1 FOR UPDATE`, g.StepUp.Nonce).
		Scan(&user, &session, &action, &ph, &kind, &expires, &used)
	if errors.Is(err, pgx.ErrNoRows) {
		return Proven{}, fmt.Errorf("%w: unknown nonce", ErrStepUpFailed)
	}
	if err != nil {
		return Proven{}, fmt.Errorf("auth: step-up: read: %w", err)
	}
	switch {
	case user != g.UserID:
		return Proven{}, fmt.Errorf("%w: another account's nonce", ErrStepUpFailed)
	case subtle.ConstantTimeCompare(session, g.SessionHash) != 1:
		return Proven{}, fmt.Errorf("%w: another session's nonce", ErrStepUpFailed)
	case action != string(g.Action):
		return Proven{}, fmt.Errorf("%w: issued for %s, used for %s", ErrStepUpFailed, action, g.Action)
	case subtle.ConstantTimeCompare(ph, g.ParamsHash[:]) != 1:
		return Proven{}, fmt.Errorf("%w: params differ from the ones begun", ErrStepUpFailed)
	case kind != g.StepUp.Proof.Kind:
		return Proven{}, fmt.Errorf("%w: proof kind %q, begun as %q", ErrStepUpFailed, g.StepUp.Proof.Kind, kind)
	case used != nil:
		return Proven{}, fmt.Errorf("%w: nonce already used", ErrStepUpFailed)
	case !expires.After(s.now()):
		return Proven{}, fmt.Errorf("%w: nonce expired", ErrStepUpFailed)
	}
	c, err := keyproto.StepUpChallenge(g.StepUp.Nonce, g.Action, g.ParamsHash)
	if err != nil {
		return Proven{}, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
	}
	p := Proven{Kind: keyproto.ProofKind(kind), Nonce: g.StepUp.Nonce}
	switch keyproto.ProofKind(kind) {
	case keyproto.ProofPasskey:
		if s.Passkeys == nil {
			return Proven{}, fmt.Errorf("%w: no relying party is configured", ErrStepUpFailed)
		}
		cred, err := s.Passkeys.VerifyAssertionCredential(ctx, g.UserID, c[:], g.StepUp.Proof.Assertion)
		if err != nil {
			if errors.Is(err, ErrPasskeyRejected) {
				return Proven{}, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
			}
			return Proven{}, err
		}
		p.CredentialID = cred
		return p, nil
	case keyproto.ProofDevice:
		w := g.StepUp.Proof.WriterID
		if w == "" || w != g.BoundWriter {
			return Proven{}, fmt.Errorf("%w: the proof's writer is not the session's", ErrStepUpFailed)
		}
		var (
			dak  []byte
			live bool
		)
		err := tx.QueryRow(ctx, `SELECT dak_pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
			g.UserID, w).Scan(&dak, &live)
		if err != nil || !live {
			return Proven{}, fmt.Errorf("%w: the session's writer is gone or revoked", ErrStepUpFailed)
		}
		msg, err := keyproto.DeviceStepUpMessage(c, w)
		if err != nil || !keyproto.VerifyDAKBytes(dak, msg, g.StepUp.Proof.Sig) {
			return Proven{}, fmt.Errorf("%w: the DAK signature does not verify", ErrStepUpFailed)
		}
		// Only now the password (spec 01 §10.2's order). This build stores no
		// passwords, so no account has one to verify against.
		return Proven{}, fmt.Errorf("%w: the account has no password", ErrStepUpFailed)
	}
	return Proven{}, fmt.Errorf("%w: proof kind %q", ErrStepUpFailed, kind)
}
