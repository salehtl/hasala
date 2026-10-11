// Package console is the operator console (spec 07 §8), built minimal for the
// beta: the waitlist with approve, the invites with mint, resend and revoke,
// and the email log with masked recipients. It runs as its own process
// (`hasalad console`) on its own loopback port, behind the LAN proxy that
// sets the tailnet identity; it holds no mail token and no auth key, so every
// email it causes is a queued mail_log row that serve's worker sends.
//
// Not built yet (TODO for full parity, spec 07 §8.7–§8.8): entry detail and
// deletion, the TestFlight screens, banks and the broadcast, the account list
// and its actions, reveal and retry in the email log, the audit screen and
// the Prometheus metrics (/metrics is a 404; /healthz is served, health.go).
package console

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"html/template"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

//go:embed templates/*.html static/console.css
var assets embed.FS

var pages = template.Must(template.ParseFS(assets, "templates/*.html"))

// CSRF lifetimes (spec 07 §4.6).
const csrfTTL = 2 * time.Hour

// Console is the operator console. Build it with New.
type Console struct {
	Pool    *pgxpool.Pool
	Host    string   // HASALA_CONSOLE_HOST
	Tailnet string   // HASALA_CONSOLE_TAILNET
	Logins  []string // HASALA_CONSOLE_LOGINS
	TTL     time.Duration
	Now     func() time.Time

	queue  *mailq.Queue
	kCSRF  []byte
	tunnel refusalLog
}

// New builds a console with a fresh CSRF key (a restart invalidates open
// forms).
func New(pool *pgxpool.Pool, host, tailnet string, logins []string, ttl time.Duration) *Console {
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		panic(err)
	}
	if ttl == 0 {
		ttl = invites.DefaultTTL
	}
	return &Console{Pool: pool, Host: host, Tailnet: tailnet, Logins: logins, TTL: ttl, queue: mailq.New(pool, nil, nil), kCSRF: k}
}

func (c *Console) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// Handler is the console's router. Every pattern starts with "/" and none
// with /api/ or /hooks/ (spec 07 F7-2).
func (c *Console) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", c.page(c.dashboard))
	mux.HandleFunc("GET /invites", c.page(c.invitesPage))
	mux.HandleFunc("GET /mail", c.page(c.mailPage))
	mux.HandleFunc("GET /static/console.css", func(w http.ResponseWriter, r *http.Request) {
		b, _ := assets.ReadFile("static/console.css")
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		_, _ = w.Write(b)
	})
	mux.HandleFunc("POST /waitlist/{id}/approve", c.action("waitlist.approve", "waitlist_entry", c.approve))
	mux.HandleFunc("POST /invites/mint", c.action("invite.mint", "invite", c.mint))
	mux.HandleFunc("POST /invites/{id}/revoke", c.action("invite.revoke", "invite", c.revoke))
	mux.HandleFunc("POST /invites/{id}/resend", c.action("invite.resend", "invite", c.resend))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	return headers(c.identify(mux))
}

func headers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		h.Set("X-Frame-Options", "DENY")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		next.ServeHTTP(w, r)
	})
}

type ctxKey struct{}

func loginOf(r *http.Request) string { s, _ := r.Context().Value(ctxKey{}).(string); return s }

func refuse(w http.ResponseWriter, reason string) {
	slog.Warn("console: refused", "reason", reason)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusForbidden)
	_, _ = w.Write([]byte("Not allowed.\n"))
}

// identify is spec 07 §8.3's eight checks, on every request.
func (c *Console) identify(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if ip := net.ParseIP(host); err != nil || ip == nil || !ip.IsLoopback() {
			refuse(w, "peer")
			return
		}
		for name := range r.Header {
			if strings.HasPrefix(strings.ToLower(name), "cf-") || strings.EqualFold(name, "Cdn-Loop") {
				slog.Error("console: a Cloudflare header reached the console")
				c.tunnel.add(c.now())
				refuse(w, "cloudflare_header")
				return
			}
		}
		if !strings.EqualFold(r.Host, c.Host) {
			refuse(w, "host")
			return
		}
		if r.Header.Get("X-Forwarded-Proto") != "https" {
			refuse(w, "proto")
			return
		}
		ids := r.Header.Values("X-Webauth-User")
		login := ""
		if len(ids) == 1 {
			login = strings.TrimSpace(ids[0])
		}
		if login == "" || len(login) > 128 || strings.IndexFunc(login, func(r rune) bool { return r < 0x21 || r > 0x7e }) >= 0 {
			refuse(w, "identity")
			return
		}
		if r.Header.Get("Tailscale-User-Login") != "" {
			refuse(w, "unexpected_header")
			return
		}
		if strings.TrimSuffix(r.Header.Get("X-Webauth-Tailnet"), ".") != strings.TrimSuffix(c.Tailnet, ".") {
			refuse(w, "tailnet")
			return
		}
		allowed := false
		for _, l := range c.Logins {
			if strings.EqualFold(l, login) {
				allowed = true
			}
		}
		if !allowed {
			refuse(w, "not_allowed")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, login)))
	})
}

// csrf mints spec 07 §4.6's token for login, the POST path and its target.
func (c *Console) csrf(login, path, target string, issued time.Time) string {
	buf := make([]byte, 8)
	binary.BigEndian.PutUint64(buf, uint64(issued.Unix()))
	m := hmac.New(sha256.New, c.kCSRF)
	for _, part := range []string{"hasala/v1/console-csrf", login, path, target, "1"} {
		m.Write([]byte(part))
		m.Write([]byte{0})
	}
	m.Write(buf)
	return base64.RawURLEncoding.EncodeToString(append(buf, m.Sum(nil)[:16]...))
}

func (c *Console) csrfOK(login, path, target, token string) bool {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) != 24 {
		return false
	}
	issued := time.Unix(int64(binary.BigEndian.Uint64(raw[:8])), 0)
	if c.now().Sub(issued) > csrfTTL || issued.After(c.now().Add(time.Minute)) {
		return false
	}
	want := c.csrf(login, path, target, issued)
	return hmac.Equal([]byte(want), []byte(token))
}

// view is what every page template gets.
type view struct {
	Login   string
	Flash   string
	Code    string
	Entries []entryRow
	Invites []inviteRow
	Mail    []mailRow
	Counts  map[string]int
	MintTok string
}

type entryRow struct {
	ID, Email, State, Bank, Created string
	ApproveTok                      string
}

type inviteRow struct {
	ID, Short, State, Origin, Expires, Note string
	Review, Redeemed                        bool
	RevokeTok, ResendTok                    string
}

type mailRow struct {
	ID                          int64
	Kind, Hint, Status, Created string
	Attempts                    int
	Error                       string
}

// page runs a GET handler in a read-only transaction (spec 07 §8.5).
func (c *Console) page(f func(ctx context.Context, tx pgx.Tx, login string, v *view) (string, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tx, err := c.Pool.BeginTx(r.Context(), pgx.TxOptions{AccessMode: pgx.ReadOnly})
		if err != nil {
			http.Error(w, "database unavailable", http.StatusServiceUnavailable)
			return
		}
		defer pgtx.Rollback(r.Context(), tx)
		v := &view{Login: loginOf(r), Flash: r.URL.Query().Get("done"), Code: ""}
		name, err := f(r.Context(), tx, v.Login, v)
		if err != nil {
			slog.Error("console: page", "err", err.Error())
			http.Error(w, "error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := pages.ExecuteTemplate(w, name, v); err != nil {
			slog.Error("console: render", "err", err.Error())
		}
	}
}

func fmtTime(t *time.Time) string {
	if t == nil {
		return "-"
	}
	return t.UTC().Format("2006-01-02 15:04")
}

func (c *Console) dashboard(ctx context.Context, tx pgx.Tx, login string, v *view) (string, error) {
	rows, err := tx.Query(ctx,
		`SELECT e.id, coalesce(e.email_norm, ''), e.state, coalesce(b.name, e.other_bank, 'Another bank'), e.created_at
		   FROM waitlist_entries e LEFT JOIN banks b ON b.slug = e.bank_slug
		  WHERE e.state <> 'joined'
		  ORDER BY CASE e.state WHEN 'confirmed' THEN 0 WHEN 'invited' THEN 1 ELSE 2 END, e.created_at
		  LIMIT 500`)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	now := c.now()
	for rows.Next() {
		var (
			e  entryRow
			id uuid.UUID
			ts time.Time
		)
		if err := rows.Scan(&id, &e.Email, &e.State, &e.Bank, &ts); err != nil {
			return "", err
		}
		e.ID, e.Created = id.String(), fmtTime(&ts)
		path := "/waitlist/" + e.ID + "/approve"
		e.ApproveTok = c.csrf(login, path, e.ID, now)
		v.Entries = append(v.Entries, e)
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	v.Counts = map[string]int{}
	crow, err := tx.Query(ctx, `SELECT state, count(*) FROM waitlist_entries GROUP BY state`)
	if err != nil {
		return "", err
	}
	defer crow.Close()
	for crow.Next() {
		var s string
		var n int
		if err := crow.Scan(&s, &n); err != nil {
			return "", err
		}
		v.Counts[s] = n
	}
	return "dashboard.html", crow.Err()
}

func (c *Console) invitesPage(ctx context.Context, tx pgx.Tx, login string, v *view) (string, error) {
	list, err := invites.List(ctx, tx)
	if err != nil {
		return "", err
	}
	now := c.now()
	for _, s := range list {
		id := s.ID.String()
		v.Invites = append(v.Invites, inviteRow{ID: id, Short: invites.ShortID(s.ID), State: s.State, Origin: s.Origin,
			Expires: fmtTime(s.ExpiresAt), Note: s.Note, Review: s.Review, Redeemed: s.Redeemed,
			RevokeTok: c.csrf(login, "/invites/"+id+"/revoke", id, now),
			ResendTok: c.csrf(login, "/invites/"+id+"/resend", id, now)})
	}
	v.MintTok = c.csrf(login, "/invites/mint", "", now)
	return "invites.html", nil
}

func (c *Console) mailPage(ctx context.Context, tx pgx.Tx, _ string, v *view) (string, error) {
	rows, err := tx.Query(ctx,
		`SELECT id, kind, recipient_hint, status, attempts, coalesce(error, ''), created_at
		   FROM mail_log ORDER BY created_at DESC LIMIT 200`)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	for rows.Next() {
		var m mailRow
		var ts time.Time
		var att int16
		if err := rows.Scan(&m.ID, &m.Kind, &m.Hint, &m.Status, &att, &m.Error, &ts); err != nil {
			return "", err
		}
		m.Attempts, m.Created = int(att), fmtTime(&ts)
		v.Mail = append(v.Mail, m)
	}
	return "mail.html", rows.Err()
}

// errRefused is an action the state of the target does not allow.
var errRefused = errors.New("console: refused")

// actionFunc does one POST's work inside tx and returns the audit target id,
// the page to go back to, and (for a printed code) what to show once.
type actionFunc func(ctx context.Context, tx pgx.Tx, r *http.Request) (target, back, show string, err error)

// action is spec 07 §8.5–§8.6 around one POST: same-origin evidence, the
// CSRF token, the action and its audit row in one transaction (a refusal or
// error is audited in its own).
func (c *Console) action(name, kind string, f actionFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		login := loginOf(r)
		target := r.PathValue("id")
		if r.Header.Get("Sec-Fetch-Site") != "same-origin" || r.Header.Get("Origin") != "https://"+c.Host {
			refuse(w, "csrf_origin")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
		if err := r.ParseForm(); err != nil || !c.csrfOK(login, r.URL.Path, target, r.PostForm.Get("csrf")) {
			refuse(w, "csrf_token")
			return
		}
		actor := "tailnet:" + login
		addr := r.Header.Get("X-Real-IP")
		var back, show string
		err := pgx.BeginFunc(r.Context(), c.Pool, func(tx pgx.Tx) error {
			t, b, s, err := f(r.Context(), tx, r)
			if err != nil {
				return err
			}
			back, show, target = b, s, t
			return audit(r.Context(), tx, actor, "console."+name, kind, target, "ok", "", addr)
		})
		if err != nil {
			code := "error"
			result := "error"
			if errors.Is(err, errRefused) || errors.Is(err, invites.ErrNotApprovable) || errors.Is(err, invites.ErrNoSuchInvite) {
				code, result = "refused", "refused"
			} else {
				slog.Error("console: action", "action", name, "err", err.Error())
			}
			_ = pgx.BeginFunc(context.WithoutCancel(r.Context()), c.Pool, func(tx pgx.Tx) error {
				return audit(r.Context(), tx, actor, "console."+name, kind, target, result, code, addr)
			})
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte("That did not work (" + code + "). Go back and reload.\n"))
			return
		}
		if show != "" {
			// A printed code is shown once, never stored, never in a URL.
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_ = pages.ExecuteTemplate(w, "code.html", &view{Login: login, Code: show})
			return
		}
		http.Redirect(w, r, back+"?done="+name, http.StatusSeeOther)
	}
}

func audit(ctx context.Context, tx pgx.Tx, actor, action, kind, target, result, code, addr string) error {
	var errCode, ip any
	if code != "" {
		errCode = code
	}
	if net.ParseIP(addr) != nil {
		ip = addr
	}
	if len(target) > 64 {
		target = target[:64]
	}
	params, _ := json.Marshal(map[string]any{})
	_, err := tx.Exec(ctx,
		`INSERT INTO admin_audit (actor, action, target_kind, target_id, params, result, error_code, client_addr)
		 VALUES ($1, $2, $3, nullif($4, ''), $5, $6, $7, $8::inet)`,
		actor, strings.ReplaceAll(action, "-", "_"), kind, target, params, result, errCode, ip)
	return err
}

func (c *Console) approve(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, string, error) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		return "", "/", "", errRefused
	}
	inv, err := invites.ApproveEntry(ctx, tx, c.queue, id, "", c.TTL)
	if err != nil {
		return id.String(), "/", "", err
	}
	return inv.String(), "/", "", nil
}

func (c *Console) mint(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, string, error) {
	note := strings.TrimSpace(r.PostForm.Get("note"))
	review := r.PostForm.Get("review") == "on"
	if email := strings.TrimSpace(r.PostForm.Get("email")); email != "" {
		if review {
			return "", "/invites", "", errRefused
		}
		id, err := invites.EnqueueEmailed(ctx, tx, c.queue, email, note, c.TTL)
		if err != nil {
			return "", "/invites", "", errRefused
		}
		return id.String(), "/invites", "", nil
	}
	id, code, err := invites.MintPrinted(ctx, tx, note, c.TTL, review, c.now())
	if err != nil {
		return "", "/invites", "", errRefused
	}
	return id.String(), "/invites", invites.Display(code), nil
}

func (c *Console) revoke(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, string, error) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		return "", "/invites", "", errRefused
	}
	got, err := invites.Revoke(ctx, tx, id.String(), c.now())
	if err == nil && got != id {
		return id.String(), "/invites", "", errRefused
	}
	return id.String(), "/invites", "", err
}

func (c *Console) resend(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, string, error) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		return "", "/invites", "", errRefused
	}
	return id.String(), "/invites", "", invites.Resend(ctx, tx, c.queue, id)
}
