package admin

// mailbox.go is the operator's view of the Gmail mailbox lane's server-side
// credential state — see 00035_mailbox.sql's header and
// internal/mailbox/grants.go, which own the table this file only reads.
//
// # Why this route exists
//
// verify.BlindSpots' mailbox_lane_client_authored_ops entry names exactly
// the hole this route fills: the mailbox lane never calls an smtpd.Handler,
// so no parse_diagnostics row is ever written for it and /admin/accounting
// cannot see it AT ALL — not undercounted, absent, a whole traffic class
// the accounting instrument was never built to watch. That entry's own text
// names the operator's substitute: "mailbox_grants.last_broker_at for the
// operator". This route is that substitute, rendered.
//
// # Content-free, on mailbox_grants' own terms
//
// mailbox_grants holds id, user_id, provider, status, created_at,
// last_broker_at and refresh_token_hash. This file reads status and
// last_broker_at ONLY, and aggregates them — no user_id, no created_at, no
// provider (today's CHECK constraint admits exactly one value), and never
// refresh_token_hash: nothing outside internal/mailbox's own VerifyAndTouch
// query ever reads that column back out, on the same rule Grant's doc
// comment states for the package that owns the table. A per-status COUNT
// and a single staleness number name no user and carry no credential.
//
// # last_broker_at is a liveness signal, not a health signal
//
// It is touched at the START of every broker call, before Google answers
// (grants.go's VerifyAndTouch), so a fresh timestamp on a
// reconnect_required grant means only that the broker was recently
// REACHED — not that whatever it tried then succeeded. This page never
// calls a fresh timestamp "healthy": the field below is named for age and
// contact, not health, and the per-status counts — reconnect_required above
// all — are what an operator should read for the actual state.

import (
	"context"
	"fmt"
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"
)

// mailboxHealth is the console's content-free view of mailbox_grants.
type mailboxHealth struct {
	// GrantsByStatus counts mailbox_grants rows by status: 'active' and
	// 'reconnect_required' today (00035's CHECK constraint). A status with
	// no grants is simply absent from the map rather than present with a
	// zero — the page treats a missing key as zero.
	GrantsByStatus map[string]int `json:"grants_by_status"`

	// MaxLastBrokerAgeSeconds is the LARGEST now()-last_broker_at across
	// every grant that has ever recorded contact — the most overdue one,
	// which is the number worth an operator's attention. Null when no grant
	// has ever been touched, including "there are no grants at all": a zero
	// here would claim a broker contact that never happened.
	//
	// This is an age, not a health check — see the file doc above. A grant
	// can carry a small number here and still be reconnect_required; the
	// status counts are the truth for that, not this field.
	MaxLastBrokerAgeSeconds *float64 `json:"max_last_broker_age_seconds"`
}

// mailboxGrantHealth reads mailbox_grants' status and last_broker_at
// columns only. It never selects refresh_token_hash, and it never selects
// user_id: the response is an aggregate, so no query here is scoped to one
// user or returns a value that could name one.
func mailboxGrantHealth(ctx context.Context, pool *pgxpool.Pool) (mailboxHealth, error) {
	out := mailboxHealth{GrantsByStatus: map[string]int{}}

	rows, err := pool.Query(ctx, `SELECT status, count(*) FROM mailbox_grants GROUP BY status`)
	if err != nil {
		return out, fmt.Errorf("admin: mailbox grant counts: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var status string
		var n int
		if err := rows.Scan(&status, &n); err != nil {
			return out, fmt.Errorf("admin: mailbox grant counts scan: %w", err)
		}
		out.GrantsByStatus[status] = n
	}
	if err := rows.Err(); err != nil {
		return out, fmt.Errorf("admin: mailbox grant counts: %w", err)
	}

	// EXTRACT(EPOCH FROM ...) over an aggregate MAX: one row, one number
	// (or SQL NULL when every last_broker_at is NULL, including the
	// zero-grant case), scanned straight into the pointer field so "never
	// touched" survives as JSON null rather than becoming a fabricated 0.
	if err := pool.QueryRow(ctx,
		`SELECT EXTRACT(EPOCH FROM max(now() - last_broker_at))
		   FROM mailbox_grants
		  WHERE last_broker_at IS NOT NULL`,
	).Scan(&out.MaxLastBrokerAgeSeconds); err != nil {
		return out, fmt.Errorf("admin: mailbox max broker age: %w", err)
	}
	return out, nil
}

// mailbox serves the operator's mailbox-grant health panel: counts by
// status and mailbox_grants' own staleness signal. See the file doc for
// what this route deliberately does not claim.
func (h *Handler) mailbox(w http.ResponseWriter, r *http.Request) {
	health, err := mailboxGrantHealth(r.Context(), h.Diag.Pool)
	if err != nil {
		h.logf("admin: mailbox: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, health)
}
