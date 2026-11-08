package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func freezeEntry(userID uuid.UUID, trigger, at time.Time) purgeledger.Entry {
	if trigger.After(at) {
		trigger = at
	}
	return purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindFreeze, Trigger: trigger}
}

func passwordEntry(userID uuid.UUID, at time.Time) purgeledger.Entry {
	return purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindPassword}
}

func phraseSeenEntry(userID uuid.UUID, at time.Time) purgeledger.Entry {
	return purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindPhraseSeen}
}

func sessionsEntry(userID uuid.UUID, at time.Time) purgeledger.Entry {
	return purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindSessions}
}

func emailEntry(userID uuid.UUID, at time.Time) purgeledger.Entry {
	return purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindEmail}
}

func UnfreezeEntry(userID uuid.UUID, at time.Time) purgeledger.Entry {
	return purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindUnfreeze}
}

func passkeyRemovalEntries(userID uuid.UUID, credentials [][]byte, at time.Time) []purgeledger.Entry {
	out := make([]purgeledger.Entry, 0, len(credentials))
	for _, id := range credentials {
		out = append(out, purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindPasskey, Credential: id})
	}
	return out
}

func wrapDeletionEntry(userID uuid.UUID, credential []byte, at time.Time) purgeledger.Entry {
	return purgeledger.Entry{ID: userID, At: at, Kind: purgeledger.KindWrap, Credential: credential}
}

type ReapplyReport struct {
	Freezes     int
	Unfreezes   int
	Devices     int
	Passwords   int
	Passkeys    int
	Wraps       int
	PhrasesSeen int
	Sessions    int
	Emails      int
	Unsigned    int
	Lifted      int
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

func afterSameSecondUnfreeze(entries []purgeledger.Entry) map[int]bool {
	type second struct {
		id uuid.UUID
		at int64
	}
	unfrozen := map[second]bool{}
	after := map[int]bool{}
	for i, e := range entries {
		key := second{e.ID, e.At.Unix()}
		switch e.Kind {
		case purgeledger.KindUnfreeze:
			unfrozen[key] = true
		case purgeledger.KindFreeze:
			after[i] = unfrozen[key]
		}
	}
	return after
}

func unfreezesToApply(entries []purgeledger.Entry, lifted map[int]bool) map[int]bool {
	latest := map[uuid.UUID]int{}
	frozen := map[uuid.UUID]bool{}
	for i, e := range entries {
		switch e.Kind {
		case purgeledger.KindFreeze:
			if !lifted[i] {
				frozen[e.ID] = true
			}
		case purgeledger.KindUnfreeze:
			if j, ok := latest[e.ID]; !ok || !entries[j].At.After(e.At) {
				latest[e.ID] = i
			}
		}
	}
	apply := map[int]bool{}
	for id, i := range latest {
		if !frozen[id] {
			apply[i] = true
		}
	}
	return apply
}

func Reapply(ctx context.Context, pool *pgxpool.Pool, entries []purgeledger.Entry, now time.Time) (ReapplyReport, error) {
	var rep ReapplyReport
	if pool == nil {
		return rep, errors.New("auth: reapply: pool is nil")
	}
	lifted := liftedInLedger(entries)
	unfreezes := unfreezesToApply(entries, lifted)
	afterUnfreeze := afterSameSecondUnfreeze(entries)
	var touched []uuid.UUID
	seen := map[uuid.UUID]bool{}
	for i, e := range entries {
		var (
			step  func(context.Context, pgx.Tx, purgeledger.Entry, time.Time) (reapplied, error)
			count *int
			locks bool
		)
		switch e.Kind {
		case purgeledger.KindFreeze:
			if lifted[i] {
				step, count = reapplyLiftedFreezeTx, &rep.Sessions
				break
			}
			step, count, locks = reapplyFreezeTx, &rep.Freezes, true
			if afterUnfreeze[i] {
				step = reapplyFreezeAfterUnfreezeTx
			}
		case purgeledger.KindUnfreeze:
			if !unfreezes[i] {
				continue
			}
			step, count = reapplyUnfreezeTx, &rep.Unfreezes
		case purgeledger.KindDevice:
			step, count = reapplyDeviceTx, &rep.Devices
		case purgeledger.KindPassword:
			step, count, locks = reapplyPasswordTx, &rep.Passwords, true
		case purgeledger.KindPasskey:
			step, count, locks = reapplyPasskeyTx, &rep.Passkeys, true
		case purgeledger.KindWrap:
			step, count = reapplyWrapTx, &rep.Wraps
		case purgeledger.KindPhraseSeen:
			step, count = reapplyPhraseSeenTx, &rep.PhrasesSeen
		case purgeledger.KindSessions:
			step, count = reapplySessionsTx, &rep.Sessions
		case purgeledger.KindEmail:
			step, count = reapplyEmailTx, &rep.Emails
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
			if locks && !seen[e.ID] {
				seen[e.ID] = true
				touched = append(touched, e.ID)
			}
		case reappliedUnsigned:
			rep.Unsigned++
		}
	}
	for _, e := range entries {
		if e.Kind != purgeledger.KindUnfreeze {
			continue
		}
		if _, err := reapplyOne(ctx, pool, e, now, reapplyLiftedLinksTx); err != nil {
			return rep, fmt.Errorf("auth: reapply %s of %s: %w", e.Kind, e.At.UTC().Format(time.RFC3339), err)
		}
	}
	for _, id := range touched {
		out, err := reapplyOne(ctx, pool, purgeledger.Entry{ID: id}, now, liftLockoutTx)
		if err != nil {
			return rep, fmt.Errorf("auth: reapply: lift a freeze that left no way in: %w", err)
		}
		if out == reappliedDone {
			rep.Lifted++
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
	return restoreFreezeTx(ctx, tx, e, now, `>=`)
}

func reapplyFreezeAfterUnfreezeTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	return restoreFreezeTx(ctx, tx, e, now, `>`)
}

func restoreFreezeTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time, later string) (reapplied, error) {
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
		`SELECT EXISTS (SELECT 1 FROM auth_events WHERE user_id = $1 AND kind = $2 AND date_trunc('second', at) `+later+` $3)`,
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
			  WHERE id = $1 AND (date_trunc('second', freeze_trigger_at) > $2 OR (frozen_by = 'operator' AND NOT holder_also_froze))`,
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

func reapplyUnfreezeTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	var (
		frozen    *time.Time
		by        *string
		holderToo bool
	)
	err := tx.QueryRow(ctx, `SELECT frozen_at, frozen_by, holder_also_froze FROM users WHERE id = $1 FOR UPDATE`, e.ID).
		Scan(&frozen, &by, &holderToo)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	if frozen == nil || frozen.Truncate(time.Second).After(e.At) {
		return reappliedNothing, nil
	}
	if by != nil && *by == FrozenByOperator {
		if !holderToo {
			return reappliedNothing, nil
		}
		if _, err := tx.Exec(ctx, `UPDATE users SET holder_also_froze = false WHERE id = $1`, e.ID); err != nil {
			return reappliedNothing, err
		}
		return reappliedDone, nil
	}
	if err := clearFreezeTx(ctx, tx, e.ID, now); err != nil {
		return reappliedNothing, err
	}
	if _, err := RevokeOtherSessionsTx(ctx, tx, e.ID, nil, now); err != nil {
		return reappliedNothing, err
	}
	return reappliedDone, nil
}

func reapplyLiftedLinksTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, e.ID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	tag, err := tx.Exec(ctx, `UPDATE freeze_tokens SET used_at = $3 WHERE user_id = $1 AND used_at IS NULL AND trigger_at < $2`,
		e.ID, e.At, now)
	if err != nil {
		return reappliedNothing, err
	}
	var known bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM auth_events WHERE user_id = $1 AND kind = $2 AND date_trunc('second', at) >= $3)`,
		e.ID, EventAccountUnfrozen, e.At).Scan(&known); err != nil {
		return reappliedNothing, err
	}
	if known && tag.RowsAffected() == 0 {
		return reappliedNothing, nil
	}
	if !known {
		if err := recordEventTx(ctx, tx, nil, e.ID, AuthEvent{Kind: EventAccountUnfrozen}, e.At); err != nil {
			return reappliedNothing, err
		}
	}
	return reappliedDone, nil
}

func liftLockoutTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	var locked bool
	err := tx.QueryRow(ctx,
		`SELECT frozen_at IS NOT NULL AND coalesce(frozen_by = 'holder', false) AND password_hash IS NULL
		        AND NOT EXISTS (SELECT 1 FROM webauthn_credentials WHERE user_id = users.id)
		   FROM users WHERE id = $1 FOR UPDATE`, e.ID).Scan(&locked)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !locked) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	if err := clearFreezeTx(ctx, tx, e.ID, now); err != nil {
		return reappliedNothing, err
	}
	if err := recordEventTx(ctx, tx, nil, e.ID, AuthEvent{Kind: EventAccountUnfrozen}, now); err != nil {
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
	var revoked *time.Time
	err = tx.QueryRow(ctx, `SELECT revoked_at FROM writers WHERE user_id = $1 AND writer_id = $2 FOR UPDATE`,
		e.ID, d.WriterID).Scan(&revoked)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	r := writerRevocation{UserID: e.ID, WriterID: d.WriterID, SignerWriterID: d.SignerWriterID,
		FinalCounter: d.FinalCounter, FinalHead: d.FinalHead, Nonce: d.Nonce, Sig: d.Sig}
	out := reappliedNothing
	retire := false
	if revoked == nil {
		signed, err := r.verifiesTx(ctx, tx)
		if err != nil {
			return reappliedNothing, err
		}
		if signed {
			retire, out = true, reappliedDone
		} else {
			out = reappliedUnsigned
		}
	}
	so, err := revokeWriterTx(ctx, tx, r, retire, e.At, now)
	if err != nil {
		return reappliedNothing, err
	}
	if out == reappliedNothing && (so.changed || so.unlinked) {
		out = reappliedDone
	}
	return out, nil
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
	if !has || (setAt != nil && !setAt.Truncate(time.Second).Before(e.At)) {
		return reappliedNothing, nil
	}
	if err := clearPasswordTx(ctx, tx, e.ID); err != nil {
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

func reapplyPasskeyTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	var created time.Time
	err := tx.QueryRow(ctx,
		`SELECT created_at FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2 FOR UPDATE`,
		e.ID, e.Credential).Scan(&created)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	if created.Truncate(time.Second).After(e.At) {
		return reappliedNothing, nil
	}
	if _, err := revokeCredentialSessionsTx(ctx, tx, e.ID, e.Credential, nil, now); err != nil {
		return reappliedNothing, err
	}
	tag, err := tx.Exec(ctx, `DELETE FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`, e.ID, e.Credential)
	if err != nil || tag.RowsAffected() != 1 {
		return reappliedNothing, err
	}
	return reappliedDone, nil
}

func reapplyWrapTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, _ time.Time) (reapplied, error) {
	if err := refuseIfLastUnseenWrapTx(ctx, tx, e.ID, e.Credential); err != nil {
		if errors.Is(err, ErrPhraseUnseen) {
			return reappliedNothing, nil
		}
		return reappliedNothing, err
	}
	tag, err := tx.Exec(ctx, `DELETE FROM account_key_wraps WHERE user_id = $1 AND credential_id = $2 AND created_at < $3`,
		e.ID, e.Credential, e.At.Truncate(time.Second))
	if err != nil || tag.RowsAffected() != 1 {
		return reappliedNothing, err
	}
	return reappliedDone, nil
}

func reapplyPhraseSeenTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, _ time.Time) (reapplied, error) {
	tag, err := tx.Exec(ctx,
		`UPDATE account_keys SET phrase_seen_at = greatest(created_at, $2)
		  WHERE user_id = $1 AND phrase_seen_at IS NULL AND date_trunc('second', created_at) <= $2`, e.ID, e.At)
	if err != nil || tag.RowsAffected() != 1 {
		return reappliedNothing, err
	}
	return reappliedDone, nil
}

func reapplySessionsTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	return endSessionsTx(ctx, tx, e, now, `<=`)
}

func reapplyLiftedFreezeTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	return endSessionsTx(ctx, tx, e, now, `<`)
}

func endSessionsTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time, older string) (reapplied, error) {
	if err := forgetPushTokens(ctx, tx,
		`user_id = $1 AND session_hash IN (SELECT token_hash FROM sessions
		    WHERE user_id = $1 AND revoked_at IS NULL AND date_trunc('second', created_at) `+older+` $2)`, e.ID, e.At); err != nil {
		return reappliedNothing, err
	}
	tag, err := tx.Exec(ctx,
		`UPDATE sessions SET revoked_at = $3, revoked_reason = 'others'
		  WHERE user_id = $1 AND revoked_at IS NULL AND date_trunc('second', created_at) `+older+` $2`, e.ID, e.At, now)
	if err != nil || tag.RowsAffected() == 0 {
		return reappliedNothing, err
	}
	return reappliedDone, nil
}

func reapplyEmailTx(ctx context.Context, tx pgx.Tx, e purgeledger.Entry, now time.Time) (reapplied, error) {
	var verified, reverify *time.Time
	err := tx.QueryRow(ctx, `SELECT email_verified_at, reverify_requested_at FROM users WHERE id = $1 FOR UPDATE`, e.ID).
		Scan(&verified, &reverify)
	if errors.Is(err, pgx.ErrNoRows) {
		return reappliedNothing, nil
	}
	if err != nil {
		return reappliedNothing, err
	}
	if verified != nil && !verified.Truncate(time.Second).Before(e.At) {
		return reappliedNothing, nil
	}
	if reverify != nil && !reverify.Truncate(time.Second).Before(e.At) {
		return reappliedNothing, nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE users SET reverify_requested_at = $2, email_undeliverable_at = coalesce(email_undeliverable_at, $2)
		  WHERE id = $1`, e.ID, e.At); err != nil {
		return reappliedNothing, err
	}
	if _, err := tx.Exec(ctx, `UPDATE freeze_tokens SET used_at = $2 WHERE user_id = $1 AND used_at IS NULL`, e.ID, now); err != nil {
		return reappliedNothing, err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE email_codes SET burned_at = $2 WHERE user_id = $1 AND used_at IS NULL AND burned_at IS NULL`, e.ID, now); err != nil {
		return reappliedNothing, err
	}
	return reappliedDone, nil
}
