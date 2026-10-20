package banks_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/banks"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

func TestConcurrentNewNamesDoNotOvershootTheCap(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	if _, err := pool.Exec(ctx,
		`INSERT INTO bank_requests (other_key, other_text, source, created_at)
		 SELECT 'seed ' || g, 'Seed ' || g, 'web', now() FROM generate_series(1, $1) g`,
		banks.MaxOtherKeys-1); err != nil {
		t.Fatal(err)
	}
	const writers = 24
	var (
		wg    sync.WaitGroup
		start = make(chan struct{})
		errs  = make([]error, writers)
	)
	for i := range writers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c := banks.Choice{OtherText: fmt.Sprintf("Race %d", i), OtherKey: fmt.Sprintf("race %d", i)}
			<-start
			errs[i] = banks.Record(ctx, pool, c, nil, "", time.Now())
		}()
	}
	close(start)
	wg.Wait()
	ok := 0
	for i, err := range errs {
		switch {
		case err == nil:
			ok++
		case errors.Is(err, banks.ErrListFull):
		default:
			t.Fatalf("writer %d: %v", i, err)
		}
	}
	var distinct int
	if err := pool.QueryRow(ctx,
		`SELECT count(DISTINCT other_key) FROM bank_requests WHERE other_key IS NOT NULL`).Scan(&distinct); err != nil {
		t.Fatal(err)
	}
	if ok != 1 || distinct != banks.MaxOtherKeys {
		t.Fatalf("%d writers succeeded and %d distinct names are stored, want 1 and %d", ok, distinct, banks.MaxOtherKeys)
	}
	if err := banks.Record(ctx, pool, banks.Choice{OtherText: "Seed 1", OtherKey: "seed 1"}, nil, "", time.Now()); err != nil {
		t.Fatalf("a known name at the cap: %v", err)
	}
}
