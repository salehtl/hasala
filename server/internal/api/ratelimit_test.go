package api

import (
	"fmt"
	"strconv"
	"testing"
	"time"
)

func TestLimiterSpendsTheBurstThenRefillsOnTheClock(t *testing.T) {
	now := time.Now()
	l := NewLimiter(1, 3, 16, func() time.Time { return now })
	for i := 0; i < 3; i++ {
		if !l.Allow("k") {
			t.Fatalf("call %d was refused inside the burst", i)
		}
	}
	if l.Allow("k") {
		t.Fatal("the burst did not bound anything")
	}
	now = now.Add(2 * time.Second)
	for i := 0; i < 2; i++ {
		if !l.Allow("k") {
			t.Fatalf("refill %d was refused after 2s at 1/s", i)
		}
	}
	if l.Allow("k") {
		t.Fatal("refill exceeded the elapsed time")
	}
}

func TestLimiterKeysAreIndependent(t *testing.T) {
	now := time.Now()
	l := NewLimiter(0, 1, 16, func() time.Time { return now })
	if !l.Allow("a") || l.Allow("a") {
		t.Fatal("key a's budget is wrong")
	}
	if !l.Allow("b") {
		t.Fatal("key a exhausting its budget must not spend key b's")
	}
}

func TestLimiterUnderKeyPressureSharesABucketRatherThanDenying(t *testing.T) {
	// The key space is attacker-chosen on the sign-in path. Refusing new keys
	// once the map is full would let anyone with many source addresses lock
	// every legitimate caller out — an amplification nuisance traded for an
	// outage. Under pressure the limit gets coarser, never absolute.
	now := time.Now()
	l := NewLimiter(0, 2, 2, func() time.Time { return now })
	for i := 0; i < 2; i++ {
		l.Allow("a")
		l.Allow("b")
	}
	// The map is now full and neither bucket is refillable (rate 0).

	served := 0
	for i := 0; i < 10; i++ {
		if l.Allow("flood-" + strconv.Itoa(i)) {
			served++
		}
	}
	if served == 0 {
		t.Fatal("a full key map denied every new caller outright")
	}
	if served > 2 {
		t.Fatalf("the shared fallback bucket served %d, which is more than its burst of 2", served)
	}
	// The established keys keep their own (already spent) budgets.
	if l.Allow("a") {
		t.Fatal("key pressure handed an established key a fresh budget")
	}
}

func TestLimiterSweepOnlyEvictsFullyRefilledKeys(t *testing.T) {
	now := time.Now()
	l := NewLimiter(1, 2, 2, func() time.Time { return now })
	l.Allow("idle") // 1 token left
	l.Allow("busy")
	l.Allow("busy") // 0 tokens left

	now = now.Add(10 * time.Second) // "idle" is back to full; "busy" is too
	if !l.Allow("new") {
		t.Fatal("a sweep of refilled keys should have made room")
	}
	if len(l.buckets) > 2 {
		t.Fatalf("the map holds %d keys, above its cap of 2", len(l.buckets))
	}

	// Now with no time passing, a spent key must not be evicted and reborn.
	l2 := NewLimiter(0, 1, 1, func() time.Time { return now })
	l2.Allow("spent")
	if l2.Allow("spent") {
		t.Fatal("a spent key was granted a second token")
	}
	l2.Allow("other") // forces the sweep path
	if l2.Allow("spent") {
		t.Fatal("the sweep evicted a partially spent bucket, handing its key a fresh burst")
	}
}

func TestNilLimiterAllows(t *testing.T) {
	var l *Limiter
	if !l.Allow("anything") {
		t.Fatal("a nil limiter must be an absent limit, not a closed door")
	}
}

func TestRefundNGivesBackUpToTheBurst(t *testing.T) {
	l := NewLimiter(0, 10, 1, time.Now)
	if !l.AllowN("a", 10) {
		t.Fatal("a full bucket refused its burst")
	}
	l.RefundN("a", 4)
	if !l.AllowN("a", 4) || l.AllowN("a", 1) {
		t.Fatal("a refund of 4 did not give back exactly 4")
	}
	l.RefundN("a", 100)
	if !l.AllowN("a", 10) || l.AllowN("a", 1) {
		t.Fatal("a refund was not capped at the burst")
	}
	if !l.AllowN("b", 10) || l.AllowN("b", 1) {
		t.Fatal("the shared bucket did not apply its burst")
	}
	l.RefundN("b", 3)
	if !l.AllowN("b", 3) || l.AllowN("b", 1) {
		t.Fatal("a refund for an untracked key did not reach the shared bucket")
	}
	var none *Limiter
	none.RefundN("a", 1)
}

func TestClientLimiterKeepsOnePrefixFromFillingTheTable(t *testing.T) {
	now := time.Now()
	l := NewClientLimiter(3.0/3600, 3, 640, func() time.Time { return now })
	for i := range 640 {
		l.Allow(fmt.Sprintf("6:20010db80001%04x", i))
	}
	if len(l.buckets) != 11 {
		t.Fatalf("one /48 holds %d table entries, want its 10 and one shared", len(l.buckets))
	}
	if l.Allow("6:20010db80001ffff") {
		t.Fatal("the /48's shared bucket did not apply its burst")
	}
	if !l.Allow("6:20010db800010000") {
		t.Fatal("a /64 inside the quota lost its own bucket")
	}
	for i := range 3 {
		if !l.Allow("6:20010db800020001") {
			t.Fatalf("call %d from another /48 was refused", i)
		}
		if !l.Allow("4:192.0.2.7") {
			t.Fatalf("call %d from an IPv4 client was refused", i)
		}
	}
	if !l.fallback.last.IsZero() {
		t.Fatal("a table with room used the shared bucket")
	}
}

func TestClientLimiterFreesAQuotaSlotOnlyAfterARefill(t *testing.T) {
	now := time.Now()
	l := NewClientLimiter(1, 2, 64, func() time.Time { return now })
	a, b, p := "6:20010db800010001", "6:20010db800010002", "6p:20010db80001"
	if !l.Allow(a) || !l.Allow(b) {
		t.Fatal("the first calls were refused")
	}
	if _, own := l.buckets[b]; own {
		t.Fatal("a /64 over the quota got its own bucket")
	}
	if _, shared := l.buckets[p]; !shared {
		t.Fatal("a /64 over the quota has no shared bucket")
	}
	now = now.Add(10 * time.Second)
	if !l.Allow(b) {
		t.Fatal("a refilled /48 refused a /64")
	}
	if _, own := l.buckets[a]; own {
		t.Fatal("the refilled /64 kept its quota slot")
	}
	if _, own := l.buckets[b]; !own || l.prefixKeys[p] != 1 {
		t.Fatalf("own %v, quota %d after a refill", own, l.prefixKeys[p])
	}
}

func TestClientLimiterSweepsAtMostOncePerRefill(t *testing.T) {
	now := time.Now()
	l := NewClientLimiter(1, 2, 64, func() time.Time { return now })
	a, b, p := "6:20010db800010001", "6:20010db800010002", "6p:20010db80001"
	l.Allow(a)
	l.Allow(b)
	first := l.nextSweep
	if !first.Equal(now.Add(2 * time.Second)) {
		t.Fatalf("next sweep %v, want one refill after %v", first, now)
	}
	now = now.Add(time.Second)
	l.Allow(b)
	if !l.nextSweep.Equal(first) {
		t.Fatal("a call inside the refill period swept again")
	}
	if l.prefixKeys[p] != 1 {
		t.Fatalf("quota %d, want 1", l.prefixKeys[p])
	}
}

func TestClientLimiterForgetsSweptPrefixes(t *testing.T) {
	now := time.Now()
	l := NewClientLimiter(1, 1, 2, func() time.Time { return now })
	l.Allow("6:20010db800010001")
	l.Allow("6:20010db800020001")
	if l.Allow("6:20010db800030001") && l.Allow("6:20010db800040001") {
		t.Fatal("the shared fallback did not apply its burst")
	}
	now = now.Add(5 * time.Second)
	if !l.Allow("6:20010db800050001") {
		t.Fatal("a sweep of refilled keys made no room")
	}
	if len(l.prefixKeys) != 1 {
		t.Fatalf("%d prefixes tracked after the sweep, want 1", len(l.prefixKeys))
	}
}

func TestLimiterWithoutAQuotaTreatsEveryKeyAlike(t *testing.T) {
	now := time.Now()
	l := NewLimiter(0, 1, 64, func() time.Time { return now })
	for i := range 64 {
		if !l.Allow(fmt.Sprintf("6:20010db80001%04x", i)) {
			t.Fatalf("key %d was refused", i)
		}
	}
	if len(l.buckets) != 64 {
		t.Fatalf("%d keys, want 64", len(l.buckets))
	}
}
