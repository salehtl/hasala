package main

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestServeExitsWhenItCannotListenWithTheMailWorkerRunning(t *testing.T) {
	pool := pgtest.New(t)
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	dir := t.TempDir()
	key := filepath.Join(dir, "auth")
	if err := os.WriteFile(key, []byte(strings.Repeat("cd", 32)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	env := []string{
		"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_RP_ID=hasala.app", "HASALA_RP_ORIGINS=https://hasala.app",
		"HASALA_HTTP_LISTEN=" + busy.Addr().String(), "HASALA_HEADROOM_PATH=" + dir, "HASALA_HEADROOM_FLOOR_BYTES=1",
		"HASALA_AUTH_KEY_FILE=" + key,
	}
	type result struct {
		code int
		msg  string
	}
	exited := make(chan result, 1)
	go func() {
		code, _, msg := hasalad(t, env, "serve")
		exited <- result{code, msg}
	}()
	select {
	case r := <-exited:
		if r.code != 1 || !strings.Contains(r.msg, "listen") {
			t.Fatalf("serve exited %d (%s), want the listen failure", r.code, r.msg)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("serve did not exit after the listen failure")
	}
}

func TestWorkersOutliveTheHTTPDrain(t *testing.T) {
	signalled, signal := context.WithCancel(context.Background())
	defer signal()
	s := newServeStop(signalled, func() {})
	entered, release := make(chan struct{}), make(chan struct{})
	workersDuringDrain := make(chan error, 1)
	srv := newHTTPServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		close(entered)
		<-release
		workersDuringDrain <- s.workers.Err()
	}))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	served := make(chan error, 1)
	go func() { served <- s.serve(srv, ln) }()
	go func() {
		if resp, err := http.Get("http://" + ln.Addr().String() + "/"); err == nil {
			resp.Body.Close()
		}
	}()
	<-entered
	signal()
	time.Sleep(50 * time.Millisecond)
	close(release)
	if err := <-workersDuringDrain; err != nil {
		t.Fatalf("the workers stopped while a request was still running: %v", err)
	}
	if err := <-served; err != nil {
		t.Fatal(err)
	}
	s.finish()
	if s.workers.Err() == nil {
		t.Fatal("finish left the workers running")
	}
}

func TestFinishStopsTheWorkersBeforeItClosesThePool(t *testing.T) {
	var closedAfterWorker atomic.Bool
	worker := make(chan struct{})
	s := newServeStop(context.Background(), func() {
		select {
		case <-worker:
			closedAfterWorker.Store(true)
		default:
		}
	})
	go func() {
		<-s.workers.Done()
		close(worker)
	}()
	s.watch(worker)
	s.finish()
	if !closedAfterWorker.Load() {
		t.Fatal("the pool closed before the worker stopped")
	}
}

func TestFinishGivesUpOnAWorkerThatDoesNotStop(t *testing.T) {
	var closed atomic.Bool
	s := newServeStop(context.Background(), func() { closed.Store(true) })
	s.limit = 50 * time.Millisecond
	s.watch(make(chan struct{}))
	finished := make(chan struct{})
	go func() {
		s.finish()
		close(finished)
	}()
	select {
	case <-finished:
	case <-time.After(10 * time.Second):
		t.Fatal("finish waited past its limit")
	}
	if closed.Load() {
		t.Fatal("the pool closed while a worker still held it")
	}
}

func TestServeRaisesTheGenerationWhenTheDatabaseWasReplaced(t *testing.T) {
	pool := pgtest.New(t)
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	dir := t.TempDir()
	generation := filepath.Join(dir, "generation")
	if err := os.WriteFile(generation+".seal", []byte("1 1\n"), 0o660); err != nil {
		t.Fatal(err)
	}
	env := []string{
		"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_RP_ID=hasala.app", "HASALA_RP_ORIGINS=https://hasala.app",
		"HASALA_HTTP_LISTEN=" + busy.Addr().String(), "HASALA_HEADROOM_PATH=" + dir, "HASALA_HEADROOM_FLOOR_BYTES=1",
		"HASALA_LOG_GENERATION_FILE=" + generation,
	}
	if code, _, msg := hasalad(t, env, "serve"); code != 1 || !strings.Contains(msg, "listen") {
		t.Fatalf("serve exited %d (%s), want the listen failure", code, msg)
	}
	if b, err := os.ReadFile(generation); err != nil || strings.TrimSpace(string(b)) != "2" {
		t.Fatalf("generation %q, %v, want 2", b, err)
	}
	if code, _, msg := hasalad(t, env, "serve"); code != 1 || !strings.Contains(msg, "listen") {
		t.Fatalf("a second serve exited %d (%s), want the listen failure", code, msg)
	}
	if b, err := os.ReadFile(generation); err != nil || strings.TrimSpace(string(b)) != "2" {
		t.Fatalf("generation %q, %v after a second start of the same database", b, err)
	}
}
