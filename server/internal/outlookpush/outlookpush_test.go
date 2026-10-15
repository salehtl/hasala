package outlookpush

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// Synthetic clientStates: 43 base64url characters, like the link's.
var (
	csA = strings.Repeat("A", 42) + "a"
	csB = strings.Repeat("b", 42) + "_"
)

func TestValidToken(t *testing.T) {
	for tok, want := range map[string]bool{
		"":                          false,
		"abc":                       true,
		"Validation: Token ~ 1 2 3": true,
		strings.Repeat("x", 256):    true,
		strings.Repeat("x", 257):    false,
		"tab\there":                 false,
		"line\nbreak":               false,
		"del\x7f":                   false,
		"café":                      false,
	} {
		if got := ValidToken(tok); got != want {
			t.Errorf("ValidToken(%q) = %v, want %v", tok, got, want)
		}
	}
}

func body(t *testing.T, entries ...map[string]any) []byte {
	t.Helper()
	b, err := json.Marshal(map[string]any{"value": entries})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestParse(t *testing.T) {
	ha, hb := sha256.Sum256([]byte(csA)), sha256.Sum256([]byte(csB))
	msg := map[string]any{"clientState": csA, "changeType": "created", "resource": "Users/x/Messages/y",
		"resourceData": map[string]any{"id": "y"}}

	// Duplicates collapse; order of first appearance; bad shapes are counted.
	p, err := Parse(body(t, msg, map[string]any{"clientState": csB}, msg,
		map[string]any{"clientState": "short"}, map[string]any{}, map[string]any{"clientState": 7},
		map[string]any{"clientState": strings.Repeat("A", 42) + "="}), false)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Hashes) != 2 || p.Hashes[0] != ha || p.Hashes[1] != hb || p.BadClientState != 4 || p.Ignored != 0 {
		t.Fatalf("parsed %+v", p)
	}

	// The lifecycle path wakes only for the three events.
	p, err = Parse(body(t,
		map[string]any{"clientState": csA, "lifecycleEvent": EventReauthorizationRequired},
		map[string]any{"clientState": csB, "lifecycleEvent": "somethingNew"},
		map[string]any{"clientState": csB}), true)
	if err != nil || len(p.Hashes) != 1 || p.Hashes[0] != ha || p.Ignored != 2 {
		t.Fatalf("lifecycle parsed %+v %v", p, err)
	}
	for _, ev := range []string{EventSubscriptionRemoved, EventMissed} {
		if p, err := Parse(body(t, map[string]any{"clientState": csB, "lifecycleEvent": ev}), true); err != nil ||
			len(p.Hashes) != 1 || p.Hashes[0] != hb {
			t.Fatalf("%s parsed %+v %v", ev, p, err)
		}
	}

	many := make([]map[string]any, MaxEntries+1)
	for i := range many {
		many[i] = map[string]any{"clientState": csA}
	}
	for name, b := range map[string][]byte{
		"empty":       nil,
		"not json":    []byte("hello"),
		"array":       []byte(`[{"clientState":"x"}]`),
		"no value":    []byte(`{"values":[]}`),
		"null value":  []byte(`{"value":null}`),
		"empty value": []byte(`{"value":[]}`),
		"trailing":    []byte(`{"value":[{}]} {}`),
		"too many":    body(t, many...),
	} {
		if _, err := Parse(b, false); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: err %v, want ErrMalformed", name, err)
		}
	}
	if p, err := Parse(body(t, many[:MaxEntries]...), false); err != nil || len(p.Hashes) != 1 {
		t.Fatalf("%d entries: %+v %v", MaxEntries, p, err)
	}
}

// The parser has no field for what names a message: a type that grew one
// would hold it in memory and invite logging it.
func TestEntryHasNoResourceFields(t *testing.T) {
	b, _ := json.Marshal(entry{})
	for _, f := range []string{"resource", "resourceData", "subscriptionId", "tenantId"} {
		if strings.Contains(strings.ToLower(string(b)), strings.ToLower(f)) {
			t.Fatalf("entry carries %s: %s", f, b)
		}
	}
}
