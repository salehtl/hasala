package purgeledger

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestAppendCreatesAGroupReadableFileAndReadsBack(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)
	path := filepath.Join(t.TempDir(), "purged")
	a, b := uuid.New(), uuid.New()
	at := time.Date(2026, 10, 20, 9, 30, 0, 0, time.FixedZone("GST", 4*3600))
	if err := Append(path, []uuid.UUID{a}, at); err != nil {
		t.Fatal(err)
	}
	if err := Append(path, []uuid.UUID{b, a}, at.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != FileMode {
		t.Fatalf("mode %v, want %v", st.Mode().Perm(), FileMode)
	}
	raw, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(raw), a.String()+" 2026-10-20T05:30:00Z\n") {
		t.Fatalf("ledger %q: want the id and the UTC time", raw)
	}
	entries, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 || entries[0].ID != a || entries[1].ID != b || entries[2].ID != a {
		t.Fatalf("entries %v", entries)
	}
	if ids := IDs(entries); len(ids) != 2 || ids[0] != a || ids[1] != b {
		t.Fatalf("ids %v", ids)
	}
}

func TestAMissingLedgerIsEmpty(t *testing.T) {
	entries, err := Read(filepath.Join(t.TempDir(), "purged"))
	if err != nil || entries != nil {
		t.Fatalf("%v %v", entries, err)
	}
	if n, err := Prune(filepath.Join(t.TempDir(), "purged"), time.Now()); n != 0 || err != nil {
		t.Fatalf("prune of nothing: %d %v", n, err)
	}
}

func TestAppendRefusesWhatItCannotRecord(t *testing.T) {
	if err := Append("", []uuid.UUID{uuid.New()}, time.Now()); err == nil {
		t.Fatal("no path was accepted")
	}
	if err := Append(filepath.Join(t.TempDir(), "purged"), []uuid.UUID{uuid.Nil}, time.Now()); err == nil {
		t.Fatal("the zero id was accepted")
	}
	if err := Append(filepath.Join(t.TempDir(), "missing", "purged"), []uuid.UUID{uuid.New()}, time.Now()); err == nil {
		t.Fatal("a ledger in a missing directory was accepted")
	}
}

func TestAMalformedLedgerIsAnError(t *testing.T) {
	id := uuid.NewString()
	for name, body := range map[string]string{
		"no time":        id + "\n",
		"bad time":       id + " yesterday\n",
		"bad id":         "not-an-id 2026-10-20T05:30:00Z\n",
		"zero id":        uuid.Nil.String() + " 2026-10-20T05:30:00Z\n",
		"braced id":      "{" + id + "} 2026-10-20T05:30:00Z\n",
		"blank line":     id + " 2026-10-20T05:30:00Z\n\n",
		"truncated last": id + " 2026-10-20T05:30:00Z\n" + id[:10],
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "purged")
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := Read(path); err == nil {
				t.Fatalf("%q was read", body)
			}
		})
	}
}

func TestPruneDropsOnlyEntriesPastTheCutoff(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)
	path := filepath.Join(t.TempDir(), "purged")
	now := time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC)
	gone, kept := uuid.New(), uuid.New()
	if err := Append(path, []uuid.UUID{gone}, now.Add(-Retention-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := Append(path, []uuid.UUID{kept}, now.Add(-Retention+time.Hour)); err != nil {
		t.Fatal(err)
	}
	n, err := Prune(path, now.Add(-Retention))
	if err != nil || n != 1 {
		t.Fatalf("pruned %d (%v), want 1", n, err)
	}
	entries, err := Read(path)
	if err != nil || len(entries) != 1 || entries[0].ID != kept {
		t.Fatalf("after prune %v %v", entries, err)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != FileMode {
		t.Fatalf("mode after prune %v", st.Mode().Perm())
	}
	if n, err := Prune(path, now.Add(-Retention)); n != 0 || err != nil {
		t.Fatalf("second prune %d %v", n, err)
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("the temporary file stayed: %v", err)
	}
}
