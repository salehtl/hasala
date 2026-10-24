package blob

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// Sealed frame v3 (spec 01 §6.1). Offsets are 0-based, L = aad_len, n = |frame|:
//
//	[0]        version   0x03
//	[1:5]      key_epoch u32be, 1 ≤ e ≤ 2³¹−1
//	[5:7]      aad_len   u16be = L
//	[7:7+L]    aad       user_id|hot|writer_id|writer_counter
//	[7+L:19+L] nonce     12 bytes
//	[19+L:n-16] ct       AES-256-GCM ciphertext of R = u32be(m) ‖ gzip(plaintext) ‖ 0x00…
//	[n-16:n]   tag       16 bytes
//
// n is exactly one bucket. The server never encrypts or decrypts anything: it
// reads the cleartext header (the epoch and the AAD) and runs LooksSealed. The
// sealer is the device's (Swift CoreCrypto.Sealer); the Go reference sealer is
// test-only (internal/blob/blobtest).
const (
	// Version3 is the only frame version the server accepts. 0x01 is ledgerd's
	// plaintext frame and 0x02 the encv2 benchmark; both are refused.
	Version3 = 3

	// FixedHeaderSize is the 7 bytes before the AAD: version, epoch, aad_len.
	FixedHeaderSize = 7
	// EpochSize is the u32be key_epoch.
	EpochSize = 4
	// PayloadLenSize is the u32be m at the start of the encrypted region.
	PayloadLenSize = 4

	// MaxEpoch is the largest key_epoch (2³¹−1): the column and Swift's Int32
	// agree on it (spec 01 §8.1, N-01).
	MaxEpoch = 1<<31 - 1

	// minTail is check 4's bound (spec 01 §8.1): L + 67 ≤ n keeps check 7's
	// 32-byte tail window, b[n-48:n-16], inside the encrypted region.
	minTail = 67
)

// Refusal check names, in LooksSealed's order. They are the API's vocabulary
// (spec 02 §11.2) and the Swift enum's raw values (spec 01 §8.1).
const (
	CheckBucket  = "bucket"
	CheckVersion = "version"
	CheckEpoch   = "epoch"
	CheckAADLen  = "aad_len"
	CheckNonce   = "nonce"
	CheckTag     = "tag"
	CheckTail    = "tail"
	CheckGzip    = "gzip"
)

// RefusalError names the first LooksSealed check a frame failed.
type RefusalError struct {
	Check string
}

func (e *RefusalError) Error() string {
	return "blob: not a sealed v3 frame: check " + e.Check + " failed"
}

var (
	zero12 = make([]byte, 12)
	zero16 = make([]byte, 16)
	zero32 = make([]byte, 32)
	gzipID = []byte{0x1f, 0x8b, 0x08}
)

// LooksSealed is the one plaintext predicate (spec 01 §8.1, spec 02 §11.2).
// The same eight checks, in the same order and with the same names, run in the
// client before it persists an in-flight batch, in decodeUploadBlob, in
// oplog.Row.validate, and in SQL as hasala_frame_is_sealed behind the
// op_log_blob_is_sealed CHECK. It returns nil or a *RefusalError.
//
// The server cannot prove that bytes are ciphertext. This refuses every shape
// a buggy or legacy client would produce: wrong framing, ledgerd's v1 and v2
// frames, a zero nonce or tag (a PlaintextSealer-style frame), v3 framing
// around a zero-padded unencrypted region, and v3 framing around a cleartext
// gzip member (false-positive rate on honest ciphertext 2⁻²⁴; the client
// re-seals once on a hit).
func LooksSealed(b []byte) error {
	n := len(b)
	if !IsBucket(n) {
		return &RefusalError{Check: CheckBucket}
	}
	if b[0] != Version3 {
		return &RefusalError{Check: CheckVersion}
	}
	if e := binary.BigEndian.Uint32(b[1:5]); e == 0 || e > MaxEpoch {
		return &RefusalError{Check: CheckEpoch}
	}
	l := int(binary.BigEndian.Uint16(b[5:7]))
	if l+minTail > n {
		return &RefusalError{Check: CheckAADLen}
	}
	if bytes.Equal(b[7+l:19+l], zero12) {
		return &RefusalError{Check: CheckNonce}
	}
	if bytes.Equal(b[n-16:], zero16) {
		return &RefusalError{Check: CheckTag}
	}
	if bytes.Equal(b[n-48:n-16], zero32) {
		return &RefusalError{Check: CheckTail}
	}
	if bytes.Equal(b[23+l:26+l], gzipID) {
		return &RefusalError{Check: CheckGzip}
	}
	return nil
}

// FrameV3 is the parsed cleartext header of a v3 frame. Only Parse3 builds it,
// and only from a frame that passed LooksSealed, so every offset is in range.
type FrameV3 struct {
	Epoch uint32
	AAD   []byte // aliases the frame
}

// Parse3 runs LooksSealed and returns the cleartext header. It is the only
// way production code reads a frame's epoch or AAD: no offset is computed
// anywhere else (spec 01 §6.1, "one versioned layout function").
func Parse3(b []byte) (FrameV3, error) {
	if err := LooksSealed(b); err != nil {
		return FrameV3{}, err
	}
	l := int(binary.BigEndian.Uint16(b[5:7]))
	return FrameV3{
		Epoch: binary.BigEndian.Uint32(b[1:5]),
		AAD:   b[FixedHeaderSize : FixedHeaderSize+l],
	}, nil
}

// EmbeddedAAD returns the AAD a v3 frame carries in cleartext, so the server
// can check that a blob was sealed for the position it is being stored at
// without holding any key. It refuses anything LooksSealed refuses.
func EmbeddedAAD(b []byte) ([]byte, error) {
	f, err := Parse3(b)
	if err != nil {
		return nil, err
	}
	return f.AAD, nil
}

// KeyEpoch returns a v3 frame's key_epoch. It refuses anything LooksSealed
// refuses.
func KeyEpoch(b []byte) (uint32, error) {
	f, err := Parse3(b)
	if err != nil {
		return 0, err
	}
	return f.Epoch, nil
}

// Header3 builds the cleartext header 0x03 ‖ u32be(epoch) ‖ u16be(L) ‖ aad for
// an envelope. It is shared with the test-only reference sealer so the two
// cannot disagree on the layout; the server itself never builds a frame.
func Header3(e Envelope, epoch uint32) ([]byte, error) {
	if err := e.Validate(); err != nil {
		return nil, err
	}
	if epoch == 0 || epoch > MaxEpoch {
		return nil, fmt.Errorf("%w: key epoch %d is outside 1..%d", ErrInvalidEnvelope, epoch, MaxEpoch)
	}
	aad := e.AAD()
	h := make([]byte, FixedHeaderSize+len(aad))
	h[0] = Version3
	binary.BigEndian.PutUint32(h[1:5], epoch)
	binary.BigEndian.PutUint16(h[5:7], uint16(len(aad)))
	copy(h[FixedHeaderSize:], aad)
	return h, nil
}
