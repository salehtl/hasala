package api

import (
	"time"

	"github.com/salehtl/hasala/server/internal/auth"
)

// invite mints one code against this harness's database, exactly as
// `hasalad invite mint` does. The invite gate itself is exercised through
// passkey registration (passkey_test.go): ledgerd's ID-token exchange, the
// other door it guarded, is retired (spec 02 §2).
func (h *harness) invite(note string) string {
	h.t.Helper()
	code, err := auth.MintInvite(bg, h.pool, note, time.Now().UTC())
	if err != nil {
		h.t.Fatal(err)
	}
	return code
}
