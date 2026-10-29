package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os/signal"
	"syscall"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/console"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

// runConsole is the operator console's mode (spec 07 §8): a separate process
// on its own loopback port and OS user, never mounted by serve. It refuses
// serve's secrets (fence F7-4), checks its own environment (§8.1) and serves
// the minimal console (internal/console) until SIGINT or SIGTERM.
//
// Until the hasala_console role exists (spec 05's role split) it connects
// with HASALA_PG_DSN like the other operator modes.
func runConsole(env *runEnv, args []string) error {
	fs := newFlags(env, "console")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := config.CheckConsoleEnvironment(env.environ); err != nil {
		return refusal{err}
	}
	cfg, err := env.load("console", nil)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	c := console.New(pool, cfg.Console.Host, cfg.Console.Tailnet, cfg.Console.Logins, cfg.Auth.InviteTTL)
	if p := cfg.Server.PurgeLedgerPath; p != "" {
		c.Record = func(e purgeledger.Entry) error { return purgeledger.AppendEntries(p, e) }
	}
	servers := []struct {
		addr, what string
		h          http.Handler
	}{{cfg.Console.Listen, "listening", c.Handler()}}
	if cfg.Console.MetricsListen != "" {
		servers = append(servers, struct {
			addr, what string
			h          http.Handler
		}{cfg.Console.MetricsListen, "healthz listening", c.HealthHandler()})
	}
	var running []*http.Server
	errc := make(chan error, len(servers))
	for _, sv := range servers {
		ln, err := net.Listen("tcp", sv.addr)
		if err != nil {
			for _, s := range running {
				_ = s.Close()
			}
			return fmt.Errorf("listen %s: %w", sv.addr, err)
		}
		srv := newHTTPServer(sv.h)
		running = append(running, srv)
		slog.Info("hasalad console: "+sv.what, "addr", ln.Addr().String())
		go func() {
			if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
				errc <- err
				return
			}
			errc <- nil
		}()
	}
	var serveErr error
	select {
	case serveErr = <-errc:
	case <-ctx.Done():
	}
	shutCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
	defer cancel()
	for _, srv := range running {
		if err := srv.Shutdown(shutCtx); err != nil && serveErr == nil {
			serveErr = err
		}
	}
	return serveErr
}
