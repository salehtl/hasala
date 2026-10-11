// Package v1ref is a marker for the frozen v1 reference tree beneath it.
//
// It holds no code. The subdirectories parse, importer, store, categorize and
// anthropic are copies of ledger 1.0's packages, frozen at the repo split (tag
// ledger-v2-final, 2026-08-11), and they exist only so the corpus-equivalence
// and import-conformance gates have a reference to measure this repo against.
// Product code must never import them; scripts/v2-check.sh fails the build if
// cmd/ledgerd's dependency graph reaches any of them.
//
// frozen.sha256 records every file here and frozen_test.go enforces it. See
// README.md for what may change and what a change means.
package v1ref
