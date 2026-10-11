package parse

import (
	"testing"
	"time"
)

func TestParseAEDToFils(t *testing.T) {
	cases := map[string]int64{
		"AED 187.25":    18725,
		"AED 6,250.00":  625000,
		"AED 1,234.56":  123456,
		"187.25":        18725,
		"AED 0.50":      50,
	}
	for in, want := range cases {
		got, cur, err := ParseAEDToFils(in)
		if err != nil {
			t.Errorf("%q: unexpected err %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("%q: fils = %d, want %d", in, got, want)
		}
		if cur != "AED" {
			t.Errorf("%q: currency = %q, want AED", in, cur)
		}
	}
	if _, _, err := ParseAEDToFils("no money here"); err == nil {
		t.Error("expected error when no amount present")
	}
}

func TestParseDIBDate(t *testing.T) {
	got, err := ParseDIBDate("11-03-2025")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !got.Equal(time.Date(2025, 3, 11, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("got %s", got)
	}
	if _, err := ParseDIBDate("2025/03/11"); err == nil {
		t.Error("expected error for wrong format")
	}
}
