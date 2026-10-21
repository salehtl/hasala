package api

import (
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func (s *Server) recordRestore(e purgeledger.Entry) {
	if s.PurgeLedger == "" {
		return
	}
	if err := purgeledger.AppendEntries(s.PurgeLedger, e); err != nil {
		s.logf("api: the restore ledger did not record a %s: %v", e.Kind, err)
	}
}
