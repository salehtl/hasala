package blobtest

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/blob"
)

func seq(from, to byte) []byte {
	var out []byte
	for c := int(from); c <= int(to); c++ {
		out = append(out, byte(c))
	}
	return out
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Spec 01 §15.5 anchors A09 and A10: the AEAD layer of frame v3 with a
// synthetic region R = u32be(16) ‖ 00..0f ‖ zeros under K_1 (A06).
func TestSealRegion3MatchesAnchorsA09A10(t *testing.T) {
	k1 := mustHex(t, "c2e59f467f32b6e843710e8f959c186013d2d2fe94ec883c64ebfa3155f8e188")
	user := uuid.MustParse("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")
	writer := "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

	type anchor struct {
		counter               int64
		nonce                 []byte
		kBlob, tag, frameHash string
		blobHash              string
	}
	anchors := []anchor{
		{1, seq(0xd0, 0xdb), "86b19ef7697c451eba5aa36bf7296de24c4feba11d5cbb6079aa03214597aabd",
			"420dd0db074a3bb3b5ba33dd3feb49a2", "8aff44368ce9015d29617089fbc81ddf7176626d04f41be297189cca90b4c708",
			"baf51ed04dd41eb700cf8ba0467411befaa4494dc6033688e7e9670e3570292f"},
		{2, seq(0xe0, 0xeb), "da2cd8d053e2129d99e76459682f1c5644ba543879bbd722598aadf078d11753",
			"67412fe8521354551b47038661c7aeb1", "c2357f3d9071227ffe86f8a8b7f1110afcbe51b2ed8e3692b7191e9a961c5418",
			"cee22837f339529583565b5de892c0783314923db66a5fdf4432590bec301b3d"},
	}
	prev := blob.ZeroHash
	for _, a := range anchors {
		e := blob.Envelope{UserID: user, Stream: blob.StreamHot, WriterID: writer, WriterCounter: a.counter}
		header, err := blob.Header3(e, 1)
		if err != nil {
			t.Fatal(err)
		}
		region := make([]byte, 1024-len(header)-blob.NonceSize-blob.TagSize)
		binary.BigEndian.PutUint32(region[:4], 16)
		copy(region[4:], seq(0x00, 0x0f))
		if a.counter == 1 && len(region) != 906 {
			t.Fatalf("|R| = %d, want A09's 906", len(region))
		}
		k, err := BlobKey3(k1, header, prev, a.nonce)
		if err != nil {
			t.Fatal(err)
		}
		if got := hex.EncodeToString(k); got != a.kBlob {
			t.Fatalf("counter %d: K_blob = %s, want %s", a.counter, got, a.kBlob)
		}
		frame, err := SealRegion3(k1, header, prev, a.nonce, region)
		if err != nil {
			t.Fatal(err)
		}
		if len(frame) != 1024 {
			t.Fatalf("frame is %d bytes", len(frame))
		}
		if got := hex.EncodeToString(frame[len(frame)-16:]); got != a.tag {
			t.Fatalf("counter %d: tag = %s, want %s", a.counter, got, a.tag)
		}
		if sum := sha256.Sum256(frame); hex.EncodeToString(sum[:]) != a.frameHash {
			t.Fatalf("counter %d: SHA256(frame) = %x, want %s", a.counter, sum, a.frameHash)
		}
		next := blob.Hash(prev, blob.Sealed{Bytes: frame})
		if got := hex.EncodeToString(next[:]); got != a.blobHash {
			t.Fatalf("counter %d: blob_hash = %s, want %s", a.counter, got, a.blobHash)
		}
		if err := blob.LooksSealed(frame); err != nil {
			t.Fatalf("counter %d: the anchor frame fails LooksSealed: %v", a.counter, err)
		}
		prev = next
	}
}

func TestSeal3RoundTripsAndBindsThePosition(t *testing.T) {
	e := blob.Envelope{UserID: uuid.New(), Stream: blob.StreamHot, WriterID: "ios-dev", WriterCounter: 3}
	prev := sha256.Sum256([]byte("prev"))
	pt := []byte(`{"v":4,"kind":"ops","ops":[]}`)
	s, err := Seal3(e, 1, TestEpochKey, prev, pt)
	if err != nil {
		t.Fatal(err)
	}
	if s.SizeBucket != 1024 || len(s.Bytes) != 1024 {
		t.Fatalf("bucket %d, len %d", s.SizeBucket, len(s.Bytes))
	}
	got, err := Open3(e, TestEpochKey, prev, s.Bytes)
	if err != nil || !bytes.Equal(got, pt) {
		t.Fatalf("Open3 = %q, %v", got, err)
	}
	// Another position, another predecessor or another key: no plaintext.
	moved := e
	moved.WriterCounter = 4
	if _, err := Open3(moved, TestEpochKey, prev, s.Bytes); err == nil {
		t.Fatal("opened at another position")
	}
	if _, err := Open3(e, TestEpochKey, blob.ZeroHash, s.Bytes); err == nil {
		t.Fatal("opened after another predecessor")
	}
	if _, err := Open3(e, bytes.Repeat([]byte{1}, 32), prev, s.Bytes); err == nil {
		t.Fatal("opened under another key")
	}
	// Large plaintext moves up the ladder and still passes the predicate.
	big := make([]byte, 300_000)
	for i := range big {
		big[i] = byte(i * 7919 >> 3)
	}
	s, err = Seal3(e, 1, TestEpochKey, prev, big)
	if err != nil {
		t.Fatal(err)
	}
	if s.SizeBucket <= 1024 || blob.LooksSealed(s.Bytes) != nil {
		t.Fatalf("large seal: bucket %d, predicate %v", s.SizeBucket, blob.LooksSealed(s.Bytes))
	}
}
