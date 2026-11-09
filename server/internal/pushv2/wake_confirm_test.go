package pushv2

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestConfirmationFollowsAWakeThatWentOut(t *testing.T) {
	runJob := func(d *Dispatcher, tokens ...Target) int {
		calls := 0
		d.run(bg, job{tokens: tokens, r: ReasonNudge, sent: func() { calls++ }})
		return calls
	}
	t.Run("two tokens confirm once", func(t *testing.T) {
		d := NewDispatcher(nil, &fakeSender{})
		if n := runJob(d, fixedTarget(1), fixedTarget(2)); n != 1 {
			t.Fatalf("%d confirmations", n)
		}
	})
	t.Run("one token of two is enough", func(t *testing.T) {
		d := NewDispatcher(nil, &fakeSender{result: func(x Target) Result {
			if x == fixedTarget(1) {
				return ResultTransient
			}
			return ResultSent
		}})
		if n := runJob(d, fixedTarget(1), fixedTarget(2)); n != 1 {
			t.Fatalf("%d confirmations", n)
		}
	})
	for name, res := range map[string]Result{
		"transient": ResultTransient, "cooldown": ResultCooldown, "gone": ResultGone,
		"config": ResultConfig, "environment": ResultEnvironment,
	} {
		t.Run("refused "+name, func(t *testing.T) {
			d := NewDispatcher(nil, &fakeSender{result: func(Target) Result { return res }})
			if n := runJob(d, fixedTarget(1)); n != 0 {
				t.Fatalf("%d confirmations for a wake APNs did not take", n)
			}
		})
	}
	t.Run("no token", func(t *testing.T) {
		d := NewDispatcher(nil, &fakeSender{})
		if n := runJob(d); n != 0 {
			t.Fatalf("%d confirmations with no device", n)
		}
	})
	t.Run("paused", func(t *testing.T) {
		s := &fakeSender{}
		d := NewDispatcher(nil, s)
		d.pause = time.Now().Add(time.Minute)
		if n := runJob(d, fixedTarget(1)); n != 0 || s.count() != 0 {
			t.Fatalf("%d confirmations, %d sends while paused", n, s.count())
		}
	})
	t.Run("cooling", func(t *testing.T) {
		s := &fakeSender{}
		d := NewDispatcher(nil, s)
		d.th.cool(fixedTarget(1), time.Now())
		if n := runJob(d, fixedTarget(1)); n != 0 || s.count() != 0 {
			t.Fatalf("%d confirmations, %d sends while cooling", n, s.count())
		}
	})
	t.Run("over the total cap", func(t *testing.T) {
		s := &fakeSender{}
		d := NewDispatcher(nil, s)
		for range totalCap {
			if n := runJob(d, fixedTarget(1)); n != 1 {
				t.Fatalf("%d confirmations under the cap", n)
			}
		}
		if n := runJob(d, fixedTarget(1)); n != 0 || s.count() != totalCap {
			t.Fatalf("%d confirmations, %d sends past the cap", n, s.count())
		}
	})
}

func TestConfirmedWakeNeedsAWriter(t *testing.T) {
	d := NewDispatcher(nil, &fakeSender{})
	if d.TryWakeWriterConfirmed(bg, uuid.New(), "", ReasonNudge, func() { t.Error("confirmed") }) {
		t.Fatal("a wake for no writer was reported queued")
	}
	if len(d.queue) != 0 {
		t.Fatal("a wake for no writer reached the queue")
	}
}
