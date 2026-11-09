package oplog

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestACommitWhoseAnswerIsLostCountsAsPossiblyStored(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	losing, lose := pgtest.LosingCommitAnswers(t, pool)
	a := &Appender{Pool: losing}
	const w = "ios-00000000-0000-4000-8000-00000000000a"
	rows, _ := chainFrom(t, u, w, blob.StreamHot, 1, blob.ZeroHash, 2)

	lose()
	if _, outcome, err := a.AppendClientOutcome(bg, u, w, blob.StreamHot, rows, testHeadSig(u, w, rows)); err == nil || outcome != AppendMayHaveAddedRows {
		t.Fatalf("a commit with no answer: outcome = %v, err = %v; want AppendMayHaveAddedRows and an error", outcome, err)
	}

	deadline := time.Now().Add(30 * time.Second)
	var want []int64
	for len(want) < 2 {
		want = seqsOf(t, pool, u)
		if time.Now().After(deadline) {
			t.Fatalf("the commit never landed: seqs %v", want)
		}
		time.Sleep(5 * time.Millisecond)
	}

	again, outcome, err := a.AppendClientOutcome(bg, u, w, blob.StreamHot, rows, testHeadSig(u, w, rows))
	if err != nil {
		t.Fatalf("the resend: %v", err)
	}
	if outcome != AppendAddedNothing {
		t.Fatal("a resend that stored nothing was reported as stored")
	}
	if !reflect.DeepEqual(again, want) {
		t.Fatalf("the resend answered %v, want %v", again, want)
	}
	assertGapFree(t, pool, u, 2)
}

func TestOnlyAnAnsweredCommitFailureIsKnownToHaveStoredNothing(t *testing.T) {
	cases := []struct {
		name  string
		err   error
		known bool
	}{
		{"the server rolled back", pgx.ErrTxCommitRollback, true},
		{"the server refused", fmt.Errorf("wrapped: %w", &pgconn.PgError{Code: "23514"}), true},
		{"the deadline passed", context.DeadlineExceeded, false},
		{"the request was cancelled", context.Canceled, false},
		{"the connection dropped", errors.New("unexpected EOF"), false},
	}
	for _, c := range cases {
		if got := commitOutcomeKnown(c.err); got != c.known {
			t.Errorf("%s: known = %v, want %v", c.name, got, c.known)
		}
	}
}
