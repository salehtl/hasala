package api

// routes_account.go: account deletion (spec 02 §15, route #41) and GET
// /api/v1/account (#40, account.go), with the display name (#76) and the
// phrase view (#67) when the account ceremonies are mounted.
//
// # Why deletion is in-app and self-service
//
// App Review guideline 5.1.1(v) requires an app that creates an account to
// offer deleting it from inside the app. That is the compliance reason. The
// product reason is the one on the privacy page: "users own their data" is a
// claim about what they can take away from us, and deletion is the half that
// proves it. `hasalad purge-user` exists for the operator, but an operator-only
// path is a promise the user has to ask permission to collect on.
//
// # Three factors, and the session is the weakest
//
// This ends everything, permanently, with no undo:
//
//  1. a live session: which account is being talked about, and nothing else;
//  2. an account.delete step-up (spec 02 §8) whose parameters name this
//     account: a UV passkey assertion over its challenge, or the session
//     writer's DAK plus the password (a password account's only factor);
//  3. a live writer's Ed25519 signature over keyproto.DeletionMessage(the
//     step-up's nonce, user_id), checked inside the step-up's transaction.
//
// A stolen session has neither of the other two. One nonce serves both the
// proof and the signature, so the gesture has one expiry, and a wrong
// signature burns it like a wrong proof.
//
// ledgerd's form (POST /api/v1/account/challenge, then an assertion and a
// signature over that nonce) is gone (spec 02 §2.4): a body that still carries
// its fields is a 400, and one without a step-up is 403 step_up_required.
//
// # What the answer says
//
// Every refusal is the step-up's: 403 step_up_required or step_up_failed,
// whichever factor was wrong, so a caller cannot tell which one it is missing.
// A purge that could not complete answers 500 deletion_failed and says the
// account was not deleted, because a client that showed "your account has been
// deleted" over a failed purge would be the worst outcome of this endpoint.

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purge"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// DeleteAccountRequest is #41's body: an account.delete step-up (P =
// (uuid_str(user_id))), the signing writer, and its Ed25519 signature over
// keyproto.DeletionMessage(step_up.nonce, user_id) (spec 02 §15.2).
type DeleteAccountRequest struct {
	StepUp   *StepUpWire `json:"step_up"`
	WriterID string      `json:"writer_id"`
	Sig      string      `json:"sig"`
}

func (s *Server) mountAccount(mux *http.ServeMux) {
	// Unconditional: App Review 5.1.1(v) requires in-app account deletion, so
	// there is no deployment of this server in which the route may be absent.
	mux.HandleFunc("DELETE /api/v1/account", s.requireSessionSuspendedOK(s.handleDeleteAccount))
	// account.go: #40, and with the account ceremonies #76 and #67.
	mux.HandleFunc("GET /api/v1/account", s.requireSessionFrozenOK(s.handleGetAccount))
	if s.Accounts != nil {
		mux.HandleFunc("PUT /api/v1/account/display-name", s.requireSession(s.userLimited(s.handleSetDisplayName)))
		mux.HandleFunc("POST /api/v1/keys/phrase/view", s.requireSession(s.userLimited(s.handlePhraseView)))
	}
}

// handleDeleteAccount purges the caller's account once all three factors are
// present. See the file header.
func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	// Attempts need their own cap: each one costs a step-up verification, a
	// signature check and, on success, a purge.
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many account requests; try again shortly")
		return
	}
	var req DeleteAccountRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	s.deleteWithStepUp(w, r, userID, req)
}

// deleteWithStepUp is spec 02 §15.2's #41: the session, an account.delete
// step-up (passkey, or DAK plus password: the password account's only path),
// and a live writer's signature over the step-up's own nonce, checked inside
// the step-up's transaction, so a wrong signature burns the nonce like a
// wrong proof. The step-up commits before the purge, whose cascade would
// otherwise wait on the nonce row the step-up holds.
func (s *Server) deleteWithStepUp(w http.ResponseWriter, r *http.Request, userID uuid.UUID, req DeleteAccountRequest) {
	su, ok := decodeStepUp(w, req.StepUp)
	if !ok {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	if su == nil {
		s.writeKeyErr(w, r, auth.ErrStepUpRequired)
		return
	}
	sig, ok := b64Field(w, req.Sig, "sig")
	if !ok {
		return
	}
	ph, err := keyproto.ParamsHash(keyproto.ActionAccountDelete, []byte(userID.String()))
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	g := auth.Guarded{UserID: userID, SessionHash: info.Hash, BoundWriter: info.WriterID,
		Action: keyproto.ActionAccountDelete, ParamsHash: ph, StepUp: su}
	err = s.StepUp.Run(r.Context(), g, func(ctx context.Context, tx pgx.Tx, _ auth.Proven) error {
		var (
			pub  []byte
			live bool
		)
		err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
			userID, req.WriterID).Scan(&pub, &live)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !live) {
			return fmt.Errorf("%w: the signer is not a live writer of the account", auth.ErrStepUpFailed)
		}
		if err != nil {
			return err
		}
		msg, err := keyproto.DeletionMessage(su.Nonce, userID)
		if err != nil || !keyproto.VerifyEd25519(pub, msg, sig) {
			return fmt.Errorf("%w: the deletion signature does not verify", auth.ErrStepUpFailed)
		}
		return nil
	})
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.purgeAccount(w, r, userID)
}

// purgeAccount collects the tokens, purges, wakes every device account-gone
// and answers 204.
func (s *Server) purgeAccount(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	// Every device hears that the account is gone (spec 02 §12.5); the tokens
	// go with the purge, so they are read first.
	tokens := s.accountTokens(r.Context(), userID, "")
	// The address's codes and joined waitlist entry are found by its tag,
	// and the goodbye email is queued, in the purge's transaction (spec 02
	// §15.2 steps 2 to 4).
	opts := purge.Options{Goodbye: true, Now: s.now}
	if s.Accounts != nil && s.Accounts.Keys != nil {
		opts.Tagger = s.Accounts.Keys
	}
	if s.PurgeLedger != "" {
		opts.Record = func(ids []uuid.UUID) error { return purgeledger.Append(s.PurgeLedger, ids, s.now()) }
		opts.Cancel = func(ids []uuid.UUID) error { return purgeledger.AppendCancelled(s.PurgeLedger, ids, s.now()) }
	}
	rep, err := purge.PurgeWith(r.Context(), s.Pool, userID, opts)
	if errors.Is(err, purge.ErrUnsettled) {
		s.logf("api: delete account %s: PURGE UNSETTLED: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "deletion_failed",
			"the deletion did not finish and may still take effect; this is a server-side "+
				"fault, not a problem with your request")
		return
	}
	if err != nil {
		// LOUD. The purge is all-or-nothing, so this means the account is still
		// here — and a client that rendered "your account has been deleted"
		// over this would be the worst outcome this endpoint has. The detail is
		// safe to return: it describes the caller's own account and the reason
		// is an operator-side defect, not a fact about their credentials.
		s.logf("api: delete account %s: PURGE FAILED, account intact: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "deletion_failed",
			"the account was NOT deleted and nothing was removed; this is a server-side "+
				"fault, not a problem with your request")
		return
	}
	// A success line names no account (spec 02 §20: `user` only on a
	// server-side failure).
	s.logf("api: delete account: purged %d rows across %d tables", rep.Total(), len(rep.Rows))
	if len(rep.SweptWithoutCascade) > 0 {
		// A schema defect the purge worked around. It is not the user's
		// problem, and it is very much the operator's.
		s.logf("api: delete account %s: tables needed an explicit sweep (missing ON DELETE "+
			"CASCADE): %v", userID, rep.SweptWithoutCascade)
	}
	s.wakeTokens(r.Context(), tokens, pushv2.ReasonAccountGone)
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
