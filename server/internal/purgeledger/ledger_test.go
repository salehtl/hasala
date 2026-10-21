package purgeledger

import (
	"bytes"
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

func testDevice() *Device {
	return &Device{
		WriterID:       "ios-" + uuid.NewString(),
		SignerWriterID: "ios-" + uuid.NewString(),
		FinalCounter:   7,
		FinalHead:      bytes.Repeat([]byte{0xab}, 32),
		Nonce:          bytes.Repeat([]byte{0x01}, 32),
		Sig:            bytes.Repeat([]byte{0x02}, 64),
	}
}

func TestEveryKindRoundTripsAndOnlyPurgesAreAccountsToPurge(t *testing.T) {
	path := filepath.Join(t.TempDir(), "purged")
	at := time.Date(2026, 10, 21, 8, 0, 0, 0, time.UTC)
	gone, frozen, removed, changed, left := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	thawed, keyless, bounced := uuid.New(), uuid.New(), uuid.New()
	cred := bytes.Repeat([]byte{0xc4}, 16)
	long := bytes.Repeat([]byte{0x5e}, 1023)
	d := testDevice()
	want := []Entry{
		{ID: gone, At: at},
		{ID: frozen, At: at, Kind: KindFreeze, Trigger: at.Add(-time.Hour)},
		{ID: removed, At: at, Kind: KindDevice, Device: d},
		{ID: changed, At: at, Kind: KindPassword},
		{ID: left, At: at, Kind: KindWaitlistLeave},
		{ID: thawed, At: at, Kind: KindUnfreeze},
		{ID: keyless, At: at, Kind: KindPasskey, Credential: cred},
		{ID: keyless, At: at, Kind: KindPasskey, Credential: long},
		{ID: bounced, At: at, Kind: KindWaitlistUnsent},
	}
	if err := AppendEntries(path, want...); err != nil {
		t.Fatal(err)
	}
	got, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(want) {
		t.Fatalf("%d entries, want %d", len(got), len(want))
	}
	for i := range want {
		g, w := got[i], want[i]
		if g.ID != w.ID || !g.At.Equal(w.At) || g.Kind != w.Kind || !g.Trigger.Equal(w.Trigger) ||
			!bytes.Equal(g.Credential, w.Credential) {
			t.Fatalf("entry %d: %+v, want %+v", i, g, w)
		}
		if (w.Device == nil) != (g.Device == nil) {
			t.Fatalf("entry %d: device %+v", i, g.Device)
		}
		if w.Device != nil {
			gd := g.Device
			if gd.WriterID != d.WriterID || gd.SignerWriterID != d.SignerWriterID || gd.FinalCounter != d.FinalCounter ||
				!bytes.Equal(gd.FinalHead, d.FinalHead) || !bytes.Equal(gd.Nonce, d.Nonce) || !bytes.Equal(gd.Sig, d.Sig) {
				t.Fatalf("device %+v, want %+v", gd, d)
			}
		}
	}
	if ids := IDs(got); len(ids) != 1 || ids[0] != gone {
		t.Fatalf("accounts to purge %v, want only %v", ids, gone)
	}
	raw, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(raw), gone.String()+" 2026-10-21T08:00:00Z\n") {
		t.Fatalf("a purge is no longer written in the first format: %q", raw)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if strings.Contains(line, "@") {
			t.Fatalf("a line holds an address: %q", line)
		}
	}
}

func TestAFirstFormatLedgerStillReads(t *testing.T) {
	path := filepath.Join(t.TempDir(), "purged")
	a, b := uuid.New(), uuid.New()
	body := a.String() + " 2026-09-01T10:00:00Z\n" + b.String() + " 2026-09-02T10:00:00+04:00\n"
	if err := os.WriteFile(path, []byte(body), 0o640); err != nil {
		t.Fatal(err)
	}
	entries, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if ids := IDs(entries); len(ids) != 2 || ids[0] != a || ids[1] != b || entries[1].Kind != KindPurge {
		t.Fatalf("entries %+v", entries)
	}
	if err := AppendEntries(path, Entry{ID: uuid.New(), At: time.Date(2026, 9, 3, 0, 0, 0, 0, time.UTC), Kind: KindPassword}); err != nil {
		t.Fatal(err)
	}
	if entries, err = Read(path); err != nil || len(entries) != 3 || len(IDs(entries)) != 2 {
		t.Fatalf("after an event: %+v %v", entries, err)
	}
}

func TestAMalformedEventIsAnError(t *testing.T) {
	id := uuid.NewString()
	w := "ios-" + uuid.NewString()
	h32, h64 := strings.Repeat("ab", 32), strings.Repeat("cd", 64)
	at := " 2026-10-20T05:30:00Z "
	for name, line := range map[string]string{
		"unknown kind":         id + at + "spare",
		"passkey without id":   id + at + "passkey",
		"passkey short id":     id + at + "passkey " + h32[:30],
		"passkey odd hex":      id + at + "passkey " + h32 + "a",
		"passkey upper hex":    id + at + "passkey " + strings.ToUpper(h32),
		"passkey long id":      id + at + "passkey " + strings.Repeat("ab", 1024),
		"passkey after":        id + at + "passkey " + h32 + " x",
		"unsent with field":    id + at + "waitlist-unsent x",
		"password with field":  id + at + "password x",
		"leave with field":     id + at + "waitlist-leave x",
		"freeze without time":  id + at + "freeze",
		"freeze bad time":      id + at + "freeze soon",
		"freeze after":         id + at + "freeze 2026-10-20T05:30:00Z extra",
		"device short":         id + at + "device " + w + " " + w + " 1 " + h32 + " " + h32,
		"device bad writer":    id + at + "device dev-a " + w + " 1 " + h32 + " " + h32 + " " + h64,
		"device bad counter":   id + at + "device " + w + " " + w + " -1 " + h32 + " " + h32 + " " + h64,
		"device padded count":  id + at + "device " + w + " " + w + " 01 " + h32 + " " + h32 + " " + h64,
		"device short head":    id + at + "device " + w + " " + w + " 1 " + h32[:62] + " " + h32 + " " + h64,
		"device upper hex":     id + at + "device " + w + " " + w + " 1 " + strings.ToUpper(h32) + " " + h32 + " " + h64,
		"device short sig":     id + at + "device " + w + " " + w + " 1 " + h32 + " " + h32 + " " + h32,
		"double space":         id + "  2026-10-20T05:30:00Z",
		"trailing space":       id + " 2026-10-20T05:30:00Z ",
		"zero id on an event":  uuid.Nil.String() + at + "password",
		"freeze trigger empty": id + at + "freeze ",
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "purged")
			if err := os.WriteFile(path, []byte(line+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := Read(path); err == nil {
				t.Fatalf("%q was read", line)
			}
		})
	}
}

func TestAppendEntriesRefusesWhatItCannotReadBack(t *testing.T) {
	path := filepath.Join(t.TempDir(), "purged")
	at := time.Now()
	bad := testDevice()
	bad.Sig = bad.Sig[:10]
	for name, e := range map[string]Entry{
		"zero id":                {At: at, Kind: KindPassword},
		"unknown kind":           {ID: uuid.New(), At: at, Kind: "spare"},
		"passkey without id":     {ID: uuid.New(), At: at, Kind: KindPasskey},
		"passkey short id":       {ID: uuid.New(), At: at, Kind: KindPasskey, Credential: make([]byte, 15)},
		"passkey long id":        {ID: uuid.New(), At: at, Kind: KindPasskey, Credential: make([]byte, 1024)},
		"passkey with trigger":   {ID: uuid.New(), At: at, Kind: KindPasskey, Credential: make([]byte, 16), Trigger: at},
		"password with id":       {ID: uuid.New(), At: at, Kind: KindPassword, Credential: make([]byte, 16)},
		"unsent with trigger":    {ID: uuid.New(), At: at, Kind: KindWaitlistUnsent, Trigger: at},
		"freeze without trigger": {ID: uuid.New(), At: at, Kind: KindFreeze},
		"device without device":  {ID: uuid.New(), At: at, Kind: KindDevice},
		"device short sig":       {ID: uuid.New(), At: at, Kind: KindDevice, Device: bad},
		"password with trigger":  {ID: uuid.New(), At: at, Kind: KindPassword, Trigger: at},
		"unfreeze with trigger":  {ID: uuid.New(), At: at, Kind: KindUnfreeze, Trigger: at},
		"purge with device":      {ID: uuid.New(), At: at, Device: testDevice()},
	} {
		if err := AppendEntries(path, e); err == nil {
			t.Errorf("%s was written", name)
		}
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("a refused entry created the ledger: %v", err)
	}
}

func TestAppendKeepsEntriesPastRetentionUntilAPrune(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)
	path := filepath.Join(t.TempDir(), "purged")
	now := time.Date(2026, 10, 21, 0, 0, 0, 0, time.UTC)
	stale, fresh := uuid.New(), uuid.New()
	if err := AppendEntries(path, Entry{ID: stale, At: now.Add(-Retention - time.Hour), Kind: KindFreeze,
		Trigger: now.Add(-Retention - 2*time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := AppendEntries(path, Entry{ID: fresh, At: now, Kind: KindWaitlistLeave}); err != nil {
		t.Fatal(err)
	}
	entries, err := Read(path)
	if err != nil || len(entries) != 2 || entries[0].ID != stale || entries[1].ID != fresh {
		t.Fatalf("after an append %+v %v, want both entries", entries, err)
	}
	if n, err := Prune(path, now.Add(-Retention)); n != 1 || err != nil {
		t.Fatalf("prune dropped %d (%v), want 1", n, err)
	}
	entries, err = Read(path)
	if err != nil || len(entries) != 1 || entries[0].ID != fresh {
		t.Fatalf("after a prune %+v %v, want only the fresh entry", entries, err)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != FileMode {
		t.Fatalf("mode %v", st.Mode().Perm())
	}
}
