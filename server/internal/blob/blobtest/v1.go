// Package blobtest holds the op-log frame code the server must never run:
// ledgerd's v1 plaintext frame (PlaintextSealer and its offset helpers), kept
// to read the v1 conformance fixtures in conformance/blob and conformance/ts,
// and the reference frame v3 sealer and opener (seal3.go) that tests use to
// produce frames the upload path and the database accept.
//
// TEST AND VECTOR CODE ONLY. cmd/hasalad's build graph must never reach this
// package (spec 02 §4.4 fences 1 and 3: no PlaintextSealer, no AES-GCM in the
// server); cmd/hasalad/fence_test.go enforces it.
package blobtest

import (
	"bytes"
	"compress/gzip"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"github.com/salehtl/hasala/server/internal/blob"
)

// Envelope and Sealed are the server package's; the v1 frame binds the same
// four fields.
type (
	Envelope = blob.Envelope
	Sealed   = blob.Sealed
)

// The v1 frame (ledgerd, spec 01 §6.1 "0x01 is the ledgerd plaintext frame"):
//
//	[1B version=1][2B BE aadLen][aad][12B nonce=0][4B BE payloadLen][gzip payload][zero padding][16B tag=0]
//
// The server refuses it (LooksSealed check "version"); it survives here only so
// the v1 fixtures keep their reader.
const (
	// Version is the v1 envelope version byte.
	Version = 1

	versionSize    = 1
	aadLenSize     = 2
	payloadLenSize = 4

	NonceSize = blob.NonceSize
	TagSize   = blob.TagSize

	MaxPlaintext = blob.MaxPlaintext

	aadSeparator = "|"
)

// StreamCold is ledgerd's raw-mail stream. Only the v1 fixtures still name it.
const StreamCold = "cold"

// StreamHot is blob.StreamHot.
const StreamHot = blob.StreamHot

var (
	// ErrSetAside is wrapped by every error Open returns.
	ErrSetAside = errors.New("blob cannot be opened")
	// ErrUnsupportedVersion means the envelope version byte is not 1.
	ErrUnsupportedVersion = fmt.Errorf("%w: unsupported envelope version", ErrSetAside)
	// ErrAADMismatch means the blob was sealed at a different position.
	ErrAADMismatch = fmt.Errorf("%w: associated data mismatch", ErrSetAside)
	// ErrMalformed means the framing itself is unreadable.
	ErrMalformed = fmt.Errorf("%w: malformed envelope", ErrSetAside)
	// ErrTooLarge and ErrInvalidEnvelope are the server package's.
	ErrTooLarge        = blob.ErrTooLarge
	ErrInvalidEnvelope = blob.ErrInvalidEnvelope
)

// validateV1 is ledgerd's envelope rule: like blob.Envelope.Validate, but the
// v1 fixtures also carry cold-stream positions.
func validateV1(e Envelope) error {
	if e.Stream == StreamCold {
		e.Stream = blob.StreamHot // every other rule is identical
	}
	if err := e.Validate(); err != nil {
		return err
	}
	if n := overhead(len(e.AAD())); n > blob.Buckets[0] {
		return fmt.Errorf("%w: framing overhead %d does not fit the smallest bucket", ErrInvalidEnvelope, n)
	}
	return nil
}

// BucketFor is the server package's.
func BucketFor(n int) (int, error) { return blob.BucketFor(n) }

// Sealer is ledgerd's v1 sealing interface.
type Sealer interface {
	Seal(e Envelope, plaintext []byte) (Sealed, error)
	Open(e Envelope, s Sealed) ([]byte, error)
}

// PlaintextSealer is the Phase 1 implementation: it frames, compresses and pads
// but does not encrypt. It leaves the nonce and tag slots zero.
type PlaintextSealer struct{}

var _ Sealer = PlaintextSealer{}

// overhead is every framed byte that is not payload or padding.
func overhead(aadLen int) int {
	return versionSize + aadLenSize + aadLen + NonceSize + payloadLenSize + TagSize
}

// SealedRegion reports the half-open byte range of a framed blob that Phase 3
// encrypts: everything after the nonce and before the tag, which is the
// payload length, the payload and the padding. Callers outside this package use
// it to reason about the format without re-deriving offsets.
func SealedRegion(b []byte) (start, end int, err error) {
	if len(b) < versionSize+aadLenSize {
		return 0, 0, fmt.Errorf("%w: %d bytes is shorter than the header", ErrMalformed, len(b))
	}
	aadLen := int(binary.BigEndian.Uint16(b[versionSize : versionSize+aadLenSize]))
	start = versionSize + aadLenSize + aadLen + NonceSize
	end = len(b) - TagSize
	if end < start+payloadLenSize {
		return 0, 0, fmt.Errorf("%w: aadLen %d leaves no room for a payload", ErrMalformed, aadLen)
	}
	return start, end, nil
}

// EmbeddedAAD returns the associated data a framed blob carries, read straight
// out of the frame. It neither opens nor decrypts anything, because the AAD is
// CLEARTEXT in the frame in both phases — see the wire format above, where it
// sits ahead of the nonce and outside [SealedRegion].
//
// That is what makes it useful to the SERVER, which holds no key in Phase 3 and
// must still be able to check that a blob a client submits was sealed for the
// position it is being stored at. [PlaintextSealer.Open] performs the same
// comparison for a READER; oplog.Row.validate performs it for a WRITER, which
// is the earlier and more useful place to catch a blob at the wrong position
// (before it is stored, rather than as a set-aside warning on a device
// afterwards).
//
// The offsets are derived here, from the layout constants, so no caller has to
// restate them — the same reason [SealedRegion] exists.
func EmbeddedAAD(b []byte) ([]byte, error) {
	start, _, err := SealedRegion(b)
	if err != nil {
		return nil, err
	}
	// SealedRegion has already bounds-checked everything this slices.
	return b[versionSize+aadLenSize : start-NonceSize], nil
}

// Seal compresses plaintext, frames it and pads the result to a size bucket.
func (PlaintextSealer) Seal(e Envelope, plaintext []byte) (Sealed, error) {
	if err := validateV1(e); err != nil {
		return Sealed{}, err
	}
	if len(plaintext) > MaxPlaintext {
		return Sealed{}, fmt.Errorf("%w: plaintext is %d bytes, cap is %d", ErrTooLarge, len(plaintext), MaxPlaintext)
	}
	aad := e.AAD()

	payload, err := compress(plaintext)
	if err != nil {
		return Sealed{}, err
	}
	bucket, err := blob.BucketFor(overhead(len(aad)) + len(payload))
	if err != nil {
		return Sealed{}, err
	}

	out := make([]byte, bucket)
	out[0] = Version
	binary.BigEndian.PutUint16(out[versionSize:versionSize+aadLenSize], uint16(len(aad)))
	copy(out[versionSize+aadLenSize:], aad)
	// out[.. +NonceSize] stays zero: the nonce slot, reserved for Phase 3.

	// Deliberately re-derived from the bytes just written rather than computed
	// alongside them: Seal and Open then get their offsets from one function, so
	// they cannot drift apart.
	start, end, err := SealedRegion(out)
	if err != nil {
		return Sealed{}, err
	}
	region := out[start:end]
	binary.BigEndian.PutUint32(region[:payloadLenSize], uint32(len(payload)))
	copy(region[payloadLenSize:], payload)
	// The rest of region stays zero: padding, INSIDE the sealed region.
	// out[end:] stays zero: the tag slot, reserved for Phase 3.

	return Sealed{Bytes: out, SizeBucket: bucket}, nil
}

// Open reverses Seal. It rejects a blob whose embedded AAD does not match the
// envelope the caller expects it at, which is what stops a server replaying a
// blob into another position, stream or user.
func (PlaintextSealer) Open(e Envelope, s Sealed) ([]byte, error) {
	if err := validateV1(e); err != nil {
		return nil, err
	}
	b := s.Bytes
	if s.SizeBucket != 0 && s.SizeBucket != len(b) {
		return nil, fmt.Errorf("%w: %d bytes declared as bucket %d", ErrMalformed, len(b), s.SizeBucket)
	}
	if !blob.IsBucket(len(b)) {
		return nil, fmt.Errorf("%w: %d bytes is not a size bucket", ErrMalformed, len(b))
	}
	if b[0] != Version {
		return nil, fmt.Errorf("%w: %d", ErrUnsupportedVersion, b[0])
	}

	start, end, err := SealedRegion(b)
	if err != nil {
		return nil, err
	}
	// Derived by EmbeddedAAD rather than re-sliced here, so the offset exists
	// in exactly one place and the reader's check and the writer's check
	// (oplog.Row.validate) cannot drift apart.
	aad, err := EmbeddedAAD(b)
	if err != nil {
		return nil, err
	}
	// Phase 3 hands this comparison to the AEAD. Until then it is a constant-time
	// compare so the check has the same shape as the one that replaces it.
	if subtle.ConstantTimeCompare(aad, e.AAD()) != 1 {
		return nil, fmt.Errorf("%w: sealed at a different position", ErrAADMismatch)
	}

	region := b[start:end]
	n := int(binary.BigEndian.Uint32(region[:payloadLenSize]))
	if n < 0 || n > len(region)-payloadLenSize {
		return nil, fmt.Errorf("%w: payload length %d runs past the sealed region", ErrMalformed, n)
	}
	return decompress(region[payloadLenSize : payloadLenSize+n])
}

func compress(plaintext []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, fmt.Errorf("blob: gzip: %w", err)
	}
	if _, err := zw.Write(plaintext); err != nil {
		return nil, fmt.Errorf("blob: gzip: %w", err)
	}
	if err := zw.Close(); err != nil {
		return nil, fmt.Errorf("blob: gzip: %w", err)
	}
	return buf.Bytes(), nil
}

func decompress(payload []byte) ([]byte, error) {
	zr, err := gzip.NewReader(bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	defer zr.Close()
	// Read one byte past the cap so an over-cap body is detected rather than
	// silently truncated.
	out, err := io.ReadAll(io.LimitReader(zr, MaxPlaintext+1))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	if len(out) > MaxPlaintext {
		return nil, fmt.Errorf("%w: decompressed payload exceeds %d bytes", ErrMalformed, MaxPlaintext)
	}
	return out, nil
}

// Hash and ZeroHash are the server package's chain rule, unchanged since v1.
var ZeroHash = blob.ZeroHash

// Hash is blob.Hash.
func Hash(prev [32]byte, s Sealed) [32]byte { return blob.Hash(prev, s) }

// Buckets and MaxBucket are the server package's ladder.
var Buckets = blob.Buckets

// MaxBucket is blob.MaxBucket.
const MaxBucket = blob.MaxBucket
