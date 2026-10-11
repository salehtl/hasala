package main

import (
	"bytes"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/oracle/corpus"
)

// Every merchant below is invented.
func TestExportCanonicalizesDedupesAndReportsEverything(t *testing.T) {
	rules := []corpus.Rule{
		{MatchType: "contains", Pattern: "  ZEBRA   Grocer ", Category: "Groceries", Active: true},
		{MatchType: "contains", Pattern: "zebra grocer", Category: "groceries", Active: true}, // duplicate after canonicalization
		{MatchType: "exact", Pattern: "Quill Cafe", Category: "Dining", Active: true},
		{MatchType: "contains", Pattern: "old merchant", Category: "shopping", Active: false}, // inactive
		{MatchType: "regex", Pattern: "^foo.*bar$", Category: "shopping", Active: true},       // unusable
		{MatchType: "contains", Pattern: "abc", Category: "shopping", Active: true},           // below the contains floor
		{MatchType: "contains", Pattern: "Orbit Fuel", Category: "transport", Active: true},   // conflict...
		{MatchType: "contains", Pattern: "orbit fuel", Category: "Shopping", Active: true},    // ...with this
		{MatchType: "contains", Pattern: "Comma, Books", Category: "shopping", Active: true},  // CSV quoting
	}
	var buf bytes.Buffer
	rep, err := export(rules, &buf)
	if err != nil {
		t.Fatal(err)
	}
	want := "pattern,match,category_label,display\n" +
		"\"comma, books\",contains,shopping,\n" +
		"orbit fuel,contains,shopping,\n" +
		"orbit fuel,contains,transport,\n" +
		"zebra grocer,contains,groceries,\n" +
		"quill cafe,exact,dining,\n"
	if got := buf.String(); got != want {
		t.Fatalf("CSV:\n%s\nwant:\n%s", got, want)
	}
	if rep.Read != 9 || rep.Inactive != 1 || rep.Duplicates != 1 || rep.Rows != 5 || len(rep.Skipped) != 2 {
		t.Fatalf("report = %+v", rep)
	}
	if rep.Read != rep.Inactive+rep.Duplicates+len(rep.Skipped)+rep.Rows {
		t.Fatalf("the reconciliation does not add up: %+v", rep)
	}
	if len(rep.Conflicts) != 1 || !strings.Contains(rep.Conflicts[0], `"orbit fuel"`) {
		t.Fatalf("conflicts = %q", rep.Conflicts)
	}
}

func TestRunNeedsTheCorpusSnapshot(t *testing.T) {
	t.Setenv("HASALA_CORPUS_DB", "")
	var out, errOut bytes.Buffer
	if err := run(nil, &out, &errOut); err == nil || !strings.Contains(err.Error(), "HASALA_CORPUS_DB") {
		t.Fatalf("run without HASALA_CORPUS_DB = %v", err)
	}
	t.Setenv("HASALA_CORPUS_DB", "/var/lib/ledger/ledger.db")
	if err := run(nil, &out, &errOut); !errors.Is(err, corpus.ErrLiveDatabase) {
		t.Fatalf("run against the live path = %v, want ErrLiveDatabase", err)
	}
}

// End to end through corpus.Rules, on a tiny synthetic snapshot with v1's two
// tables.
func TestRunReadsASnapshot(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "corpus.db")
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`CREATE TABLE categories (id INTEGER PRIMARY KEY, name TEXT NOT NULL)`,
		`CREATE TABLE rules (id INTEGER PRIMARY KEY, match_type TEXT, pattern TEXT, category_id INTEGER, is_active INTEGER)`,
		`INSERT INTO categories VALUES (1, 'Groceries'), (2, 'Dining')`,
		`INSERT INTO rules VALUES (1, 'contains', 'Zebra Grocer', 1, 1), (2, 'exact', 'Quill Cafe', 2, 1)`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()

	t.Setenv("HASALA_CORPUS_DB", path)
	csvPath := filepath.Join(dir, "rules.csv")
	var out, errOut bytes.Buffer
	if err := run([]string{"-o", csvPath}, &out, &errOut); err != nil {
		t.Fatalf("run: %v (%s)", err, errOut.String())
	}
	got, err := os.ReadFile(csvPath)
	if err != nil {
		t.Fatal(err)
	}
	want := "pattern,match,category_label,display\nzebra grocer,contains,groceries,\nquill cafe,exact,dining,\n"
	if string(got) != want {
		t.Fatalf("CSV:\n%s\nwant:\n%s", got, want)
	}
	if out.Len() != 0 {
		t.Fatalf("-o still wrote to standard output: %q", out.String())
	}
	if !strings.Contains(errOut.String(), "exported 2 rows (from 2 v1 rules") {
		t.Fatalf("summary: %q", errOut.String())
	}
}
