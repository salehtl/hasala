package privatefixtures

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// recorder stands in for the calling test. Skipf and Fatalf end the call the
// way the real ones do (they never return), by panicking with what was said.
type recorder struct {
	testing.TB
	logs []string
}

type stopped struct{ kind, msg string }

func (r *recorder) Helper() {}
func (r *recorder) Logf(format string, args ...any) {
	r.logs = append(r.logs, fmt.Sprintf(format, args...))
}
func (r *recorder) Skipf(format string, args ...any) {
	panic(stopped{"skip", fmt.Sprintf(format, args...)})
}
func (r *recorder) Fatalf(format string, args ...any) {
	panic(stopped{"fatal", fmt.Sprintf(format, args...)})
}

// call runs Path against a recorder and reports how it ended.
func call(t *testing.T, rel string) (kind, msg, path string, logs []string) {
	t.Helper()
	r := &recorder{TB: t}
	defer func() {
		if v := recover(); v != nil {
			s, ok := v.(stopped)
			if !ok {
				panic(v)
			}
			kind, msg, logs = s.kind, s.msg, r.logs
		}
	}()
	path = Path(r, rel)
	return "ran", "", path, r.logs
}

func TestUnsetSkipsWithANamedReason(t *testing.T) {
	t.Setenv(EnvVar, "")
	kind, msg, _, _ := call(t, "conformance/normalizer/dib-arabic-01.json")
	if kind != "skip" {
		t.Fatalf("got %s, want a skip", kind)
	}
	for _, want := range []string{Marker, EnvVar, "conformance/normalizer/dib-arabic-01.json", Repo} {
		if !strings.Contains(msg, want) {
			t.Errorf("skip reason %q does not name %q", msg, want)
		}
	}
	if !strings.HasPrefix(msg, Marker) {
		t.Errorf("skip reason %q must start with %s; scripts/gotest-summary.ts counts on it", msg, Marker)
	}
}

func TestSetAndPresentRunsAndSaysSo(t *testing.T) {
	root := t.TempDir()
	rel := "server/internal/origin/testdata/x.eml"
	if err := os.MkdirAll(filepath.Join(root, filepath.Dir(rel)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, rel), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv(EnvVar, root)
	kind, _, path, logs := call(t, rel)
	if kind != "ran" {
		t.Fatalf("got %s, want the file", kind)
	}
	if path != filepath.Join(root, rel) {
		t.Fatalf("path = %q", path)
	}
	if len(logs) != 1 || !strings.Contains(logs[0], Marker) {
		t.Fatalf("logs = %q, want one %s line so the gate can count the run", logs, Marker)
	}
}

// A configured checkout that lacks the file is broken, and must not pass as a
// quiet skip.
func TestSetButMissingFails(t *testing.T) {
	t.Setenv(EnvVar, t.TempDir())
	if kind, msg, _, _ := call(t, "conformance/templates/corpus-dib.card.v1.json"); kind != "fatal" {
		t.Fatalf("got %s (%s), want a failure", kind, msg)
	}
}

func TestARelativeCheckoutPathFails(t *testing.T) {
	t.Setenv(EnvVar, "../hasala-fixtures")
	if kind, msg, _, _ := call(t, "conformance/normalizer"); kind != "fatal" || !strings.Contains(msg, "absolute") {
		t.Fatalf("got %s (%s), want a failure naming the absolute-path rule", kind, msg)
	}
}

func TestReadFileReturnsTheBytes(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "f.json"), []byte(`{"a":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv(EnvVar, root)
	// Through a recorder, so this test's own output carries no marker line and
	// the gate does not count it as a real-corpus run.
	if got := string(ReadFile(&recorder{TB: t}, "f.json")); got != `{"a":1}` {
		t.Fatalf("ReadFile = %q", got)
	}
}
