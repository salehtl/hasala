package auth

import (
	"context"
	"fmt"
	"time"
)

// SweepCeremonies is spec 02 §9.7's five-minute sweep: signup ceremonies (the
// plaintext addresses), password-login, recovery, reset and email-change
// ceremonies past their expiry.
func (a *Accounts) SweepCeremonies(ctx context.Context) (int64, error) {
	now := a.now()
	var total int64
	for _, t := range []string{"signup_ceremonies", "password_login_ceremonies", "recovery_ceremonies",
		"password_reset_ceremonies", "email_change_ceremonies"} {
		tag, err := a.Pool.Exec(ctx, `DELETE FROM `+t+` WHERE expires_at < $1`, now)
		if err != nil {
			return total, fmt.Errorf("auth: sweep %s: %w", t, err)
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// SweepHourly is the rest of spec 02 §9.7's account sweeps.
func (a *Accounts) SweepHourly(ctx context.Context) (int64, error) {
	now := a.now()
	steps := []struct {
		sql  string
		args []any
	}{
		{`DELETE FROM email_codes WHERE expires_at < $1`, []any{now.Add(-time.Hour)}},
		{`DELETE FROM email_code_pauses WHERE paused_until < $1`, []any{now}},
		{`DELETE FROM rate_counters WHERE window_start < $1`, []any{now.Add(-24 * time.Hour)}},
		{`UPDATE users SET password_paused_until = NULL WHERE password_paused_until < $1`, []any{now.Add(-24 * time.Hour)}},
		{`DELETE FROM freeze_tokens WHERE expires_at < $1`, []any{now}},
		{`DELETE FROM auth_events WHERE at < $1`, []any{now.Add(-90 * 24 * time.Hour)}},
		{`DELETE FROM admin_audit WHERE at < LEAST($1, now() - interval '400 days')`, []any{now.Add(-400 * 24 * time.Hour)}},
		{`DELETE FROM account_refusals WHERE day < $1::date`, []any{now.Add(-90 * 24 * time.Hour)}},
		{`DELETE FROM step_up_challenges WHERE expires_at < $1`, []any{now.Add(-time.Hour)}},
		{`DELETE FROM writer_challenges WHERE expires_at < $1`, []any{now.Add(-time.Hour)}},
		{`DELETE FROM device_freeze_challenges WHERE expires_at < $1`, []any{now.Add(-time.Hour)}},
		{`DELETE FROM webauthn_ceremonies WHERE expires_at < $1`, []any{now}},
	}
	var total int64
	for _, s := range steps {
		tag, err := a.Pool.Exec(ctx, s.sql, s.args...)
		if err != nil {
			return total, fmt.Errorf("auth: sweep: %w", err)
		}
		total += tag.RowsAffected()
	}
	if a.Sessions != nil {
		n, err := a.Sessions.ReapSessions(ctx)
		if err != nil {
			return total, err
		}
		total += n
	}
	return total, nil
}
