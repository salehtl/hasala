// Command export-dictionary writes the operator's v1 categorization rules as
// the CSV that the app's dictionary generator reads (spec 02 §2.3 and §4.3; the
// generator, the label map and the bundle format are spec 03c §8.5). It
// replaces ledgerd's `seed-dictionary` mode: the dictionary no longer lives on
// the server, it ships inside the app.
//
//	HASALA_CORPUS_DB=/scratch/corpus.db go run ./cmd/export-dictionary -o rules.csv
//
// HASALA_CORPUS_DB is a root-made `.backup` snapshot of the v1 database (the
// corpus package refuses the live one). The output has one header row,
// `pattern,match,category_label,display`, then one row per usable active
// rule: the pattern and match canonicalized by internal/dict (the oracle the
// conformance/dict fixtures pin), the category as v1's label (lower-cased;
// the generator maps it to a taxonomy id and fails on any label it does not
// know), and display empty (v1 kept no display name). Rows are sorted by
// match, then pattern, so two exports of one snapshot are byte-identical.
//
// Nothing is dropped silently. On stderr it reports every rule it could not
// use (a regex, an out-of-range pattern) and every conflict (one pattern
// confirmed into two categories). Conflicting rows are all written, because
// choosing between them is the operator's decision, and the generator refuses
// a duplicate (match, pattern), so the CSV must be edited before it is built.
// The exit status is 1 when anything was skipped or conflicts, 0 otherwise.
//
// The CSV is operator data: it is never committed to this repository.
package main

import (
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"

	"github.com/salehtl/hasala/server/internal/dict"
	"github.com/salehtl/hasala/server/oracle/corpus"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "export-dictionary:", err)
		os.Exit(1)
	}
}

// errIncomplete means the CSV was written but some rules need the operator.
var errIncomplete = errors.New("some rules were skipped or conflict (see above); edit the CSV before building the dictionary")

func run(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("export-dictionary", flag.ContinueOnError)
	fs.SetOutput(stderr)
	out := fs.String("o", "", "write the CSV here instead of standard output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected arguments %q", fs.Args())
	}
	path := corpus.DefaultPath()
	if path == "" {
		return errors.New("set HASALA_CORPUS_DB to a `.backup` snapshot of the v1 database " +
			"(the corpus package refuses the live one)")
	}
	db, err := corpus.Open(path)
	if err != nil {
		return err
	}
	defer db.Close()
	rules, err := db.Rules()
	if err != nil {
		return err
	}

	w := stdout
	var f *os.File
	if *out != "" {
		if f, err = os.OpenFile(*out, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600); err != nil {
			return err
		}
		w = f
	}
	rep, err := export(rules, w)
	if f != nil {
		if cerr := f.Close(); err == nil {
			err = cerr
		}
	}
	if err != nil {
		return err
	}
	for _, s := range rep.Skipped {
		fmt.Fprintln(stderr, "skipped:", s)
	}
	for _, c := range rep.Conflicts {
		fmt.Fprintln(stderr, "conflict:", c)
	}
	fmt.Fprintf(stderr, "exported %d rows (from %d v1 rules: %d inactive, %d duplicate, %d unusable, %d patterns in conflict)\n",
		rep.Rows, rep.Read, rep.Inactive, rep.Duplicates, len(rep.Skipped), len(rep.Conflicts))
	if len(rep.Skipped) > 0 || len(rep.Conflicts) > 0 {
		return errIncomplete
	}
	return nil
}

// report is export's reconciliation: the numbers add up to Read, so the
// operator can check them against `select count(*) from rules`.
type report struct {
	Read, Inactive, Duplicates, Rows int
	Skipped                          []string // one line per unusable rule
	Conflicts                        []string // one line per (match, pattern) with two or more categories
}

// header is the generator's input contract (spec 03c §8.5.2).
var header = []string{"pattern", "match", "category_label", "display"}

// export canonicalizes, dedupes and writes rules as CSV.
func export(rules []corpus.Rule, w io.Writer) (report, error) {
	rep := report{Read: len(rules)}
	type key struct{ match, pattern string }
	seen := map[dict.Entry]bool{}
	cats := map[key][]string{}
	var rows []dict.Entry
	for _, r := range rules {
		if !r.Active {
			rep.Inactive++
			continue
		}
		e, err := dict.Canonicalize(dict.Entry{Pattern: r.Pattern, Match: r.MatchType, Category: r.Category})
		if err != nil {
			rep.Skipped = append(rep.Skipped, fmt.Sprintf("%s %q: %v", r.MatchType, r.Pattern, err))
			continue
		}
		if seen[e] {
			rep.Duplicates++
			continue
		}
		seen[e] = true
		k := key{e.Match, e.Pattern}
		cats[k] = append(cats[k], e.Category)
		rows = append(rows, e)
	}
	sort.Slice(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.Match != b.Match {
			return a.Match < b.Match
		}
		if a.Pattern != b.Pattern {
			return a.Pattern < b.Pattern
		}
		return a.Category < b.Category
	})
	for _, e := range rows {
		k := key{e.Match, e.Pattern}
		if c := cats[k]; len(c) > 1 && c[0] == e.Category {
			sorted := append([]string(nil), c...)
			sort.Strings(sorted)
			rep.Conflicts = append(rep.Conflicts, fmt.Sprintf("%s %q is filed under %q", e.Match, e.Pattern, sorted))
		}
	}
	sort.Strings(rep.Conflicts)

	cw := csv.NewWriter(w) // LF line endings: UseCRLF is false
	if err := cw.Write(header); err != nil {
		return rep, err
	}
	for _, e := range rows {
		if err := cw.Write([]string{e.Pattern, e.Match, e.Category, ""}); err != nil {
			return rep, err
		}
	}
	cw.Flush()
	if err := cw.Error(); err != nil {
		return rep, err
	}
	rep.Rows = len(rows)
	return rep, nil
}
