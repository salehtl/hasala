package pushv2

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
)

type recorder struct {
	calls int
	err   error
}

func (r *recorder) Notify(context.Context, uuid.UUID) error { r.calls++; return r.err }

func TestMultiCallsEveryMemberAndJoinsTheErrors(t *testing.T) {
	a, b, c := &recorder{err: errors.New("a down")}, &recorder{}, &recorder{err: errors.New("c down")}
	err := Multi{a, nil, b, c}.Notify(context.Background(), uuid.New())
	if a.calls != 1 || b.calls != 1 || c.calls != 1 {
		t.Fatalf("calls a=%d b=%d c=%d, want one each", a.calls, b.calls, c.calls)
	}
	if err == nil || err.Error() != "a down\nc down" {
		t.Fatalf("err = %v, want both failures joined", err)
	}
	if err := (Disabled{}).Notify(context.Background(), uuid.New()); err != nil {
		t.Fatalf("Disabled: %v", err)
	}
}
