package oplog

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestAnAppendRacingAccountDeletionDoesNotDeadlock(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	warmPool(t, pool, 4)
	const w = "ios-00000000-0000-4000-8000-00000000000a"
	first, h1 := chainFrom(t, u, w, blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, w, blob.StreamHot, first, testHeadSig(u, w, first)); err != nil {
		t.Fatal(err)
	}

	holding, release := make(chan struct{}), make(chan struct{})
	appended := make(chan error, 1)
	go func() {
		rows, _ := chainFrom(t, u, w, blob.StreamHot, 2, h1, 1)
		_, err := a.appendRows(bg, rows, func(context.Context, pgx.Tx, []Row) error {
			close(holding)
			<-release
			return nil
		})
		appended <- err
	}()
	<-holding
	deleted := make(chan error, 1)
	go func() {
		_, err := pool.Exec(bg, `DELETE FROM users WHERE id = $1`, u)
		deleted <- err
	}()
	time.Sleep(300 * time.Millisecond)
	close(release)
	if err := <-appended; err != nil {
		t.Fatalf("the append: %v", err)
	}
	if err := <-deleted; err != nil {
		t.Fatalf("the deletion: %v", err)
	}
}
