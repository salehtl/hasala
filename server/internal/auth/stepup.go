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
//     credentials;
//   - device: the bound writer's DAK over DeviceStepUpMessage(C, writer_id),
//     then the password S. The DAK is checked first, so only an enrolled
//     iPhone with its owner present can submit a password here, and a valid
//     DAK signature makes the attempt bound: the account's pause and the
//     per-address counter do not apply, the writer's password-writer budget
//     does (review 2 F-01);
//   - device_code: only for password.reset (C8): the same DAK signature, then
//     the password_reset code begin emailed. C8's codes have a per-account
//     budget of their own.
//
// A failed proof burns the nonce in its own statement, committed even though
// the guarded action rolls back (spec 02 §8.1 step 4), with two exceptions
// that also move counters: a device proof with a valid DAK and a wrong S, and
// a device_code proof with a valid DAK and a wrong code (which keeps the nonce
// until the fifth wrong code). An action that fails after a good proof leaves
// the nonce usable until it expires.

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// StepUpTTL is the challenge row's lifetime (spec 02 §8.1, the CHECK's bound).
const StepUpTTL = 5 * time.Minute

// C8's per-account code budget (spec 02 §8.1 step 2, V2-2).
const (
	deviceCodeBeginsPerHour = 5
	deviceCodeBurnPause     = 15 * time.Minute
)

// Step-up errors. The HTTP layer answers ErrStepUpRequired with 403
// step_up_required and every failure with one 403 step_up_failed.
var (
	ErrStepUpRequired   = errors.New("auth: step-up required")
	ErrStepUpFailed     = errors.New("auth: step-up failed")
	ErrStepUpBadRequest = errors.New("auth: step-up request is malformed")
	ErrWriterUnbound    = errors.New("auth: the session is not bound to a live writer")
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
// (keys.wrap.put's credential, account.unfreeze's age rule, auth events).
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
	Keys     *authkeys.Keys // device proofs: the pepper and the code MACs
	Gate     *authkeys.Gate
	Mail     *Mailer // device_code: the password_reset code email
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
// DAK. A device_code begin also issues the password_reset code, within the
// account's own budget, and emails it after commit.
func (s *StepUp) Begin(ctx context.Context, userID uuid.UUID, sessionHash []byte, boundWriter string,
	action keyproto.Action, paramsHash []byte, kind keyproto.ProofKind) (Begun, error) {
	if s == nil || s.Pool == nil {
		return Begun{}, errors.New("auth: StepUp is not configured")
	}
	if !keyproto.ProofAllowed(action, kind) || len(paramsHash) != 32 || len(sessionHash) != 32 {
		return Begun{}, ErrStepUpBadRequest
	}
	now := s.now()
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return Begun{}, fmt.Errorf("auth: step-up begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	if action == keyproto.ActionAccountUnfreeze {
		// Only the operator lifts an operator freeze (review 2 F-03): nothing
		// is issued.
		var by *string
		if err := tx.QueryRow(ctx, `SELECT frozen_by FROM users WHERE id = $1`, userID).Scan(&by); err != nil {
			return Begun{}, fmt.Errorf("auth: step-up begin: %w", err)
		}
		if by != nil && *by == "operator" {
			return Begun{}, fmt.Errorf("%w: an operator freeze", ErrAccountFrozen)
		}
	}
	if kind == keyproto.ProofDevice || kind == keyproto.ProofDeviceCode {
		live, err := liveWriterWithDAK(ctx, tx, userID, boundWriter)
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
	b := Begun{Nonce: nonce, Challenge: c, ExpiresAt: now.Add(StepUpTTL)}
	var (
		codeID any
		code   *IssuedCode
	)
	if kind == keyproto.ProofDeviceCode {
		if s.Keys == nil {
			return Begun{}, errors.New("auth: StepUp.Keys is nil")
		}
		var begins int
		var burned bool
		if err := tx.QueryRow(ctx,
			`SELECT (SELECT count(*) FROM step_up_challenges
			          WHERE user_id = $1 AND proof_kind = 'device_code' AND issued_at > $2),
			        EXISTS (SELECT 1 FROM email_codes WHERE user_id = $1 AND ceremony_kind = 'step_up'
			                   AND burned_at > $3)`,
			userID, now.Add(-time.Hour), now.Add(-deviceCodeBurnPause)).Scan(&begins, &burned); err != nil {
			return Begun{}, fmt.Errorf("auth: step-up begin: C8 budget: %w", err)
		}
		if begins >= deviceCodeBeginsPerHour || burned {
			return Begun{}, fmt.Errorf("%w: this account's reset codes", ErrRateLimited)
		}
		st, err := readAccount(ctx, tx, userID, false)
		if err != nil {
			return Begun{}, err
		}
		ic, err := issueCodeTx(ctx, tx, s.Keys, now, PurposePasswordReset, st.EmailNorm, &userID, CeremonyStepUp,
			hex.EncodeToString(nonce), true)
		if err != nil {
			return Begun{}, err
		}
		ic.Name = st.DisplayName
		codeID, code = ic.ID, &ic
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO step_up_challenges (nonce, user_id, session_hash, action, params_hash, proof_kind, code_id,
		   issued_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		nonce, userID, sessionHash, string(action), paramsHash, string(kind), codeID, now, b.ExpiresAt); err != nil {
		return Begun{}, fmt.Errorf("auth: record step-up: %w", err)
	}
	if kind == keyproto.ProofPasskey {
		rows, err := tx.Query(ctx,
			`SELECT credential_id FROM webauthn_credentials WHERE user_id = $1 ORDER BY created_at, credential_id`, userID)
		if err != nil {
			return Begun{}, fmt.Errorf("auth: step-up allow list: %w", err)
		}
		for rows.Next() {
			var id []byte
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return Begun{}, err
			}
			b.AllowCredentials = append(b.AllowCredentials, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return Begun{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Begun{}, fmt.Errorf("auth: step-up begin: commit: %w", err)
	}
	if code != nil {
		s.Mail.SendCodes(*code)
	}
	return b, nil
}

// liveWriterWithDAK reports whether writerID is a live writer of userID (every
// writer has a DAK by the schema).
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

// failure is what a failed proof leaves behind, committed alone after the
// rollback: counters, and whether the nonce burns.
type failure func(ctx context.Context, tx pgx.Tx) (burn bool, err error)

// Run verifies g's step-up and runs action in the same transaction, spending
// the nonce only if action succeeds. A failed proof rolls back, applies its
// failure effects and burns the nonce in their own transaction, and returns
// ErrStepUpFailed; a missing step-up returns ErrStepUpRequired and touches
// nothing.
func (s *StepUp) Run(ctx context.Context, g Guarded, action func(ctx context.Context, tx pgx.Tx, p Proven) error) error {
	if g.StepUp == nil || len(g.StepUp.Nonce) == 0 {
		return ErrStepUpRequired
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return fmt.Errorf("auth: step-up: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	p, fail, err := s.verify(ctx, tx, g)
	if err != nil {
		pgtx.Rollback(ctx, tx)
		if errors.Is(err, ErrStepUpFailed) {
			if ferr := s.fail(ctx, g.StepUp.Nonce, fail); ferr != nil {
				return ferr
			}
		}
		return err
	}
	if err := action(ctx, tx, p); err != nil {
		// An action may refuse the proof itself (keys.wrap.put: the asserting
		// credential is not the wrap's; account.unfreeze: the factor is not
		// older than the trigger); that is a failed proof and burns.
		if errors.Is(err, ErrStepUpFailed) {
			pgtx.Rollback(ctx, tx)
			if ferr := s.fail(ctx, g.StepUp.Nonce, nil); ferr != nil {
				return ferr
			}
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

// fail commits a failed proof's effects and (unless they say otherwise) the
// burn of its nonce, in one transaction of their own.
func (s *StepUp) fail(ctx context.Context, nonce []byte, f failure) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("auth: step-up: record the failure: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	burn := true
	if f != nil {
		if burn, err = f(ctx, tx); err != nil {
			return err
		}
	}
	if burn {
		if _, err := tx.Exec(ctx, `UPDATE step_up_challenges SET used_at = $2 WHERE nonce = $1 AND used_at IS NULL`,
			nonce, s.now()); err != nil {
			return fmt.Errorf("auth: step-up: burn: %w", err)
		}
	}
	return tx.Commit(ctx)
}

// verify is spec 02 §8.1 step 5.1–5.3 inside tx: the row, then the proof.
func (s *StepUp) verify(ctx context.Context, tx pgx.Tx, g Guarded) (Proven, failure, error) {
	var (
		user         uuid.UUID
		session, ph  []byte
		action, kind string
		codeID       *uuid.UUID
		expires      time.Time
		used         *time.Time
	)
	err := tx.QueryRow(ctx,
		`SELECT user_id, session_hash, action, params_hash, proof_kind, code_id, expires_at, used_at
		   FROM step_up_challenges WHERE nonce = $1 FOR UPDATE`, g.StepUp.Nonce).
		Scan(&user, &session, &action, &ph, &kind, &codeID, &expires, &used)
	if errors.Is(err, pgx.ErrNoRows) {
		return Proven{}, nil, fmt.Errorf("%w: unknown nonce", ErrStepUpFailed)
	}
	if err != nil {
		return Proven{}, nil, fmt.Errorf("auth: step-up: read: %w", err)
	}
	switch {
	case user != g.UserID:
		return Proven{}, nil, fmt.Errorf("%w: another account's nonce", ErrStepUpFailed)
	case subtle.ConstantTimeCompare(session, g.SessionHash) != 1:
		return Proven{}, nil, fmt.Errorf("%w: another session's nonce", ErrStepUpFailed)
	case action != string(g.Action):
		return Proven{}, nil, fmt.Errorf("%w: issued for %s, used for %s", ErrStepUpFailed, action, g.Action)
	case subtle.ConstantTimeCompare(ph, g.ParamsHash[:]) != 1:
		return Proven{}, nil, fmt.Errorf("%w: params differ from the ones begun", ErrStepUpFailed)
	case kind != g.StepUp.Proof.Kind:
		return Proven{}, nil, fmt.Errorf("%w: the proof kind is not the one begun (%s)", ErrStepUpFailed, kind)
	case used != nil:
		return Proven{}, nil, fmt.Errorf("%w: nonce already used", ErrStepUpFailed)
	case !expires.After(s.now()):
		return Proven{}, nil, fmt.Errorf("%w: nonce expired", ErrStepUpFailed)
	}
	c, err := keyproto.StepUpChallenge(g.StepUp.Nonce, g.Action, g.ParamsHash)
	if err != nil {
		return Proven{}, nil, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
	}
	p := Proven{Kind: keyproto.ProofKind(kind), Nonce: g.StepUp.Nonce}
	switch keyproto.ProofKind(kind) {
	case keyproto.ProofPasskey:
		if s.Passkeys == nil {
			return Proven{}, nil, fmt.Errorf("%w: no relying party is configured", ErrStepUpFailed)
		}
		cred, err := s.Passkeys.VerifyAssertionCredentialTx(ctx, tx, g.UserID, c[:], g.StepUp.Proof.Assertion)
		if err != nil {
			if errors.Is(err, ErrPasskeyRejected) {
				return Proven{}, nil, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
			}
			return Proven{}, nil, err
		}
		p.CredentialID = cred
		return p, nil, nil
	case keyproto.ProofDevice, keyproto.ProofDeviceCode:
		w := g.StepUp.Proof.WriterID
		if err := s.verifyDAK(ctx, tx, g, c, w); err != nil {
			return Proven{}, nil, err
		}
		p.WriterID = w
		if keyproto.ProofKind(kind) == keyproto.ProofDevice {
			return s.verifyDevicePassword(ctx, tx, g, p)
		}
		if codeID == nil {
			return Proven{}, nil, fmt.Errorf("%w: no code was issued", ErrStepUpFailed)
		}
		return s.verifyDeviceCode(ctx, tx, g, p, *codeID)
	}
	return Proven{}, nil, fmt.Errorf("%w: proof kind %q", ErrStepUpFailed, kind)
}

// verifyDAK checks the proof's writer is the session's live writer and its
// DAK signed DeviceStepUpMessage(C, writer_id). An invalid signature changes no
// counter.
func (s *StepUp) verifyDAK(ctx context.Context, tx pgx.Tx, g Guarded, c [32]byte, w string) error {
	if w == "" || w != g.BoundWriter {
		return fmt.Errorf("%w: the proof's writer is not the session's", ErrStepUpFailed)
	}
	var (
		dak  []byte
		live bool
	)
	err := tx.QueryRow(ctx, `SELECT dak_pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		g.UserID, w).Scan(&dak, &live)
	if err != nil || !live {
		return fmt.Errorf("%w: the session's writer is gone or revoked", ErrStepUpFailed)
	}
	msg, err := keyproto.DeviceStepUpMessage(c, w)
	if err != nil || !keyproto.VerifyDAKBytes(dak, msg, g.StepUp.Proof.Sig) {
		return fmt.Errorf("%w: the DAK signature does not verify", ErrStepUpFailed)
	}
	return nil
}

// verifyDevicePassword is the device proof's second half: the account's
// password, bound by the DAK (no pause, no per-address counter; the writer's
// budget instead), through the gate.
func (s *StepUp) verifyDevicePassword(ctx context.Context, tx pgx.Tx, g Guarded, p Proven) (Proven, failure, error) {
	st, err := readAccount(ctx, tx, g.UserID, false)
	if err != nil {
		return Proven{}, nil, err
	}
	if !st.hasPassword() {
		return Proven{}, nil, fmt.Errorf("%w: the account has no password", ErrStepUpFailed)
	}
	if s.Keys == nil {
		return Proven{}, nil, errors.New("auth: StepUp.Keys is nil")
	}
	now := s.now()
	if err := writerPasswordBudget(ctx, tx, g.UserID, p.WriterID, now); err != nil {
		return Proven{}, nil, err
	}
	ok, err := passwordMatches(ctx, s.Keys, s.Gate, st, g.StepUp.Proof.Verifier, true)
	if err != nil {
		return Proven{}, nil, err
	}
	if !ok {
		writer := p.WriterID
		return Proven{}, func(ctx context.Context, tx pgx.Tx) (bool, error) {
			return true, recordPasswordFailure(ctx, tx, g.UserID, writer, now)
		}, fmt.Errorf("%w: wrong password", ErrStepUpFailed)
	}
	if st.Failures != 0 || st.PausedUntil != nil {
		if _, err := tx.Exec(ctx, `UPDATE users SET password_failures = 0, password_paused_until = NULL WHERE id = $1`,
			g.UserID); err != nil {
			return Proven{}, nil, err
		}
	}
	return p, nil, nil
}

// verifyDeviceCode is the device_code proof's second half: C8's code, gated
// by the DAK and bounded by code_attempts (no per-address counter).
func (s *StepUp) verifyDeviceCode(ctx context.Context, tx pgx.Tx, g Guarded, p Proven, codeID uuid.UUID) (Proven, failure, error) {
	now := s.now()
	fail, err := verifyCodeTx(ctx, tx, s.Keys, now, codeCheck{CodeID: codeID, Purpose: PurposePasswordReset,
		CeremonyKind: CeremonyStepUp, CeremonyID: hex.EncodeToString(g.StepUp.Nonce), Submitted: g.StepUp.Proof.Code})
	if err == nil {
		return p, nil, nil
	}
	if fail == nil {
		return Proven{}, nil, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
	}
	nonce := g.StepUp.Nonce
	return Proven{}, func(ctx context.Context, tx pgx.Tx) (bool, error) {
		var attempts int
		if err := tx.QueryRow(ctx,
			`UPDATE step_up_challenges SET code_attempts = least(code_attempts + 1, 5) WHERE nonce = $1 RETURNING code_attempts`,
			nonce).Scan(&attempts); err != nil {
			return false, err
		}
		burned, err := fail.apply(ctx, tx, now)
		if err != nil {
			return false, err
		}
		return burned || attempts >= codeMaxAttempts, nil
	}, fmt.Errorf("%w: wrong code", ErrStepUpFailed)
}

// ReapStepUps is spec 02 §9.7's step-up sweep.
func (s *StepUp) ReapStepUps(ctx context.Context) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM step_up_challenges WHERE expires_at < $1`, s.now().Add(-time.Hour))
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}
