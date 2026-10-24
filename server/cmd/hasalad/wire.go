package main

// wire.go builds what serve runs beside the API: the APNs dispatcher, the
// Gmail and Outlook links and hooks, the account ceremonies (with the server keys), the one
// email queue and its worker, and spec 07's website routes, each from its own
// configuration group, plus their sweeps.

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/msjwt"
	"github.com/salehtl/hasala/server/internal/opsnotify"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/pushv2"
	"github.com/salehtl/hasala/server/internal/turnstile"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

// nudgeInterval is spec 02 §13.7's watch-renewal nudge.
const nudgeInterval = 15 * time.Minute

// readSecret reads a *_FILE secret: the whole file, never logged.
func readSecret(name, path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", refusal{fmt.Errorf("%s: %w", name, err)}
	}
	return string(b), nil
}

// newSender is the [email] group's sender: Cloudflare Email Service, at
// HASALA_EMAIL_API_BASE_URL when set (config refuses a non-default base
// behind Cloudflare: it is a local end-to-end run's capture server), or
// mail.Unconfigured without the group.
func newSender(cfg config.Config) (mail.Sender, error) {
	if !cfg.Email.Enabled() {
		slog.Warn("hasalad serve: the [email] group is not configured: every email fails and the waitlist routes are not mounted")
		return mail.Unconfigured{}, nil
	}
	tok, err := readSecret("HASALA_EMAIL_API_TOKEN_FILE", cfg.Email.APITokenFile)
	if err != nil {
		return nil, err
	}
	cf, err := mail.NewCloudflare(cfg.Email.CloudflareAccountID, strings.TrimSpace(tok), cfg.Email.From)
	if err != nil {
		return nil, refusal{err}
	}
	cf.FromName = cfg.Email.FromName
	cf.ReplyTo = cfg.Email.ReplyTo
	if cfg.Email.APIBaseURL != "" && cfg.Email.APIBaseURL != mail.DefaultBaseURL {
		cf.BaseURL = cfg.Email.APIBaseURL
		slog.Warn("hasalad serve: email goes to a non-default API base (HASALA_EMAIL_API_BASE_URL); local runs only")
	}
	return cf, nil
}

// wireMailbox mounts the mailbox links of [gmail] and [outlook], which share
// the route key, and Gmail's push.
func wireMailbox(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, srv *api.Server, waker pushv2.Waker,
	ex *extras) error {
	if !cfg.Gmail.LinkEnabled() && !cfg.Outlook.LinkEnabled() {
		slog.Warn("hasalad serve: neither the [gmail] nor the [outlook] mailbox link is configured: " +
			"the mailbox link routes and the Pub/Sub hook are not mounted")
		return nil
	}
	raw, err := readSecret("HASALA_MAILBOX_ROUTE_KEY_FILE", cfg.Gmail.RouteKeyFile)
	if err != nil {
		return err
	}
	rk, err := gmailpush.ParseRouteKey(raw)
	if err != nil {
		return refusal{err}
	}
	if err := gmailpush.CheckKeyID(ctx, pool, rk); err != nil {
		return refusal{err}
	}
	wireOutlook(cfg.Outlook, srv, rk)
	wireGmail(cfg.Gmail, srv, rk)
	// The renewal nudge asks a holder to renew its watch, so it runs only
	// for the providers whose push is on: without one it would wake every
	// holder twice a day for a watch that cannot exist.
	var nudged []string
	if srv.Gmail != nil && srv.Gmail.Push != nil {
		nudged = append(nudged, gmailpush.ProviderGmail)
	}
	if srv.Outlook != nil && srv.Outlook.Push != nil {
		nudged = append(nudged, gmailpush.ProviderOutlook)
	}
	if len(nudged) > 0 {
		ex.done = append(ex.done, startSweepEvery(ctx, "mailbox watch nudge", nudgeInterval,
			func(ctx context.Context) (string, error) { return gmailpush.Nudge(ctx, pool, waker, nudged...) }))
	}
	return nil
}

// wireOutlook mounts the [outlook] group's parts (config.OutlookConfig): the
// link with client_id and the route key; the Graph hooks and their URLs in
// /meta with the push too.
func wireOutlook(o config.OutlookConfig, srv *api.Server, rk gmailpush.RouteKey) {
	if !o.LinkEnabled() {
		slog.Warn("hasalad serve: the [outlook] group is not configured: Outlook mailboxes cannot be linked")
		return
	}
	srv.Outlook = &api.OutlookOptions{
		RouteKey: rk,
		Link:     &msjwt.Verifier{Audience: o.ClientID},
		ClientID: o.ClientID,
	}
	if !o.PushEnabled() {
		slog.Warn("hasalad serve: the [outlook] Graph push is not configured: the Outlook link is mounted " +
			"without wakes (the app fetches mail when opened)")
		return
	}
	srv.Outlook.Push = &api.OutlookPush{NotificationURL: o.NotificationURL, LifecycleURL: o.LifecycleURL}
}

// wireGmail mounts the [gmail] group's parts (config.GmailConfig): the link
// with ios_client_id and the route key; the hook and the watch topic only with
// the Pub/Sub push too.
func wireGmail(g config.GmailConfig, srv *api.Server, rk gmailpush.RouteKey) {
	if !g.LinkEnabled() {
		slog.Warn("hasalad serve: the [gmail] group is not configured: Gmail mailboxes cannot be linked and the Pub/Sub hook is not mounted")
		return
	}
	srv.Gmail = &api.GmailOptions{
		RouteKey:    rk,
		Link:        &googlejwt.Verifier{Audience: g.IOSClientID},
		IOSClientID: g.IOSClientID,
	}
	if !g.PushEnabled() {
		slog.Warn("hasalad serve: the [gmail] Pub/Sub push is not configured: the mailbox link is mounted, " +
			"the Pub/Sub hook is not, and /api/v1/meta offers no watch topic (the app fetches mail when opened, without wakes)")
		return
	}
	srv.Gmail.Push = &api.GmailPush{
		Topic:          g.PubSubTopic,
		Hook:           &googlejwt.Verifier{Audience: g.PubSubAudience},
		Subscription:   g.PubSubSubscription,
		ServiceAccount: g.PubSubServiceAccount,
	}
}

// extras is what wireExtras started; stop waits for its goroutines.
type extras struct {
	done []<-chan struct{}
}

func (e *extras) wait() {
	for _, d := range e.done {
		<-d
	}
}

// wireExtras configures srv's push, Gmail and website options from cfg and
// starts their workers and sweeps until ctx is done.
func wireExtras(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, srv *api.Server) (*extras, error) {
	ex := &extras{}

	// Push (spec 02 §12): routes always mounted; sending only when enabled.
	srv.Push.Environments = cfg.APNs.AllowedEnvironments
	var waker pushv2.Waker = pushv2.NopWaker{}
	if cfg.APNs.Enabled {
		pemText, err := readSecret("HASALA_APNS_KEY_FILE", cfg.APNs.KeyFile)
		if err != nil {
			return nil, err
		}
		key, err := pushv2.ParseP8([]byte(pemText))
		if err != nil {
			return nil, refusal{err}
		}
		client, err := pushv2.NewClient(pushv2.ClientConfig{TeamID: cfg.APNs.TeamID, KeyID: cfg.APNs.KeyID,
			Topic: cfg.APNs.Topic, Key: key})
		if err != nil {
			return nil, refusal{err}
		}
		d := pushv2.NewDispatcher(pool, client)
		ex.done = append(ex.done, d.Start(ctx))
		waker = d
	}
	srv.Push.Waker = waker

	// The mailbox links (spec 02 §13), and Gmail's Pub/Sub push on top.
	if err := wireMailbox(ctx, cfg, pool, srv, waker, ex); err != nil {
		return nil, err
	}

	// Email (spec 02 §14.4, spec 07 §6): Cloudflare when configured. Without
	// it every send fails permanently (mail.Unconfigured), so a queued email
	// ends `failed` in the log rather than `sent`, and the website routes are
	// not mounted: a sign-up whose confirmation can never arrive is worse than
	// no form.
	sender, err := newSender(cfg)
	if err != nil {
		return nil, err
	}

	// The server keys (spec 01 §4.11). Both files mount the account
	// ceremonies (signup, passwords, recovery, resets, email change, freeze);
	// the auth key alone still gives the waitlist and the queue their
	// email_tag. Both derive K_tag identically, so the tags agree.
	keys, err := loadAuthKeys(cfg)
	if err != nil {
		return nil, refusal{err}
	}
	var tagger mailq.Tagger
	switch {
	case keys != nil:
		if err := checkKeyIDs(ctx, pool, keys); err != nil {
			return nil, refusal{err}
		}
		tagger = keys
	case cfg.Auth.AuthKeyFile != "":
		k, err := readKeyFile("HASALA_AUTH_KEY_FILE", cfg.Auth.AuthKeyFile)
		if err != nil {
			return nil, refusal{err}
		}
		t, err := authkeys.NewEmailTagger(k)
		if err != nil {
			return nil, refusal{err}
		}
		tagger = t
	}

	// One queue, one worker and one log for every email this server sends.
	q := mailq.New(pool, sender, tagger)
	q.Rates = map[mailq.Lane]int{mailq.LaneWaitlist: int(cfg.Web.RateWaitlist), mailq.LaneBulk: int(cfg.Web.RateBulk)}
	q.Retention = cfg.Web.LogRetention
	q.Register("test", mailq.TestRenderer)
	q.Register("deleted", mailq.DeletedRenderer)
	minter, _ := tagger.(invites.Minter)
	q.Register("invite", invites.Renderer{WebBase: cfg.Email.WebBaseURL, ManualTestFlight: true, Minter: minter})
	var record func(purgeledger.Entry)
	if p := cfg.Server.PurgeLedgerPath; p != "" {
		record = func(e purgeledger.Entry) {
			if err := purgeledger.AppendEntries(p, e); err != nil {
				slog.Warn("hasalad serve: the restore ledger did not record a waitlist deletion", "kind", string(e.Kind), "err", err)
			}
		}
	}
	q.Unsent = invites.MailUnsent(record)
	wl := waitlist.New(pool, tagger, cfg.Email.WebBaseURL)
	wl.MaxOpen, wl.MaxPending = int(cfg.Web.WaitlistMax), int(cfg.Web.WaitlistPendingMax)
	wl.ConfirmedRetention = cfg.Web.WaitlistRetention
	if p := cfg.Server.PurgeLedgerPath; p != "" {
		wl.Record = record
		ex.done = append(ex.done, startSweep(ctx, "restore ledger retention",
			countSweep("removed %d restore ledger entries past retention", func(context.Context) (int, error) {
				return purgeledger.Prune(p, time.Now().Add(-purgeledger.Retention))
			})))
	}
	if cfg.Ops.Enabled() {
		n := opsnotify.New(cfg.Ops.NtfyURL, cfg.Ops.NtfyClick)
		wl.OnConfirmed = func() {
			go func() {
				if err := n.Post(context.Background(), "Hasala", "New early-access request", "inbox_tray"); err != nil {
					slog.Warn("hasalad serve: early-access notice not delivered", "err", err)
				}
			}()
		}
	}
	wl.Register(q)
	if keys != nil {
		logf := func(format string, args ...any) { slog.Warn(fmt.Sprintf(format, args...)) }
		mailer := &auth.Mailer{Queue: q, Keys: keys, FreezeURL: cfg.Email.FreezeURL, Logf: logf}
		mailer.Register(q)
		gate := authkeys.NewGate(cfg.Auth.PasswordHashConcurrency, authkeys.DefaultGateQueue, authkeys.DefaultGateWait)
		srv.EnableAccounts(keys, gate, mailer)
		a := srv.Accounts
		ex.done = append(ex.done,
			startSweepEvery(ctx, "account ceremony sweep", ceremonySweepInterval,
				countSweep("swept %d expired ceremony(s)", a.SweepCeremonies)),
			startSweep(ctx, "account sweep", countSweep("swept %d row(s)", a.SweepHourly)),
		)
	} else {
		slog.Warn("hasalad serve: HASALA_AUTH_KEY_FILE and HASALA_SALT_KEY_FILE are not both set: " +
			"signup, password, recovery, reset, email-change and freeze routes are NOT mounted")
	}
	if tagger != nil {
		if cfg.Email.Enabled() {
			srv.Web = &api.WebOptions{Waitlist: wl, Origins: cfg.Web.Origins, DoneURL: cfg.Web.DoneURL,
				TurnstileRequired: cfg.Web.TurnstileRequired}
			if cfg.Web.TurnstileSecretFile != "" {
				secret, err := readSecret("HASALA_TURNSTILE_SECRET_FILE", cfg.Web.TurnstileSecretFile)
				if err != nil {
					return nil, err
				}
				v, err := turnstile.New(secret, cfg.Web.TurnstileHostnames)
				if err != nil {
					return nil, refusal{err}
				}
				srv.Web.Turnstile = v
			}
		}
		ex.done = append(ex.done, q.Run(ctx))
	} else {
		slog.Warn("hasalad serve: no HASALA_AUTH_KEY_FILE: the waitlist routes are not mounted and the email worker does not run")
	}
	ex.done = append(ex.done,
		startSweep(ctx, "invite sweep", func(ctx context.Context) (string, error) { return invites.Sweep(ctx, pool, record) }),
		startSweep(ctx, "waitlist sweep", wl.Sweep),
		startSweep(ctx, "mail log sweep", q.Sweep),
	)
	return ex, nil
}
