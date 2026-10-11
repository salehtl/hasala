package tmpl

// oracle_hooks.go exists for the oracle module (server/oracle, spec 02 §4.3):
// the corpus writers moved there with v1ref and corpus. Nothing in the main
// module may call these.

// ASCIILower is asciiLower, for the corpus writers' sender-domain guess.
func ASCIILower(s string) string { return asciiLower(s) }
