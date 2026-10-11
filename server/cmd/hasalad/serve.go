package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/headroom"
	"github.com/salehtl/hasala/server/internal/pg"
)

// HTTP server limits (spec 02 §18.4). There is no TLS code in hasalad at all
// (F3): the listener is plain HTTP on loopback, behind Cloudflare Tunnel.
const (
	readHeaderTimeout = 10 * time.Second
	readTimeout       = 180 * time.Second
	writeTimeout      = 120 * time.Second
	idleTimeout       = 120 * time.Second
	maxHeaderBytes    = 64 << 10
	shutdownTimeout   = 15 * time.Second
	sweepInterval     = time.Hour
)

// runServe serves the API until SIGINT or SIGTERM.
//
// Order, and why: refuse a mis-wired unit (console or App Store Connect
// variables, F7-4) before reading anything; load and validate the
// configuration; connect as the runtime role and run the startup refusals
// O1–O8 (internal/pg.CheckServing) — serve never migrates, `hasalad migrate`
// does, as the schema owner, before serve starts; then the disk fuse, the
// sweeps and the listener.
func runServe(env *runEnv, args []string) error {
	fs := newFlags(env, "serve")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := config.CheckServeEnvironment(env.environ); err != nil {
		return refusal{err}
	}
	cfg, err := env.load("serve", nil)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := pg.Open(ctx, cfg.PGDSN)
	if err != nil {
		return fmt.Errorf("open postgres: %w", err)
	}
	defer pool.Close()
	if err := pg.CheckServing(ctx, pool, func(msg string) { slog.Warn(msg) }); err != nil {
		return err
	}

	srvAPI, err := api.NewServer(cfg, pool)
	if err != nil {
		return err
	}
	fuse := startHeadroom(cfg, srvAPI)
	defer fuse.Stop()
	logGroups(cfg)

	sweeps := []<-chan struct{}{
		startSweep(ctx, "deleted-account tombstone sweep", tombstoneSweep(srvAPI.Sessions)),
	}
	if srvAPI.Passkeys != nil {
		sweeps = append(sweeps, startSweep(ctx, "passkey ceremony sweep", ceremonySweep(srvAPI.Passkeys)))
	}

	// Re-checked immediately before the listener, for a Config assembled in
	// code rather than through Load.
	if !config.IsLoopbackListen(cfg.Server.HTTPListen) {
		return refusal{fmt.Errorf("server.http_listen %q is not loopback", cfg.Server.HTTPListen)}
	}
	ln, err := net.Listen("tcp", cfg.Server.HTTPListen)
	if err != nil {
		return fmt.Errorf("listen %s: %w", cfg.Server.HTTPListen, err)
	}
	srv := newHTTPServer(srvAPI.Handler())
	errc := make(chan error, 1)
	go func() {
		slog.Info("hasalad serve: listening", "addr", ln.Addr().String(), "tls", false)
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errc <- err
			return
		}
		errc <- nil
	}()

	var serveErr error
	select {
	case serveErr = <-errc:
	case <-ctx.Done():
	}
	slog.Info("hasalad serve: shutting down")
	shutCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutCtx); err != nil && serveErr == nil {
		serveErr = fmt.Errorf("shutdown: %w", err)
	}
	stop()
	for _, done := range sweeps {
		<-done
	}
	return serveErr
}

func newHTTPServer(h http.Handler) *http.Server {
	return &http.Server{
		Handler:           h,
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		MaxHeaderBytes:    maxHeaderBytes,
	}
}

// logGroups logs which optional configuration groups are enabled, names only
// (spec 02 §18.2), and says out loud what is configured but not built yet.
func logGroups(cfg config.Config) {
	var on []string
	if cfg.APNs.Enabled {
		on = append(on, "apns")
	}
	if cfg.Gmail.Enabled() {
		on = append(on, "gmail")
	}
	if cfg.Email.Enabled() {
		on = append(on, "email")
	}
	if cfg.Server.MetricsListen != "" {
		on = append(on, "metrics")
	}
	slog.Info("hasalad serve: optional groups", "enabled", strings.Join(on, ","),
		"trusted_proxy", cfg.Server.TrustedProxy)
	if len(on) > 0 {
		// The configuration is validated so deployments can be prepared; the
		// senders, the hook and the metrics listener are WS-4's and WS-5's.
		slog.Warn("hasalad serve: these groups are configured but not served by this build yet",
			"groups", strings.Join(on, ","))
	}
}

// startHeadroom builds the disk fuse, STARTS it (Start samples synchronously,
// so the flag is the truth about this box before the first request) and hands
// it to the API: below the floor every durable write is refused, sign-in
// included, while reads keep serving.
func startHeadroom(cfg config.Config, s *api.Server) *headroom.Fuse {
	fuse := headroom.New(cfg.Headroom.Path, uint64(cfg.Headroom.FloorBytes), cfg.Headroom.Interval)
	fuse.Start()
	s.Headroom = fuse
	slog.Info("hasalad serve: headroom fuse", "path", fuse.Path(), "every", cfg.Headroom.Interval.String(),
		"floor_bytes", fuse.Floor())
	return fuse
}

func tombstoneSweep(s *auth.Sessions) func(context.Context) (string, error) {
	return func(ctx context.Context) (string, error) {
		n, err := s.ReapDeletedAccountTombstones(ctx)
		if err != nil || n == 0 {
			return "", err
		}
		return fmt.Sprintf("reaped %d expired deleted-account tombstone(s)", n), nil
	}
}

func ceremonySweep(p *auth.Passkeys) func(context.Context) (string, error) {
	return func(ctx context.Context) (string, error) {
		n, err := p.ReapExpiredCeremonies(ctx)
		if err != nil || n == 0 {
			return "", err
		}
		return fmt.Sprintf("reaped %d expired passkey ceremony(s)", n), nil
	}
}

// startSweep runs one job now and then hourly until ctx is done (spec 02
// §9.7), returning a channel that closes when it has stopped. A failed sweep
// is logged and the loop continues: one failure is a transient database
// problem, and stopping would silently end every future sweep.
func startSweep(ctx context.Context, name string, run func(context.Context) (string, error)) <-chan struct{} {
	return startSweepEvery(ctx, name, sweepInterval, run)
}

func startSweepEvery(ctx context.Context, name string, every time.Duration, run func(context.Context) (string, error)) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		tick := time.NewTicker(every)
		defer tick.Stop()
		for {
			// Detached from ctx's cancellation but bounded on its own, so a
			// shutdown arriving mid-sweep does not abort a transaction.
			sweepCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Minute)
			msg, err := run(sweepCtx)
			cancel()
			switch {
			case err != nil:
				slog.Error("hasalad serve: sweep failed", "sweep", name, "err", err.Error())
			case msg != "":
				slog.Info("hasalad serve: sweep", "sweep", name, "result", msg)
			}
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
			}
		}
	}()
	return done
}

// openRuntime connects with HASALA_PG_DSN and runs the startup refusals: the
// shared prologue of every operator mode except migrate (spec 02 §5.6).
func openRuntime(ctx context.Context, cfg config.Config) (*pgxpool.Pool, error) {
	pool, err := pg.Open(ctx, cfg.PGDSN)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}
	if err := pg.CheckServing(ctx, pool, func(msg string) { slog.Warn(msg) }); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}
