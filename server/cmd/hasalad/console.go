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
	ln, err := net.Listen("tcp", cfg.Console.Listen)
	if err != nil {
		return fmt.Errorf("listen %s: %w", cfg.Console.Listen, err)
	}
	srv := newHTTPServer(c.Handler())
	errc := make(chan error, 1)
	go func() {
		slog.Info("hasalad console: listening", "addr", ln.Addr().String())
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
	shutCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutCtx); err != nil && serveErr == nil {
		serveErr = err
	}
	return serveErr
}
