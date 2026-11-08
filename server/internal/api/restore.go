package api

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/purgeledger"
)

const restoreFlushTimeout = 10 * time.Second

func (s *Server) holdRestore(ctx context.Context, tx pgx.Tx, e purgeledger.Entry) error {
	if s.PurgeLedger == "" {
		return nil
	}
	return purgeledger.HoldTx(ctx, tx, e)
}

func (s *Server) recordRestore(e purgeledger.Entry) {
	if s.PurgeLedger == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), restoreFlushTimeout)
	defer cancel()
	if _, err := purgeledger.Flush(ctx, s.Pool, s.PurgeLedger); err != nil {
		s.logf("api: the restore ledger did not take a %s; the line stays held and a sweep retries it: %v", e.Kind, err)
	}
}
