package pgtest_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

type detachedCluster struct {
	dsn, stop, dir string
}

var (
	bootURLLine  = regexp.MustCompile(`HASALA_TEST_POSTGRES_URL="([^"]+)"`)
	bootStopLine = regexp.MustCompile(`PG_STOP="([^"]+)"`)
)

func privateTemp(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "pgr-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func startOwner(t *testing.T) *exec.Cmd {
	t.Helper()
	owner := exec.Command("sleep", "120")
	if err := owner.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = owner.Process.Kill()
		_ = owner.Wait()
	})
	return owner
}

func bootDetached(t *testing.T, tmp string, args ...string) detachedCluster {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "boot")
	if out, err := exec.Command("go", "build", "-o", bin, "./cmd/boot").CombinedOutput(); err != nil {
		t.Fatalf("build cmd/boot: %v: %s", err, out)
	}
	log, err := os.Create(filepath.Join(t.TempDir(), "boot.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), "TMPDIR="+tmp)
	cmd.Stderr = log
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("run cmd/boot: %v", err)
	}
	dsn := bootURLLine.FindSubmatch(out)
	stop := bootStopLine.FindSubmatch(out)
	if dsn == nil || stop == nil {
		t.Fatalf("cmd/boot printed %q", out)
	}
	c := detachedCluster{dsn: string(dsn[1]), stop: string(stop[1]), dir: filepath.Dir(string(stop[1]))}
	t.Cleanup(func() {
		if _, err := os.Stat(c.stop); err == nil {
			_ = exec.Command(c.stop).Run()
		}
	})
	return c
}

func pingCluster(c detachedCluster) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, c.dsn)
	if err != nil {
		return err
	}
	defer pool.Close()
	return pool.Ping(ctx)
}

func requireServing(t *testing.T, c detachedCluster) {
	t.Helper()
	if err := pingCluster(c); err != nil {
		t.Fatalf("the cluster stopped serving: %v", err)
	}
	if _, err := os.Stat(filepath.Join(c.dir, "data")); err != nil {
		t.Fatalf("the cluster's data directory is gone: %v", err)
	}
}

func requireReaped(t *testing.T, c detachedCluster) {
	t.Helper()
	if _, err := os.Stat(c.dir); !os.IsNotExist(err) {
		t.Fatalf("the cluster's directory is still there: %v", err)
	}
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		if pingCluster(c) != nil {
			return
		}
	}
	t.Fatal("the cluster still answers after the reap")
}

func TestReapSparesAClusterWhoseOwnerIsRunning(t *testing.T) {
	tmp := privateTemp(t)
	owner := startOwner(t)
	c := bootDetached(t, tmp, "-owner", strconv.Itoa(owner.Process.Pid))
	t.Setenv("TMPDIR", tmp)
	if _, err := pgtest.ReapOrphans(); err != nil {
		t.Fatal(err)
	}
	requireServing(t, c)
}

func TestReapTakesAClusterWhoseOwnerIsGoneFromAnyTempDir(t *testing.T) {
	tmp := privateTemp(t)
	owner := startOwner(t)
	c := bootDetached(t, tmp, "-owner", strconv.Itoa(owner.Process.Pid))
	if err := owner.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = owner.Wait()
	t.Setenv("TMPDIR", privateTemp(t))
	n, err := pgtest.ReapOrphans()
	if err != nil {
		t.Fatal(err)
	}
	if n < 1 {
		t.Fatalf("reaped %d clusters", n)
	}
	requireReaped(t, c)
}

func TestReapLeavesAClusterThatNamesNoOwner(t *testing.T) {
	tmp := privateTemp(t)
	c := bootDetached(t, tmp)
	t.Setenv("TMPDIR", tmp)
	if _, err := pgtest.ReapOrphans(); err != nil {
		t.Fatal(err)
	}
	requireServing(t, c)
}
