package blobtest

import (
	"bytes"
	"encoding/binary"
	"math/rand"

	"github.com/salehtl/hasala/server/internal/blob"
)

var gzipMagic = []byte{0x1f, 0x8b, 0x08}

// Honest builds a frame shaped like honest ciphertext: v3, the given epoch and
// aad_len, and pseudo-random bytes everywhere after the header, which pass
// checks 5–8 (the gzip window is forced off 1f8b08).
func Honest(n, l int, epoch uint32) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(int64(n*31 + l))).Read(b)
	b[0] = blob.Version3
	binary.BigEndian.PutUint32(b[1:5], epoch)
	binary.BigEndian.PutUint16(b[5:7], uint16(l))
	if l+26 <= n && bytes.Equal(b[23+l:26+l], gzipMagic) {
		b[23+l] ^= 0xff
	}
	return b
}

// LooksSealedCase is one predicate case. The same table runs against the SQL
// function hasala_frame_is_sealed in internal/pg (spec 01 AT-P1, AT-P3).
type LooksSealedCase struct {
	Name  string
	Frame []byte
	Want  string // "" means accepted
}

// LooksSealedCases is spec 01 V-F's set: every bucket, the four AT-P2
// offsets, the L + 67 = n boundary, epochs 0, 1, 7fffffff, 80000000, 80000001
// and ffffffff, five version bytes, empty and 1-byte input, and a v1 frame.
func LooksSealedCases() []LooksSealedCase {
	var cs []LooksSealedCase
	add := func(name string, f []byte, want string) { cs = append(cs, LooksSealedCase{name, f, want}) }
	for _, n := range blob.Buckets {
		add("bucket "+itoa(n), Honest(n, 83, 1), "")
	}
	add("empty", []byte{}, blob.CheckBucket)
	add("one byte", []byte{3}, blob.CheckBucket)
	add("1023 bytes", Honest(1023, 83, 1), blob.CheckBucket)
	add("1025 bytes", Honest(1025, 83, 1), blob.CheckBucket)
	add("2048 bytes (between rungs)", Honest(2048, 83, 1), blob.CheckBucket)
	for _, v := range []byte{0x00, 0x01, 0x02, 0x04, 0xff} {
		f := Honest(1024, 83, 1)
		f[0] = v
		add("version "+itoa(int(v)), f, blob.CheckVersion)
	}
	for _, e := range []struct {
		epoch uint32
		want  string
	}{{0, blob.CheckEpoch}, {1, ""}, {0x7fffffff, ""}, {0x80000000, blob.CheckEpoch}, {0x80000001, blob.CheckEpoch}, {0xffffffff, blob.CheckEpoch}} {
		add("epoch "+hex32(e.epoch), Honest(1024, 83, e.epoch), e.want)
	}
	add("aad_len L+67 = n", Honest(1024, 1024-67, 1), "")
	add("aad_len L+67 = n+1", Honest(1024, 1024-66, 1), blob.CheckAADLen)
	add("aad_len 0xffff", Honest(1024, 0xffff, 1), blob.CheckAADLen)
	// AT-P2: L = 50, n = 1024.
	at := func(name string, from, to int, fill []byte, want string) {
		f := Honest(1024, 50, 1)
		if fill == nil {
			for i := from; i < to; i++ {
				f[i] = 0
			}
		} else {
			copy(f[from:], fill)
		}
		add(name, f, want)
	}
	at("AT-P2 zero nonce [57,69)", 57, 69, nil, blob.CheckNonce)
	at("AT-P2 zero tag [1008,1024)", 1008, 1024, nil, blob.CheckTag)
	at("AT-P2 zero tail [976,1008)", 976, 1008, nil, blob.CheckTail)
	at("AT-P2 gzip at [73,76)", 73, 76, gzipMagic, blob.CheckGzip)
	at("AT-P2 gzip at [72,75) is not the window", 72, 75, gzipMagic, "")
	// A ledgerd v1 plaintext frame: version 1, aad_len at bytes 1–2, zero
	// nonce, zero tag. Refused on its version before anything else is read.
	v1 := make([]byte, 1024)
	v1[0] = 1
	binary.BigEndian.PutUint16(v1[1:3], 10)
	add("ledgerd v1 frame", v1, blob.CheckVersion)
	return cs
}

func itoa(n int) string { return string(appendInt(nil, n)) }
func appendInt(b []byte, n int) []byte {
	if n >= 10 {
		b = appendInt(b, n/10)
	}
	return append(b, byte('0'+n%10))
}
func hex32(v uint32) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 8)
	for i := 7; i >= 0; i-- {
		out[i] = digits[v&0xf]
		v >>= 4
	}
	return string(out)
}
