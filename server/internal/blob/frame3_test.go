package blob_test

import (
	"bytes"
	"errors"
	"testing"

	"github.com/google/uuid"

	. "github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
)

func TestLooksSealedCases(t *testing.T) {
	cs := blobtest.LooksSealedCases()
	if len(cs) < 32 {
		t.Fatalf("%d cases, want at least V-F's 32", len(cs))
	}
	for _, c := range cs {
		err := LooksSealed(c.Frame)
		var got string
		if err != nil {
			var re *RefusalError
			if !errors.As(err, &re) {
				t.Fatalf("%s: error %v is not a *RefusalError", c.Name, err)
			}
			got = re.Check
		}
		if got != c.Want {
			t.Errorf("%s: LooksSealed = %q, want %q", c.Name, got, c.Want)
		}
	}
}

func TestParse3ReadsTheCleartextHeader(t *testing.T) {
	e := Envelope{UserID: uuid.MustParse("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d"), Stream: StreamHot,
		WriterID: "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", WriterCounter: 1}
	h, err := Header3(e, 7)
	if err != nil {
		t.Fatal(err)
	}
	f := blobtest.Honest(1024, len(e.AAD()), 7)
	copy(f, h)
	aad, err := EmbeddedAAD(f)
	if err != nil || !bytes.Equal(aad, e.AAD()) {
		t.Fatalf("EmbeddedAAD = %q, %v", aad, err)
	}
	if ep, err := KeyEpoch(f); err != nil || ep != 7 {
		t.Fatalf("KeyEpoch = %d, %v", ep, err)
	}
	// Spec 01 A09's header for this envelope at epoch 1.
	h1, _ := Header3(e, 1)
	const a09 = "0300000001005336663163326239652d346433612d346635622d386337642d306531" +
		"6632613362346335647c686f747c696f732d30613162326333642d346535662d3461" +
		"36622d386337642d3965306631613262336334647c31"
	if got := hexOf(h1); got != a09 {
		t.Fatalf("Header3 = %s, want A09's %s", got, a09)
	}
	// Nothing is read from a frame that fails the predicate.
	f[0] = 1
	if _, err := EmbeddedAAD(f); err == nil {
		t.Fatal("EmbeddedAAD read a v1 frame")
	}
	if _, err := KeyEpoch(f); err == nil {
		t.Fatal("KeyEpoch read a v1 frame")
	}
}

func hexOf(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 2*len(b))
	for i, c := range b {
		out[2*i], out[2*i+1] = digits[c>>4], digits[c&0xf]
	}
	return string(out)
}

func TestHeader3RefusesBadEpochsAndEnvelopes(t *testing.T) {
	e := Envelope{UserID: uuid.New(), Stream: StreamHot, WriterID: "w", WriterCounter: 1}
	for _, ep := range []uint32{0, MaxEpoch + 1} {
		if _, err := Header3(e, ep); !errors.Is(err, ErrInvalidEnvelope) {
			t.Errorf("epoch %d: %v", ep, err)
		}
	}
	e.Stream = "cold"
	if _, err := Header3(e, 1); !errors.Is(err, ErrInvalidEnvelope) {
		t.Errorf("cold stream: %v", err)
	}
}

func TestBucketLadder(t *testing.T) {
	if len(Buckets) != 7 {
		t.Fatalf("the ladder is frozen at seven rungs, got %v", Buckets)
	}
	if Buckets[len(Buckets)-1] != MaxBucket {
		t.Fatalf("MaxBucket %d is not the top rung %d", MaxBucket, Buckets[len(Buckets)-1])
	}
	for _, c := range []struct{ n, want int }{{0, 1024}, {1024, 1024}, {1025, 4096}, {MaxBucket, MaxBucket}} {
		if got, err := BucketFor(c.n); err != nil || got != c.want {
			t.Errorf("BucketFor(%d) = %d, %v; want %d", c.n, got, err, c.want)
		}
	}
	if _, err := BucketFor(MaxBucket + 1); !errors.Is(err, ErrTooLarge) {
		t.Errorf("BucketFor(MaxBucket+1): %v", err)
	}
}
