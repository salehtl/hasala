package purgeledger

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestAWrapLineReadsBack(t *testing.T) {
	path := filepath.Join(t.TempDir(), "purged")
	id, cred := uuid.New(), bytes.Repeat([]byte{0xab}, 20)
	at := time.Date(2026, 10, 20, 9, 30, 0, 0, time.UTC)
	if err := AppendEntries(path, Entry{ID: id, At: at, Kind: KindWrap, Credential: cred}); err != nil {
		t.Fatal(err)
	}
	entries, err := Read(path)
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries %+v %v", entries, err)
	}
	e := entries[0]
	if e.Kind != KindWrap || e.ID != id || !e.At.Equal(at) || !bytes.Equal(e.Credential, cred) {
		t.Fatalf("entry %+v", e)
	}
}

func TestAMalformedWrapLineFailsTheLedger(t *testing.T) {
	id := uuid.New().String()
	at := " 2026-10-20T05:30:00Z "
	for name, line := range map[string]string{
		"no credential":    id + at + "wrap",
		"short credential": id + at + "wrap abcd",
		"upper hex":        id + at + "wrap ABABABABABABABABABABABABABABABAB",
		"extra field":      id + at + "wrap abababababababababababababababab x",
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

func TestAWrapEntryNeedsACredentialAndNothingElse(t *testing.T) {
	path := filepath.Join(t.TempDir(), "purged")
	at := time.Now()
	for name, e := range map[string]Entry{
		"without id":   {ID: uuid.New(), At: at, Kind: KindWrap},
		"short id":     {ID: uuid.New(), At: at, Kind: KindWrap, Credential: make([]byte, 15)},
		"with trigger": {ID: uuid.New(), At: at, Kind: KindWrap, Credential: make([]byte, 16), Trigger: at},
		"with device":  {ID: uuid.New(), At: at, Kind: KindWrap, Credential: make([]byte, 16), Device: testDevice()},
	} {
		if err := AppendEntries(path, e); err == nil {
			t.Errorf("%s was written", name)
		}
	}
}
