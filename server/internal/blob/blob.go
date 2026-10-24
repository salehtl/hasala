// Package blob is the server's view of an op-log blob: the size-bucket ladder,
// the position a blob is bound to (its Envelope and AAD), the per-writer chain
// hash, and the sealed frame v3's cleartext header and plaintext predicate
// (frame3.go).
//
// The server holds no key and never seals, opens, compresses or decompresses
// anything (spec 02 §4.4 fence 3). Everything here reads framing that is
// cleartext by design: the bucket (the frame's length), the key epoch and the
// AAD. The reference sealer, ledgerd's v1 plaintext frame and its helpers live
// in internal/blob/blobtest, which only tests and vector generators import.
package blob

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/google/uuid"
)

// Frame constants shared by every frame version.
const (
	// NonceSize is the AES-GCM nonce; TagSize its tag.
	NonceSize = 12
	TagSize   = 16

	// MaxPlaintext bounds an op blob's plaintext on both sides of the device's
	// sealer (spec 01 §6.3). The server never sees plaintext; the constant is
	// here so the reference sealer and the docs share one number.
	MaxPlaintext = 2 << 20

	// aadSeparator joins the AAD fields. Fields may not contain it.
	aadSeparator = "|"
)

// StreamHot is the only stream (spec 02 A-6: the op_log_stream_is_hot CHECK).
// ledgerd's cold stream carried raw mail and is gone with the ingest path.
const StreamHot = "hot"

// Buckets is the size ladder every frame is padded to, in bytes. A 300-byte op
// and a 900-byte op are the same size on the wire, so a server or a backup
// thief learns the bucket and nothing finer.
var Buckets = []int{1 << 10, 4 << 10, 16 << 10, 64 << 10, 256 << 10, 512 << 10, 1024 << 10}

// MaxBucket is the largest frame (a constant so a size check can run before
// anything is parsed; a test keeps it in step with the ladder).
const MaxBucket = 1 << 20

var (
	// ErrMalformed means a length is negative or otherwise unusable.
	ErrMalformed = errors.New("blob: malformed")
	// ErrTooLarge means a frame would exceed the largest bucket.
	ErrTooLarge = errors.New("blob exceeds the largest size bucket")
	// ErrInvalidEnvelope means the caller passed an unusable Envelope: a
	// programming error, not a property of stored bytes.
	ErrInvalidEnvelope = errors.New("invalid blob envelope")
)

// BucketFor returns the smallest bucket that can hold n framed bytes.
func BucketFor(n int) (int, error) {
	if n < 0 {
		return 0, fmt.Errorf("%w: negative length %d", ErrMalformed, n)
	}
	for _, b := range Buckets {
		if n <= b {
			return b, nil
		}
	}
	return 0, fmt.Errorf("%w: %d bytes exceeds %d", ErrTooLarge, n, MaxBucket)
}

// IsBucket reports whether n is exactly a rung of the ladder.
func IsBucket(n int) bool {
	for _, b := range Buckets {
		if n == b {
			return true
		}
	}
	return false
}

// Envelope is the position a blob occupies. Its four fields are exactly the
// AAD spec 01 §6.2 binds; the op_log_aad_matches_position CHECK recomputes the
// same string from the row's columns.
type Envelope struct {
	UserID        uuid.UUID
	Stream        string // StreamHot
	WriterID      string
	WriterCounter int64 // 1-based position within the writer's chain
}

// AAD is the canonical associated data: user_id|stream|writer_id|writer_counter,
// with the counter in decimal. Callers must Validate the envelope first — the
// separator is not escaped.
func (e Envelope) AAD() []byte {
	return []byte(strings.Join([]string{
		e.UserID.String(),
		e.Stream,
		e.WriterID,
		strconv.FormatInt(e.WriterCounter, 10),
	}, aadSeparator))
}

// Validate rejects envelopes whose AAD would be ambiguous or nonsensical.
func (e Envelope) Validate() error {
	switch {
	case e.UserID == uuid.Nil:
		return fmt.Errorf("%w: user_id is zero", ErrInvalidEnvelope)
	case e.Stream != StreamHot:
		return fmt.Errorf("%w: stream is %q, want %q", ErrInvalidEnvelope, e.Stream, StreamHot)
	case e.WriterID == "":
		return fmt.Errorf("%w: writer_id is empty", ErrInvalidEnvelope)
	case e.WriterCounter < 1:
		return fmt.Errorf("%w: writer_counter is %d, and counters are 1-based", ErrInvalidEnvelope, e.WriterCounter)
	case strings.Contains(e.WriterID, aadSeparator):
		return fmt.Errorf("%w: writer_id may not contain %q", ErrInvalidEnvelope, aadSeparator)
	}
	if l := len(e.AAD()); l+minTail > Buckets[0] || l > 0xFFFF {
		return fmt.Errorf("%w: an AAD of %d bytes does not fit the smallest bucket", ErrInvalidEnvelope, l)
	}
	return nil
}

// Sealed is a framed blob, exactly SizeBucket bytes.
type Sealed struct {
	Bytes      []byte
	SizeBucket int
}

// ZeroHash is the genesis of every chain: the prev-hash of writer_counter 1.
var ZeroHash [32]byte

// Hash advances a writer's chain: SHA256(prev || s.Bytes) (spec 01 §7). It
// hashes the stored, framed, padded bytes, so the server recomputes it without
// any key.
func Hash(prev [32]byte, s Sealed) [32]byte {
	h := sha256.New()
	h.Write(prev[:])
	h.Write(s.Bytes)
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}
