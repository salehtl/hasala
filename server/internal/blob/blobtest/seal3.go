package blobtest

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"github.com/salehtl/hasala/server/internal/blob"
)

// The frame v3 reference sealer (spec 01 §6.4–§6.5). TEST ONLY: the device's
// CoreCrypto.Sealer is the production sealer, and the server never seals or
// opens anything. WS-2 owns the vector generator and the tamper suite; this
// is the smallest correct sealer the server's own tests need to produce
// frames that pass LooksSealed, the upload path and the op_log CHECKs.

// Domain strings (spec 01 §3, D11 and D12).
const (
	domainBlob    = "hasala/v1/blob"
	domainBlobKey = "hasala/v1/blob-key"
)

// TestEpochKey is a fixed K_e for tests that do not care which key sealed a
// frame. It is not a secret: it is 32 bytes of 0x42.
var TestEpochKey = bytes.Repeat([]byte{0x42}, 32)

// SealRegion3 is the AEAD layer of §6.4 with every input explicit, so the
// anchor vectors A09 and A10 can pin it: AD = "hasala/v1/blob" ‖ 0x00 ‖ header
// ‖ prev_hash; K_blob = HKDF(K_e, salt = nonce, info = "hasala/v1/blob-key" ‖
// 0x00 ‖ SHA256(AD)); frame = header ‖ nonce ‖ AES-256-GCM(K_blob, nonce, R, AD).
func SealRegion3(epochKey, header []byte, prevHash [32]byte, nonce, region []byte) ([]byte, error) {
	if len(epochKey) != 32 {
		return nil, fmt.Errorf("blobtest: epoch key is %d bytes, want 32", len(epochKey))
	}
	if len(nonce) != blob.NonceSize {
		return nil, fmt.Errorf("blobtest: nonce is %d bytes, want %d", len(nonce), blob.NonceSize)
	}
	ad := associatedData(header, prevHash)
	key, err := blobKey(epochKey, nonce, ad)
	if err != nil {
		return nil, err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, len(header)+len(nonce)+len(region)+blob.TagSize)
	out = append(out, header...)
	out = append(out, nonce...)
	return gcm.Seal(out, nonce, region, ad), nil
}

// BlobKey3 exposes K_blob for the anchor test.
func BlobKey3(epochKey, header []byte, prevHash [32]byte, nonce []byte) ([]byte, error) {
	return blobKey(epochKey, nonce, associatedData(header, prevHash))
}

func associatedData(header []byte, prevHash [32]byte) []byte {
	ad := make([]byte, 0, len(domainBlob)+1+len(header)+32)
	ad = append(ad, domainBlob...)
	ad = append(ad, 0)
	ad = append(ad, header...)
	return append(ad, prevHash[:]...)
}

func blobKey(epochKey, nonce, ad []byte) ([]byte, error) {
	sum := sha256.Sum256(ad)
	info := append(append([]byte(domainBlobKey), 0), sum[:]...)
	return hkdf.Key(sha256.New, epochKey, nonce, string(info), 32)
}

func newGCM(key []byte) (cipher.AEAD, error) {
	c, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(c)
}

// Seal3 seals plaintext for an envelope as spec 01 §6.5 does: gzip, pick the
// smallest bucket with 39 + L + |G| ≤ bucket, build R = u32be(|G|) ‖ G ‖ zero
// padding, draw a fresh nonce, seal, and re-seal once if the frame trips
// LooksSealed (probability 2⁻²⁴, from the gzip check).
func Seal3(e blob.Envelope, epoch uint32, epochKey []byte, prevHash [32]byte, plaintext []byte) (blob.Sealed, error) {
	header, err := blob.Header3(e, epoch)
	if err != nil {
		return blob.Sealed{}, err
	}
	if len(plaintext) > blob.MaxPlaintext {
		return blob.Sealed{}, fmt.Errorf("%w: plaintext is %d bytes, cap is %d", blob.ErrTooLarge, len(plaintext), blob.MaxPlaintext)
	}
	g, err := gzip3(plaintext)
	if err != nil {
		return blob.Sealed{}, err
	}
	bucket, err := blob.BucketFor(len(header) + blob.NonceSize + 4 + len(g) + blob.TagSize)
	if err != nil {
		return blob.Sealed{}, err
	}
	region := make([]byte, bucket-len(header)-blob.NonceSize-blob.TagSize)
	binary.BigEndian.PutUint32(region[:4], uint32(len(g)))
	copy(region[4:], g)
	for attempt := 0; attempt < 2; attempt++ {
		nonce := make([]byte, blob.NonceSize)
		if _, err := rand.Read(nonce); err != nil {
			return blob.Sealed{}, err
		}
		frame, err := SealRegion3(epochKey, header, prevHash, nonce, region)
		if err != nil {
			return blob.Sealed{}, err
		}
		if len(frame) != bucket {
			return blob.Sealed{}, fmt.Errorf("blobtest: frame is %d bytes, want bucket %d", len(frame), bucket)
		}
		if blob.LooksSealed(frame) == nil {
			return blob.Sealed{Bytes: frame, SizeBucket: bucket}, nil
		}
	}
	return blob.Sealed{}, errors.New("blobtest: sealer fault: two seals in a row tripped LooksSealed")
}

// MustSeal3 is Seal3 under TestEpochKey and epoch 1, panicking on error.
func MustSeal3(e blob.Envelope, prevHash [32]byte, plaintext []byte) blob.Sealed {
	s, err := Seal3(e, 1, TestEpochKey, prevHash, plaintext)
	if err != nil {
		panic(err)
	}
	return s
}

// Open3 reverses Seal3 for a frame expected at e after prevHash (spec 01
// §6.6, R3–R9, without the roster and head checks a device also runs).
func Open3(e blob.Envelope, epochKey []byte, prevHash [32]byte, frame []byte) ([]byte, error) {
	f, err := blob.Parse3(frame)
	if err != nil {
		return nil, err
	}
	if subtle.ConstantTimeCompare(f.AAD, e.AAD()) != 1 {
		return nil, ErrAADMismatch
	}
	hl := blob.FixedHeaderSize + len(f.AAD)
	header, nonce, ct := frame[:hl], frame[hl:hl+blob.NonceSize], frame[hl+blob.NonceSize:]
	ad := associatedData(header, prevHash)
	key, err := blobKey(epochKey, nonce, ad)
	if err != nil {
		return nil, err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	region, err := gcm.Open(nil, nonce, ct, ad)
	if err != nil {
		return nil, fmt.Errorf("%w: aead: %v", ErrSetAside, err)
	}
	m := int(binary.BigEndian.Uint32(region[:4]))
	if m > len(region)-4 {
		return nil, fmt.Errorf("%w: payload length %d runs past the region", ErrMalformed, m)
	}
	zr, err := gzip.NewReader(bytes.NewReader(region[4 : 4+m]))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	zr.Multistream(false)
	out, err := io.ReadAll(io.LimitReader(zr, blob.MaxPlaintext+1))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	if len(out) > blob.MaxPlaintext {
		return nil, fmt.Errorf("%w: plaintext exceeds %d bytes", ErrMalformed, blob.MaxPlaintext)
	}
	return out, nil
}

func gzip3(plaintext []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(plaintext); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
