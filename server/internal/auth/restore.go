package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func (a *Accounts) recordFreeze(userID uuid.UUID, trigger, at time.Time) {
	if a.Record == nil {
		return
	}
	if trigger.After(at) {
		trigger = at
	}
	a.Record(purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindFreeze, Trigger: trigger})
}

func (a *Accounts) recordPassword(userID uuid.UUID, at time.Time) {
	if a.Record != nil {
		a.Record(purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindPassword})
	}
}

func (a *Accounts) recordUnfreeze(userID uuid.UUID, at time.Time) {
	if a.Record != nil {
		a.Record(purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindUnfreeze})
	}
}

type ReapplyReport struct {
	Freezes   int
	Devices   int
	Passwords int
	Unsigned  int
}

type reapplied int

const (
	reappliedNothing reapplied = iota
	reappliedDone
	reappliedUnsigned
)

func liftedInLedger(entries []purgeledger.Entry) map[int]bool {
	type unfreeze struct {
		index int
		at    time.Time
	}
	unfreezes := map[uuid.UUID][]unfreeze{}
	for i, e := range entries {
		if e.Kind == purgeledger.KindUnfreeze {
			unfreezes[e.ID] = append(unfreezes[e.ID], unfreeze{i, e.At})
		}
	}
	lifted := map[int]bool{}
	for i, e := range entries {
		if e.Kind != purgeledger.KindFreeze {
			continue
		}
		for _, u := range unfreezes[e.ID] {
			if u.index > i || u.at.After(e.At) {
				lifted[i] = true
				break
			}
		}
	}
	return lifted
}

func Reapply(ctx context.Context, pool *pgxpool.Pool, entries []purgeledger.Entry, now time.Time) (ReapplyReport, error) {
	var rep ReapplyReport
	if pool == nil {
		return rep, errors.New("auth: reapply: pool is nil")
	}
	lifted := liftedInLedger(entries)
	for i, e := range entries {
		var (
			step  func(context.Context, pgx.Tx, purgeledger.Entry, time.Time) (reapplied, error)
			count *int
		)
		switch e.Kind {
		case purgeledger.KindFreeze:
			if lifted[i] {
				continue
			}
			step, count = reapplyFreezeTx, &rep.Freezes
		case purgeledger.KindDevice:
			step, count = reapplyDeviceTx, &rep.Devices
		case purgeledger.KindPassword:
			step, count = reapplyPasswordTx, &rep.Passwords
		default:
			continue
		}
		out, err := reapplyOne(ctx, pool, e, now, step)
		if err != nil {
			return rep, fmt.Errorf("auth: reapply %s of %s: %w", e.Kind, e.At.UTC().Format(time.RFC3339), err)
		}
		switch out {
		case reappliedDone:
			*count++
		case reappliedUnsigned:
			rep.Unsigned++
		}
	}
	return rep, nil
}

func reapplyOne(ctx context.Context, pool *pgxpool.Pool, e purgeledger.Entry, now time.Time,
	step func(context.Context, pgx.Tx, purgeledger.Entry, time.Time) (reapplied, error)) (reapplied, error) {
	tx, err := pgtx.BeginReadCommitted(ctx, pool)
	if err != nil {
		return reappliedNothing, err
	}
	defer pgtx.Rollback(ctx, tx)
	out, err := step(ctx, tx, e, now)
	if err != nil || out == reappliedNothing {
		return reappliedNothing, err
	}
	if err := tx.Commit(ctx); err != nil {
		return reappliedNothing, err
	}
	return out, nil
}

func reapplyFreezeTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	var frozen *time.Time
	err := tx.QueryRow(ctx, `SELECT frozen_at FROM users WHERE id = $1 FOR UPDATE`, e.ID).Scan(&frozen)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	var lifted bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM auth_events WHERE user_id = $1 AND kind = $2 AND at >= $3)`,
		e.ID, EventAccountUnfrozen, e.At).Scan(&lifted); err != nil || lifted {
		return reappliedNothing, err
	}
	trigger := e.Trigger
	if trigger.After(e.At) {
		trigger = e.At
	}
	if frozen != nil {
		tag, err := tx.Exec(ctx,
			`UPDATE users SET freeze_trigger_at = least(freeze_trigger_at, $2),
			        holder_also_froze = holder_also_froze OR frozen_by = 'operator'
			  WHERE id = $1 AND (freeze_trigger_at > $2 OR (frozen_by = 'operator' AND NOT holder_also_froze))`,
			e.ID, trigger)
		if err != nil || tag.RowsAffected() == 0 {
			return reappliedNothing, err
		}
		return reappliedDone, nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE users SET frozen_at = $2, freeze_trigger_at = $3, frozen_by = 'holder', holder_also_froze = false
		  WHERE id = $1`, e.ID, e.At, trigger); err != nil {
		return reappliedNothing, err
	}
	if _, err := RevokeOtherSessionsTx(ctx, tx, e.ID, nil, now); err != nil {
		return reappliedNothing, err
	}
	return reappliedDone, nil
}

func reapplyDeviceTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	d := e.Device
	var id uuid.UUID
	err := tx.QueryRow(ctx, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, e.ID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	var (
		pub     []byte
		revoked *time.Time
	)
	err = tx.QueryRow(ctx, `SELECT pubkey, revoked_at FROM writers WHERE user_id = $1 AND writer_id = $2 FOR UPDATE`,
		e.ID, d.WriterID).Scan(&pub, &revoked)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	out := reappliedNothing
	if revoked == nil {
		signed, err := revocationVerifiesTx(ctx, tx, e.ID, d)
		if err != nil {
			return reappliedNothing, err
		}
		if !signed {
			out = reappliedUnsigned
		} else {
			if _, err := tx.Exec(ctx,
				`UPDATE writers SET revoked_at = $3 WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL`,
				e.ID, d.WriterID, e.At); err != nil {
				return reappliedNothing, err
			}
			if _, err := tx.Exec(ctx,
				`INSERT INTO key_history (user_id, writer_id, alg, pubkey, event, authorized_by, authorizer_writer_id,
				   final_counter, final_head, nonce, signature, at)
				 VALUES ($1,$2,'ed25519',$3,'revoked','device',$4,$5,$6,$7,$8,$9)`,
				e.ID, d.WriterID, pub, d.SignerWriterID, d.FinalCounter, d.FinalHead, d.Nonce, d.Sig, e.At); err != nil {
				return reappliedNothing, err
			}
			out = reappliedDone
		}
	}
	changed := false
	tag, err := tx.Exec(ctx,
		`UPDATE sessions SET revoked_at = $3, revoked_reason = 'writer'
		  WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL`, e.ID, d.WriterID, now)
	if err != nil {
		return reappliedNothing, err
	}
	changed = changed || tag.RowsAffected() > 0
	tag, err = tx.Exec(ctx, `DELETE FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, e.ID, d.WriterID)
	if err != nil {
		return reappliedNothing, err
	}
	changed = changed || tag.RowsAffected() > 0
	tag, err = tx.Exec(ctx,
		`DELETE FROM password_reset_ceremonies WHERE user_id = $1 AND approved_by_writer = $2 AND consumed_at IS NULL`,
		e.ID, d.WriterID)
	if err != nil {
		return reappliedNothing, err
	}
	changed = changed || tag.RowsAffected() > 0
	unlinked, err := dropHeldMailboxLinkTx(ctx, tx, e.ID, d.WriterID)
	if err != nil {
		return reappliedNothing, err
	}
	if out == reappliedNothing && (changed || unlinked) {
		out = reappliedDone
	}
	return out, nil
}

func revocationVerifiesTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, d *purgeledger.Device) (bool, error) {
	var (
		signerKey  []byte
		signerLive bool
	)
	err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		userID, d.SignerWriterID).Scan(&signerKey, &signerLive)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	msg, err := keyproto.RevocationMessage(d.Nonce, d.WriterID, uint64(d.FinalCounter), d.FinalHead)
	if err != nil {
		return false, nil
	}
	return signerLive && keyproto.VerifyEd25519(signerKey, msg, d.Sig), nil
}

func reapplyPasswordTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	var (
		has   bool
		setAt *time.Time
	)
	err := tx.QueryRow(ctx, `SELECT password_hash IS NOT NULL, password_set_at FROM users WHERE id = $1 FOR UPDATE`,
		e.ID).Scan(&has, &setAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	if !has || (setAt != nil && !setAt.Before(e.At)) {
		return reappliedNothing, nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE users SET password_hash = NULL, password_salt = NULL, password_version = NULL, password_set_at = NULL,
		        password_failures = 0, password_paused_until = NULL WHERE id = $1`, e.ID); err != nil {
		return reappliedNothing, err
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM password_reset_ceremonies WHERE user_id = $1 AND consumed_at IS NULL`, e.ID); err != nil {
		return reappliedNothing, err
	}
	if _, err := RevokeOtherSessionsTx(ctx, tx, e.ID, nil, now); err != nil {
		return reappliedNothing, err
	}
	return reappliedDone, nil
}
