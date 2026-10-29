// Package api is hasalad's HTTP surface (spec 02 §6, §7): the sync protocol a
// device speaks, the passkey ceremonies, the writer roster and the account
// routes. It is the first thing in this tree reachable from a network, so it
// owns the translation from the internal packages' precise errors into answers
// that are useful to a client and useless to an attacker.
//
// # One file per area, one mount function per file (spec 02 §4.2)
//
// Handler calls every mount function below. Each routes_*.go file belongs to
// one workstream; the ones whose routes are not built yet hold an empty mount
// function, so a workstream adds its routes to its own file and never to this
// one:
//
//	routes_session.go      logout, logout-all (F4)                  WS-3
//	routes_writers.go      writer challenge, register, revoke, roster WS-3
//	routes_account.go      account deletion                         WS-3
//	routes_stepup.go       step-up begin                            WS-3
//	routes_signup.go, routes_password.go, routes_reset.go,
//	routes_recover.go, routes_email.go, routes_freeze.go,
//	routes_events.go                                                WS-3 (empty)
//	routes_push.go         APNs token routes                        WS-4 (empty)
//	routes_mailboxlink.go  mailbox link routes                      WS-4 (empty)
//	routes_hooks.go        POST /hooks/gmail/pubsub                 WS-4 (empty)
//	routes_waitlist.go, routes_bankrequests.go   07's public routes  WS-19 (empty)
//
// The sync routes are in sync.go (WS-2), keys and the bootstrap in keys.go and
// keywraps.go, the passkey ceremonies in passkey.go and passkeymanage.go.
//
// # The contract
//
// Every endpoint except healthz, meta and the passkey register/login ceremonies
// requires `Authorization: Bearer <session token>`. Every query is scoped by
// the user id RESOLVED from that token and never by a user id taken from the
// request — there is no user field anywhere in the request shapes,
// deliberately.
//
// # Two answers a client must tell apart
//
// Every session rejection is the same 401 with the same body, with ONE
// exception: a session whose account has been DELETED answers
// `410 {"error":"account_deleted"}`. It is the only thing a device may key a
// local wipe on: wiping on a 401 would fire on every routine token expiry and
// destroy an offline user's outbox.
//
// # Wire encodings
//
//   - Integers that are int64 in Go (seq, writer_counter) travel as DECIMAL
//     STRINGS: JSON.parse and friends turn a JSON number into a float64.
//   - Chain hashes are lower-case HEX; every other binary field — blob bodies,
//     public keys, nonces, signatures — is standard base64.
//
// # Uploading: what happens when a batch is partly applied
//
// A batch that STRADDLES the writer's committed head — some rows already
// stored, some not — is refused with 409 rather than trimmed, because the seq
// block is reserved for the whole batch before the head is known
// (oplog.AppendClient). The client contract, quoted verbatim from
// oplog/chain.go:
//
//	read the chain head and resend only the rows above it
//
// A byte-identical resend of an ALREADY-applied batch is idempotent and answers
// 200 with the seqs those rows already hold.
//
// # The plaintext refusal (F1)
//
// POST /api/v1/sync accepts only sealed frame v3: every blob must pass
// blob.LooksSealed (400 plaintext_refused, naming the check) and carry the AAD
// of the position it is stored at (400 aad_mismatch). oplog.Row.validate runs
// the predicate again inside the append, and the op_log_blob_is_sealed CHECK
// is the database's guarantee behind both.
//
// # Sessions are weak capabilities
//
// A session token authorizes reading and appending to the account's log, and
// obtaining a registration challenge. It does NOT authorize enrolling a writer
// (an Ed25519 signature over a server-issued single-use nonce does) or
// deleting the account (a fresh passkey assertion over a server-issued
// challenge plus a device-key signature does). Spec 02 §8's action-bound
// step-up generalizes that rule (WS-3).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/oplog"
)

// Request-shaping limits. They bound what one caller can make the server hold
// in memory before anything about the caller is known to be legitimate.
const (
	// maxUploadBlobs caps how many positions one call may claim (spec 01 §6.8:
	// at most 8 blobs per upload). The whole batch shares one seq block and one
	// counter-lock hold (oplog.appendRows).
	maxUploadBlobs = 8
	// maxUploadBytes caps POST /api/v1/sync. Sized so a batch conforming to
	// maxUploadBlobs always fits: 8 blobs x base64(1 MiB) is ~11.2 MB, plus
	// JSON framing. TestUploadSizeCapsAgree asserts the arithmetic.
	maxUploadBytes = 12 << 20
	// maxSmallBodyBytes caps every other request body (spec 02 §6.1: 64 KiB).
	maxSmallBodyBytes = 64 << 10

	// defaultPullLimit / maxPullLimit bound GET /api/v1/sync's row count;
	// pullByteBudget bounds the bytes those rows may carry, which is the limit
	// that matters when a row can be a megabyte. 4 MiB keeps one response's
	// peak memory (raw, base64 and marshalled) near 15 MB.
	defaultPullLimit = 100
	maxPullLimit     = 500
	pullByteBudget   = 4 << 20

	// Hash-list pages are fixed-width rows, so a much larger page is still a
	// small response.
	defaultHashLimit = 1000
	maxHashLimit     = 5000
)

// Rate-limit defaults. See Limiter for why each of these endpoints has one.
const (
	challengeRate    = 1.0 / 60.0 // 1/minute sustained
	challengeBurst   = 10
	challengeMaxKeys = 4096

	// Strictly more generous than the challenge cap, because a legitimate
	// client spends one challenge per registration and may retry a request that
	// failed in transit.
	registerRate    = 2.0 / 60.0 // 2/minute sustained
	registerBurst   = 20
	registerMaxKeys = 4096

	// A user deletes their account at most once in its life, so any caller
	// making more than a handful of attempts a minute is not a user — and every
	// attempt costs a challenge row, an Ed25519 verification and a passkey
	// assertion.
	accountRate    = 1.0 / 60.0 // 1/minute sustained
	accountBurst   = 10
	accountMaxKeys = 4096

	// Session routes (logout, logout-all): rare, deliberate, and each one a
	// write. Generous burst, mean sustained rate.
	sessionRate    = 1.0 / 60.0
	sessionBurst   = 20
	sessionMaxKeys = 4096

	// Step-up begin (spec 02 §16.2 stepup-user): one per guarded action a
	// person takes, each a row.
	stepUpRate    = 10.0 / 60.0 // 10/minute sustained
	stepUpBurst   = 20
	stepUpMaxKeys = 4096

	// Pulls and hash lists (spec 02 §16.2 pull-user), plus at most
	// maxConcurrentPulls in flight per account (§11.3).
	pullRate           = 10.0
	pullBurst          = 50
	pullMaxKeys        = 4096
	maxConcurrentPulls = 2

	// POST /api/v1/sync gets two budgets: a request rate for POOL fairness
	// (one account cannot occupy the 16-connection pool with back-to-back
	// append transactions) and a byte-weighted bucket for the bytes that land
	// on the disk — about 64 MiB of burst, refilling at 256 MiB a day. No
	// request rate could be the storage control: legitimate imports and abuse
	// differ by blob size, not by request count. Neither stops an attacker who
	// stays inside the rate; the per-account ceiling (internal/budget) and the
	// headroom fuse exist beside them for that.
	syncRate             = 2.0 // requests/second sustained, for pool fairness
	syncBurst            = 20
	syncMaxKeys          = 4096
	maxConcurrentUploads = 2

	syncByteBurst   = 64 << 20             // 64 MiB of burst
	syncByteRate    = (256 << 20) / 86400. // 256 MiB/day sustained, in bytes/second
	syncByteMaxKeys = 4096
)

// Server holds everything the handlers need. Construct it with NewServer in
// production; the fields are exported so a test can substitute a limiter with
// no refill.
type Server struct {
	Pool     *pgxpool.Pool
	Sessions *auth.Sessions
	Writers  *auth.Writers
	Appender *oplog.Appender

	// StepUp verifies the action-bound step-ups (spec 02 §8); AccountKeys owns
	// the bootstrap, GET /keys and the PRF wraps. Handler fills both in over
	// Pool and Passkeys when a Server was built field by field.
	StepUp      *auth.StepUp
	AccountKeys *auth.AccountKeys

	// Accounts owns signup, passwords, recovery, resets, email change and
	// freeze (spec 02 §10.4, §10.7–§10.13). Nil means those routes are NOT
	// mounted: they need the server's key files (spec 01 §4.11).
	Accounts *auth.Accounts

	// Passkeys is the WebAuthn relying party. Nil means the passkey routes are
	// NOT MOUNTED: a deployment that has not been told its own domain
	// (`auth.rp_id`) cannot run a ceremony, and a sign-in route that exists only
	// to answer 500 is one a client retries forever.
	Passkeys *auth.Passkeys

	// The limiters default to the constants above when nil.
	ChallengePerUser *Limiter
	RegisterPerUser  *Limiter
	// AccountPerUser covers deletion challenges AND deletion attempts on one
	// budget: they are two halves of one flow, and a caller who can mint
	// unlimited nonces can make unlimited attempts.
	AccountPerUser *Limiter
	// SessionPerUser bounds logout and logout-all.
	SessionPerUser *Limiter
	// StepUpPerUser is spec 02's stepup-user: every begin writes a row.
	StepUpPerUser *Limiter
	// PullPerUser is spec 02's pull-user; pulls also hold one of
	// maxConcurrentPulls slots per account while they run.
	PullPerUser *Limiter
	pulls       accountSlots
	// PasskeyPerIP and PasskeyGlobal bound all the passkey routes, including
	// the ones that require a session — the limiter runs before the session is
	// resolved, so omitting the credential is not a way around it.
	PasskeyPerIP     *Limiter
	PasskeyPerPrefix *Limiter
	PasskeyGlobal    *Limiter
	// SyncPerUser and SyncUploadBytes are POST /api/v1/sync's pair.
	SyncPerUser     *Limiter
	SyncUploadBytes *Limiter
	uploads         accountSlots
	// MetaPerIP is GET /api/v1/meta's meta-ip.
	MetaPerIP *Limiter
	// The account routes' limiters (spec 02 §16.2). Sign-in uses PasskeyPerIP
	// and PasskeyGlobal, which are signin-ip and signin-global.
	RecoverPerIP       *Limiter
	CodePerIP          *Limiter
	ResetPerIP         *Limiter
	FreezePerIP        *Limiter
	FreezePerPrefix    *Limiter
	FreezeGlobal       *Limiter
	DevFreezeIP        *Limiter
	DevFreezePerPrefix *Limiter
	DevFreezeWriter    *Limiter
	DevFreezeGlobal    *Limiter

	// Meta is what GET /api/v1/meta reports (meta.go).
	Meta Meta

	// Push configures the APNs token routes and the wakes (routes_push.go).
	Push PushOptions
	// Gmail, when set, mounts the mailbox link (routes_mailboxlink.go) and,
	// when its Push is set too, the Pub/Sub hook (routes_hooks.go).
	Gmail *GmailOptions
	// Outlook, when set, mounts the mailbox link for provider "outlook"
	// (routes_mailboxlink.go), with or without Gmail's.
	Outlook *OutlookOptions
	// Web, when set, mounts spec 07's website routes: the waitlist and the
	// anonymous bank request (routes_waitlist.go, routes_bankrequests.go).
	// The app's signed-in bank request is mounted either way.
	Web *WebOptions
	// BankUser is the signed-in bank request's per-account limiter (spec 07
	// §5.9); Handler fills it in (Web.BankUser when set).
	BankUser *Limiter

	// Headroom is the box-level disk fuse (internal/headroom). When it is
	// tripped every non-read request is refused with a temporary 503 while
	// reads keep serving — see headroomGate. Nil is no fuse.
	Headroom Fuse

	// PullByteBudget bounds the blob bytes one page of GET /api/v1/sync may
	// carry; 0 means pullByteBudget. A field so a test can truncate a page by
	// BYTES without seeding megabytes.
	PullByteBudget int

	// Logf receives operator-facing detail: the REASON a request was rejected,
	// which the response deliberately does not carry. Defaults to log.Printf.
	Logf func(format string, args ...any)

	// TrustCloudflare is server.trusted_proxy = cloudflare: a loopback peer's
	// Cf-Connecting-Ip keys the per-IP limiters (spec 02 §16.1, clientip.go).
	TrustCloudflare bool

	// Now defaults to time.Now and is used only by the default limiters.
	Now func() time.Time

	PurgeLedger string
}

// NewServer builds the production server from config. It performs no network
// I/O.
func NewServer(cfg config.Config, pool *pgxpool.Pool) (*Server, error) {
	if pool == nil {
		return nil, errors.New("api: NewServer: pool is nil")
	}
	if cfg.Auth.SessionIdle <= 0 {
		return nil, errors.New("api: NewServer: auth.session_idle must be positive")
	}
	now := time.Now
	s := &Server{
		Pool: pool,
		// Until WS-3 lands spec 02 §9.2's sliding idle window and absolute cap,
		// a session lives for session_idle from issue (ledgerd's fixed TTL).
		Sessions: &auth.Sessions{Pool: pool, TTL: cfg.Auth.SessionIdle},
		Writers:  &auth.Writers{Pool: pool},
		Appender: &oplog.Appender{Pool: pool},
		Now:      now,

		TrustCloudflare: cfg.Server.TrustedProxy == config.ProxyCloudflare,
		PurgeLedger:     cfg.Server.PurgeLedgerPath,
		Meta: Meta{
			RPID:          cfg.Auth.RPID,
			MinIOSBuild:   cfg.Server.MinIOSBuild,
			LogGeneration: cfg.Server.LogGeneration,
		},
	}
	if cfg.Auth.RPID != "" {
		pk, err := auth.NewPasskeys(pool, cfg.Auth.RPID, cfg.Auth.RPDisplayName, cfg.Auth.RPOrigins)
		if err != nil {
			return nil, errors.New("api: NewServer: " + err.Error())
		}
		s.Passkeys = pk
	}
	s.StepUp = &auth.StepUp{Pool: pool, Passkeys: s.Passkeys}
	if s.Passkeys != nil {
		s.Passkeys.StepUp = s.StepUp
		s.Passkeys.Record = s.recordRestore
	}
	s.Writers.StepUp = s.StepUp
	s.Writers.Record = s.recordRestore
	s.AccountKeys = &auth.AccountKeys{Pool: pool, StepUp: s.StepUp}
	s.Sessions.Max = cfg.Auth.SessionMax
	return s, nil
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// route is what a log line names a request by: the matched route pattern
// (spec 02 §20), never the path, which can carry ids.
func route(r *http.Request) string {
	if r.Pattern != "" {
		return r.Pattern
	}
	return r.Method + " (unmatched)"
}

func (s *Server) logf(format string, args ...any) {
	if s.Logf != nil {
		s.Logf(format, args...)
		return
	}
	log.Printf(format, args...)
}

// Handler returns the router. It fills in any limiter the caller left nil, so a
// Server built field-by-field is still rate limited.
func (s *Server) Handler() http.Handler {
	s.ensureLimiter(&s.ChallengePerUser, challengeRate, challengeBurst, challengeMaxKeys)
	s.ensureLimiter(&s.RegisterPerUser, registerRate, registerBurst, registerMaxKeys)
	s.ensureLimiter(&s.AccountPerUser, accountRate, accountBurst, accountMaxKeys)
	s.ensureLimiter(&s.SessionPerUser, sessionRate, sessionBurst, sessionMaxKeys)
	s.ensureLimiter(&s.SyncPerUser, syncRate, syncBurst, syncMaxKeys)
	s.ensureLimiter(&s.SyncUploadBytes, syncByteRate, syncByteBurst, syncByteMaxKeys)
	s.ensureLimiter(&s.PasskeyPerIP, passkeyPerIPRate, passkeyPerIPBurst, passkeyMaxKeys)
	s.ensureLimiter(&s.PasskeyPerPrefix, passkeyPrefixRate, passkeyPrefixBurst, passkeyMaxKeys)
	s.ensureLimiter(&s.PasskeyGlobal, passkeyGlobalRate, passkeyGlobalBurst, 1)
	s.ensureLimiter(&s.MetaPerIP, metaRate, metaBurst, metaMaxKeys)
	s.ensureLimiter(&s.StepUpPerUser, stepUpRate, stepUpBurst, stepUpMaxKeys)
	s.ensureLimiter(&s.PullPerUser, pullRate, pullBurst, pullMaxKeys)
	if s.StepUp == nil {
		s.StepUp = &auth.StepUp{Pool: s.Pool, Passkeys: s.Passkeys}
	}
	if s.StepUp.Passkeys == nil {
		s.StepUp.Passkeys = s.Passkeys
	}
	if s.Passkeys != nil && s.Passkeys.StepUp == nil {
		s.Passkeys.StepUp = s.StepUp
	}
	if s.Writers != nil && s.Writers.StepUp == nil {
		s.Writers.StepUp = s.StepUp
	}
	if s.AccountKeys == nil {
		s.AccountKeys = &auth.AccountKeys{Pool: s.Pool, StepUp: s.StepUp}
	}
	if s.PullByteBudget <= 0 {
		s.PullByteBudget = pullByteBudget
	}
	s.defaultAccountLimiters()

	mux := http.NewServeMux()
	// Unauthenticated and unconditional. See health.go for why it pings the
	// pool and why its body is two words.
	mux.HandleFunc("GET /api/v1/healthz", s.handleHealthz)
	s.mountMeta(mux)
	s.mountPasskeys(mux)
	s.mountKeys(mux)
	s.mountSync(mux)

	// One mount function per routes_*.go file (spec 02 §4.2). Empty ones
	// register nothing until their workstream fills them in.
	s.mountSession(mux)
	s.mountWriters(mux)
	s.mountAccount(mux)
	s.mountStepUp(mux)
	s.mountSignup(mux)
	s.mountPassword(mux)
	s.mountReset(mux)
	s.mountRecover(mux)
	s.mountEmail(mux)
	s.mountFreeze(mux)
	s.mountEvents(mux)
	s.mountPush(mux)
	s.mountMailboxLink(mux)
	s.mountHooks(mux)
	s.mountWaitlist(mux)
	s.mountBankRequests(mux)

	// Catch-all: an unrouted path answers 404 JSON. There is no web content on
	// any hasala.app name served by this process (spec 02 §2.1: the embedded
	// PWA is gone), so "/" is a 404 too.
	//
	// One edge this does NOT cover: ServeMux cleans paths BEFORE matching, so a
	// path needing normalisation (`/api/v1/../v1/sync`) is answered with a 301
	// by net/http itself. Harmless — the target is the correct route.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeErr(w, http.StatusNotFound, "not_found", "no such endpoint")
	})
	// The box-level fuse wraps EVERYTHING, including the unauthenticated
	// ceremonies, because a sign-in is a durable write too.
	return securityHeaders(s.withClientKey(s.headroomGate(mux)))
}

// securityHeaders sets spec 02 §6.2's headers on every response. No HSTS
// in-process (Cloudflare's edge, and .app is HSTS-preloaded) and no CORS
// anywhere yet (07's four website routes bring their own, WS-19).
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		next.ServeHTTP(w, r)
	})
}

// mountPasskeys mounts the ceremonies. Absent entirely without a relying
// party — see the Passkeys field and passkey.go.
func (s *Server) mountPasskeys(mux *http.ServeMux) {
	if s.Passkeys == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/auth/passkey/register/begin", s.passkeyLimited(s.handlePasskeyRegisterBegin))
	mux.HandleFunc("POST /api/v1/auth/passkey/register/finish", s.passkeyLimited(s.handlePasskeyRegisterFinish))
	mux.HandleFunc("POST /api/v1/auth/passkey/login/begin", s.passkeyLimited(s.handlePasskeyLoginBegin))
	mux.HandleFunc("POST /api/v1/auth/passkey/login/finish", s.passkeyLimited(s.handlePasskeyLoginFinish))
	// Add (S + WB, step-up passkey.add, DWK at finish) and delete (step-up
	// passkey.delete): spec 02 #10, #11, #13, §10.5.
	mux.HandleFunc("POST /api/v1/auth/passkey/add/begin", s.passkeyLimitedSession(s.handlePasskeyAddBegin))
	mux.HandleFunc("POST /api/v1/auth/passkey/add/finish", s.passkeyLimitedSession(s.handlePasskeyAddFinish))
	mux.HandleFunc("GET /api/v1/auth/passkeys", s.passkeyLimitedSession(s.handleListPasskeys))
	mux.HandleFunc("DELETE /api/v1/auth/passkeys/{credential_id}", s.passkeyLimitedSession(s.handleDeletePasskey))
}

// mountKeys mounts the account's key material and the key-history log
// (keys.go, keywraps.go, keyhistory.go). ledgerd's write-once PUT
// /api/v1/keys is retired (spec 02 §2.4): keys arrive only through the
// bootstrap.
func (s *Server) mountKeys(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/key-history", s.requireSession(s.handleKeyHistory))
	mux.HandleFunc("GET /api/v1/keys", s.requireSession(s.handleGetKeys))
	mux.HandleFunc("POST /api/v1/account/bootstrap", s.requireSession(s.handleBootstrap))
	mux.HandleFunc("GET /api/v1/keys/wraps", s.requireSession(s.handleGetKeyWraps))
	mux.HandleFunc("POST /api/v1/keys/wraps", s.requireSession(s.handlePutKeyWrap))
	mux.HandleFunc("DELETE /api/v1/keys/wraps", s.requireSession(s.handleDeleteKeyWrap))
}

// mountSync mounts pull, hashes and upload (sync.go, WS-2).
func (s *Server) mountSync(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/sync", s.requireSession(s.handlePull))
	mux.HandleFunc("GET /api/v1/sync/hashes", s.requireSession(s.handleHashes))
	mux.HandleFunc("POST /api/v1/sync", s.requireSession(s.handleUpload))
}

// ---------------------------------------------------------------------------
// Session middleware
// ---------------------------------------------------------------------------

type authedHandler func(w http.ResponseWriter, r *http.Request, userID uuid.UUID)

// requireSession resolves the bearer token and hands the handler the user id it
// names; the whole session is in the request's context (sessionInfo). It
// refuses a frozen account and a restricted session (403 account_frozen,
// spec 02 §9.8); requireSessionFrozenOK is for the few routes §9.8 admits.
//
// EVERY rejection — absent header, wrong scheme, unknown token, expired, idle
// or revoked token — produces the identical 401. auth returns distinct
// sentinels (useful in a log); telling them apart in a RESPONSE is an oracle.
// The one deliberate exception is a deleted account's token: 410
// account_deleted, the only wipe signal.
//
// A failure that is not a rejection — the database is unreachable — is a 500,
// not a 401.
func (s *Server) requireSession(h authedHandler) http.HandlerFunc {
	return s.sessionGate(h, false, false)
}

// requireSessionFrozenOK is requireSession for GET /account and unfreeze.
func (s *Server) requireSessionFrozenOK(h authedHandler) http.HandlerFunc {
	return s.sessionGate(h, true, false)
}

// requireSessionSuspendedOK is requireSession for DELETE /account and its
// challenge, which a suspended account keeps (spec 02 §9.6, AT-DEL-3).
func (s *Server) requireSessionSuspendedOK(h authedHandler) http.HandlerFunc {
	return s.sessionGate(h, false, true)
}

// requireSessionForStepUpBegin admits a frozen and a suspended account; the
// handler then allows account.unfreeze only while frozen and account.delete
// only while suspended (spec 02 §9.6, §9.8).
func (s *Server) requireSessionForStepUpBegin(h authedHandler) http.HandlerFunc {
	return s.sessionGate(h, true, true)
}

type sessionCtxKey struct{}

func (s *Server) sessionGate(h authedHandler, frozenOK, suspendedOK bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			s.logf("api: %s: no bearer token", route(r))
			writeUnauthorized(w)
			return
		}
		info, err := s.Sessions.Info(r.Context(), token)
		if err != nil {
			if errors.Is(err, auth.ErrSessionAccountDeleted) {
				s.logf("api: %s: session belongs to a deleted account", route(r))
				writeAccountDeleted(w)
				return
			}
			if errors.Is(err, auth.ErrSessionInvalid) {
				s.logf("api: %s: session rejected: %v", route(r), err)
				writeUnauthorized(w)
				return
			}
			s.logf("api: %s: resolve session: %v", route(r), err)
			writeErr(w, http.StatusInternalServerError, "internal", "")
			return
		}
		userID := info.UserID
		st, err := s.accountStatus(r.Context(), userID)
		if err != nil {
			s.logf("api: %s: account status for %s: %v", route(r), userID, err)
			writeErr(w, http.StatusInternalServerError, "internal", "")
			return
		}
		// A frozen account, or a restricted session, reaches only §9.8's list.
		if !frozenOK && (st.Frozen || info.Restricted) {
			s.logf("api: %s: refused, the account is frozen", route(r))
			writeErr(w, http.StatusForbidden, "account_frozen", "")
			return
		}
		// Suspension (spec 02 §9.6): non-read methods only, so a pause never
		// looks like data loss, and account deletion stays open. Sign-in and
		// logout are outside this middleware.
		if !isRead(r.Method) && st.Suspended && !suspendedOK {
			s.logf("api: %s: refused, the account is suspended", route(r))
			writeAccountSuspended(w)
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), sessionCtxKey{}, info)), userID)
	}
}

// bearerToken extracts the credential from an Authorization header. The scheme
// is matched case-insensitively (RFC 7235 says it is case-insensitive); the
// token itself is not touched, because Sessions hashes the ENCODED form that
// arrives on the wire.
func bearerToken(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	const scheme = "bearer "
	if len(h) <= len(scheme) || !strings.EqualFold(h[:len(scheme)], scheme) {
		return "", false
	}
	tok := strings.TrimSpace(h[len(scheme):])
	if tok == "" {
		return "", false
	}
	return tok, true
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

// errorBody is every failure answer this package produces. Detail is present
// only where it describes the CALLER's own submission (a malformed blob, a
// chain break in their own log); it is always empty on 401 and on a rejected
// registration, where any variation at all would be an oracle.
type errorBody struct {
	Error  string `json:"error"`
	Detail string `json:"detail,omitempty"`
	// Budget is present on exactly one answer — 413 account_full — and absent
	// everywhere else. See [BudgetInfo].
	Budget *BudgetInfo `json:"budget,omitempty"`
}

// BudgetInfo is the machine-readable half of a 413 account_full: the numbers
// behind a refusal, so a client can render "you are using 255 MB of 256 MB"
// rather than a generic failure.
//
// It discloses nothing: every field describes the CALLER'S OWN account, which
// they can already read, and the same rule that governs errorBody.Detail
// applies — it is present only where it describes the caller's own submission.
type BudgetInfo struct {
	// Resource is the budget.Resource* name that ran out.
	Resource string `json:"resource"`
	// Have is what the account already holds, Delta is what this request asked
	// to add, and Limit is the ceiling. All in bytes, all as JSON numbers
	// because all are far below 2^53.
	Have  int64 `json:"have"`
	Delta int64 `json:"delta"`
	Limit int64 `json:"limit"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	buf, err := json.Marshal(v)
	if err != nil {
		// Marshalling our own response types cannot fail; if it somehow does,
		// a 500 with no body beats a half-written one.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	// Every response from this API is either a credential (a ceremony returns
	// a session bearer token) or the user's own encrypted history. None of it
	// may reach a shared cache, an intermediary, or a client's disk cache, so
	// the header is set here — once, for every response — rather than on the
	// handlers someone remembers.
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(buf)
}

func writeErr(w http.ResponseWriter, status int, code, detail string) {
	writeJSON(w, status, errorBody{Error: code, Detail: detail})
}

// writeUnauthorized is the ONE 401 this package emits. It takes no arguments
// precisely so no caller can vary it.
func writeUnauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	writeJSON(w, http.StatusUnauthorized, errorBody{Error: "unauthorized"})
}

// writeAccountDeleted is the ONE 410 this package emits, on the same terms.
//
// 410 rather than 404 or another 401 because it is the status whose meaning is
// exactly this one: the resource existed, it is gone, and the condition is
// permanent. A client keys its "wipe local data" path on this and on nothing
// else — see the Task 26 and Task 29 handling in the app.
func writeAccountDeleted(w http.ResponseWriter) {
	writeJSON(w, http.StatusGone, errorBody{Error: "account_deleted"})
}

// ---------------------------------------------------------------------------
// Request parsing
// ---------------------------------------------------------------------------

// decodeBody reads a JSON request body under a hard byte cap, refusing unknown
// fields so a client typo is a loud 400 rather than a silently ignored value.
// It reports whether it already answered.
func decodeBody(w http.ResponseWriter, r *http.Request, max int64, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, max)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large",
				"request body exceeds "+strconv.FormatInt(max, 10)+" bytes")
			return false
		}
		writeErr(w, http.StatusBadRequest, "bad_request", "body is not valid JSON for this endpoint")
		return false
	}
	// Exactly one JSON value per request: trailing bytes mean the client and
	// the server disagree about what was sent.
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		writeErr(w, http.StatusBadRequest, "bad_request", "body carries more than one JSON value")
		return false
	}
	return true
}

// parseCursor reads the `after` query parameter: a seq, as a decimal string,
// defaulting to 0. Negative is refused rather than clamped — it means the
// client's cursor arithmetic is wrong, and silently repairing it hides that.
func parseCursor(r *http.Request) (int64, error) {
	raw := r.URL.Query().Get("after")
	if raw == "" {
		return 0, nil
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n < 0 {
		return 0, errors.New("after must be a non-negative decimal seq")
	}
	return n, nil
}

// parseLimit reads `limit`, defaulting and capping it. A caller asking for more
// than the cap gets the cap, not an error: the response says `complete` either
// way, so an over-large request is answered correctly, just in more pages.
func parseLimit(r *http.Request, def, max int) (int, error) {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return def, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 {
		return 0, errors.New("limit must be a positive integer")
	}
	if n > max {
		n = max
	}
	return n, nil
}
