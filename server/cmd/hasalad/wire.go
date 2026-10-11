package main

// wire.go builds what serve runs beside the API: the APNs dispatcher, the
// Gmail link and hook, the email queue and its worker, and spec 07's website
// routes, each from its own configuration group, plus their sweeps.

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pushv2"
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

	// Gmail (spec 02 §13): all or nothing.
	if cfg.Gmail.Enabled() {
		raw, err := readSecret("HASALA_MAILBOX_ROUTE_KEY_FILE", cfg.Gmail.RouteKeyFile)
		if err != nil {
			return nil, err
		}
		rk, err := gmailpush.ParseRouteKey(raw)
		if err != nil {
			return nil, refusal{err}
		}
		if err := gmailpush.CheckKeyID(ctx, pool, rk); err != nil {
			return nil, refusal{err}
		}
		srv.Gmail = &api.GmailOptions{
			RouteKey:           rk,
			Link:               &googlejwt.Verifier{Audience: cfg.Gmail.IOSClientID},
			IOSClientID:        cfg.Gmail.IOSClientID,
			Hook:               &googlejwt.Verifier{Audience: cfg.Gmail.PubSubAudience},
			Subscription:       cfg.Gmail.PubSubSubscription,
			PushServiceAccount: cfg.Gmail.PubSubServiceAccount,
		}
		srv.Meta.GmailWatchTopic = cfg.Gmail.PubSubTopic
		ex.done = append(ex.done, startSweepEvery(ctx, "mailbox watch nudge", nudgeInterval,
			func(ctx context.Context) (string, error) { return gmailpush.Nudge(ctx, pool, waker) }))
	} else {
		slog.Warn("hasalad serve: the [gmail] group is not configured: the mailbox link and the Pub/Sub hook are not mounted")
	}

	// Email (spec 02 §14.4, spec 07 §6): Cloudflare when configured. Without
	// it every send fails permanently (mail.Unconfigured), so a queued email
	// ends `failed` in the log rather than `sent`, and the website routes are
	// not mounted: a sign-up whose confirmation can never arrive is worse than
	// no form.
	var sender mail.Sender
	if cfg.Email.Enabled() {
		tok, err := readSecret("HASALA_EMAIL_API_TOKEN_FILE", cfg.Email.APITokenFile)
		if err != nil {
			return nil, err
		}
		cf, err := mail.NewCloudflare(cfg.Email.CloudflareAccountID, strings.TrimSpace(tok), cfg.Email.From)
		if err != nil {
			return nil, refusal{err}
		}
		sender = cf
	} else {
		sender = mail.Unconfigured{}
		slog.Warn("hasalad serve: the [email] group is not configured: every email fails and the waitlist routes are not mounted")
	}

	// The auth key's email_tag is what the waitlist and the queue key on.
	var tagger mailq.Tagger
	if cfg.Auth.AuthKeyFile != "" {
		raw, err := readSecret("HASALA_AUTH_KEY_FILE", cfg.Auth.AuthKeyFile)
		if err != nil {
			return nil, err
		}
		k, err := authkeys.ParseKeyHex(raw)
		if err != nil {
			return nil, refusal{fmt.Errorf("HASALA_AUTH_KEY_FILE: %w", err)}
		}
		t, err := authkeys.NewEmailTagger(k)
		if err != nil {
			return nil, refusal{err}
		}
		tagger = t
	}

	q := mailq.New(pool, sender, tagger)
	q.Rates = map[mailq.Lane]int{mailq.LaneWaitlist: int(cfg.Web.RateWaitlist), mailq.LaneBulk: int(cfg.Web.RateBulk)}
	q.Retention = cfg.Web.LogRetention
	q.Register("test", mailq.TestRenderer)
	q.Register("invite", invites.Renderer{WebBase: cfg.Email.WebBaseURL, ManualTestFlight: true})
	wl := waitlist.New(pool, tagger, cfg.Email.WebBaseURL)
	wl.MaxOpen, wl.MaxPending = int(cfg.Web.WaitlistMax), int(cfg.Web.WaitlistPendingMax)
	wl.ConfirmedRetention = cfg.Web.WaitlistRetention
	wl.Register(q)
	if tagger != nil {
		if cfg.Email.Enabled() {
			srv.Web = &api.WebOptions{Waitlist: wl, Origins: cfg.Web.Origins, DoneURL: cfg.Web.DoneURL}
		}
		ex.done = append(ex.done, q.Run(ctx))
	} else {
		slog.Warn("hasalad serve: no HASALA_AUTH_KEY_FILE: the waitlist routes are not mounted and the email worker does not run")
	}
	ex.done = append(ex.done,
		startSweep(ctx, "invite sweep", func(ctx context.Context) (string, error) { return invites.Sweep(ctx, pool) }),
		startSweep(ctx, "waitlist sweep", wl.Sweep),
		startSweep(ctx, "mail log sweep", q.Sweep),
	)
	return ex, nil
}
