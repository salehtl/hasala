package vectors

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	. "github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// ---------------------------------------------------------------------------
// frame-aead.json: the AEAD layer of §6.4 only, R supplied (A09, A10).
// ---------------------------------------------------------------------------

type aeadCase struct {
	Name     string    `json:"name"`
	KE       H         `json:"k_e"`
	Epoch    uint32    `json:"epoch"`
	UserID   uuid.UUID `json:"user_id"`
	WriterID string    `json:"writer_id"`
	Counter  int64     `json:"writer_counter"`
	PrevHash H         `json:"prev_hash"`
	Nonce    H         `json:"nonce"`
	Region   H         `json:"region"`
	Header   H         `json:"header"`
	AD       H         `json:"ad"`
	SHA256AD H         `json:"sha256_ad"`
	KBlob    H         `json:"k_blob"`
	CtTag    H         `json:"ct_tag"`
	Frame    H         `json:"frame"`
	BlobHash H         `json:"blob_hash"`
}

func aeadFor(name string, ke []byte, epoch uint32, user uuid.UUID, writer string, counter int64, prev [32]byte, nonce []byte, bucket int, region []byte) (aeadCase, error) {
	env := blob.Envelope{UserID: user, Stream: blob.StreamHot, WriterID: writer, WriterCounter: counter}
	header, err := blob.Header3(env, epoch)
	if err != nil {
		return aeadCase{}, err
	}
	if region == nil {
		region = make([]byte, bucket-len(header)-blob.NonceSize-blob.TagSize)
		binary.BigEndian.PutUint32(region, 16)
		copy(region[4:], Range(0x00, 0x0f))
	}
	frame, err := blobtest.SealRegion3(ke, header, prev, nonce, region)
	if err != nil {
		return aeadCase{}, err
	}
	if len(frame) != bucket {
		return aeadCase{}, fmt.Errorf("frame-aead %s: %d bytes, want %d", name, len(frame), bucket)
	}
	kb, _ := blobtest.BlobKey3(ke, header, prev, nonce)
	ad := append(append([]byte(keyproto.DomainBlob+"\x00"), header...), prev[:]...)
	h := blob.Hash(prev, blob.Sealed{Bytes: frame, SizeBucket: bucket})
	return aeadCase{name, ke, epoch, user, writer, counter, prev[:], nonce, region, header, ad, sum(ad), kb,
		frame[len(header)+blob.NonceSize:], frame, h[:]}, nil
}

func anchorFrame1() []byte {
	c, err := aeadFor("", EpochKey1(AnchorAMK, AnchorUser), 1, AnchorUser, AnchorWriterID, 1, blob.ZeroHash, AnchorFrameNonce1, 1024, nil)
	if err != nil {
		panic(err)
	}
	return c.Frame
}

func genFrameAEAD(f Files, _ string) error {
	k1 := EpochKey1(AnchorAMK, AnchorUser)
	a09, err := aeadFor("A09 counter 1", k1, 1, AnchorUser, AnchorWriterID, 1, blob.ZeroHash, AnchorFrameNonce1, 1024, nil)
	if err != nil {
		return err
	}
	a10, err := aeadFor("A10 counter 2", k1, 1, AnchorUser, AnchorWriterID, 2, [32]byte(a09.BlobHash), AnchorFrameNonce2, 1024, nil)
	if err != nil {
		return err
	}
	if !bytes.Equal(a09.BlobHash, Hex(Anchors["A09 blob_hash"])) || !bytes.Equal(a10.BlobHash, Hex(Anchors["A10 blob_hash"])) {
		return errors.New("frame-aead.json: A09/A10 do not reproduce")
	}
	cases := []aeadCase{a09, a10}
	s := newStream("frame-aead.json")
	ke := s.bytes(32)
	for _, c := range []struct {
		counter int64
		epoch   uint32
		bucket  int
	}{{9, 7, 1024}, {10, 7, 1024}, {99999, 0x7fffffff, 1024}, {9223372036854775807, 2, 4096}} {
		prev := [32]byte(s.bytes(32))
		x, err := aeadFor(fmt.Sprintf("counter %d, epoch %d", c.counter, c.epoch), ke, c.epoch, AnchorUser, AnchorWriterID,
			c.counter, prev, s.bytes(12), c.bucket, nil)
		if err != nil {
			return err
		}
		x.Region = nil // the synthetic region: u32be(16) ‖ 00..0f ‖ zeros, stated in the note
		cases = append(cases, x)
	}
	return f.json(CryptoDir+"/frame-aead.json", struct {
		Note  string     `json:"note"`
		Cases []aeadCase `json:"cases"`
	}{
		Note: "spec 01 §6.4, the AEAD layer alone (independent of gzip): header = 03 ‖ u32be(epoch) ‖ u16be(L) ‖ aad; " +
			"AD = \"hasala/v1/blob\" ‖ 00 ‖ header ‖ prev_hash; K_blob = HKDF(K_e, nonce, \"hasala/v1/blob-key\" ‖ 00 ‖ SHA256(AD)); " +
			"frame = header ‖ nonce ‖ AES-256-GCM(K_blob, nonce, R, AD). R is the synthetic u32be(16) ‖ 00..0f ‖ zeros filling the bucket " +
			"(region is printed for A09 and A10 and null where it is that same construction).",
		Cases: cases,
	})
}

// ---------------------------------------------------------------------------
// frames.json + frames/*.bin: full frames with Go gzip at the bucket edges.
// ---------------------------------------------------------------------------

type fullFrame struct {
	Name      string    `json:"name"`
	File      string    `json:"file"`
	UserID    uuid.UUID `json:"user_id"`
	WriterID  string    `json:"writer_id"`
	Counter   int64     `json:"writer_counter"`
	AADLen    int       `json:"aad_len"`
	Epoch     uint32    `json:"epoch"`
	KE        H         `json:"k_e"`
	PrevHash  H         `json:"prev_hash"`
	Nonce     H         `json:"nonce"`
	Bucket    int       `json:"bucket"`
	GzipLen   int       `json:"gzip_len"`
	Fill      int       `json:"framed_len"` // 39 + L + |G|
	Plaintext string    `json:"plaintext"`
	SHA256    H         `json:"sha256_frame"`
	BlobHash  H         `json:"blob_hash"`
}

func padPlaintext(s *stream, n int) []byte {
	const alphabet = "0123456789abcdef"
	pad := s.bytes(n)
	for i := range pad {
		pad[i] = alphabet[pad[i]&0x0f]
	}
	return []byte(`{"v":4,"kind":"ops","ops":[{"v":4,"type":"txn_annotated","op_id":"01JA4A2B3C4D5E6F7G8H9J0K1M","note":"` +
		string(pad) + `"}]}`)
}

func gzipLen(p []byte) int {
	g, err := blobtest.Gzip(p)
	if err != nil {
		panic(err)
	}
	return len(g)
}

// edge finds a plaintext whose framed length 39 + L + |G| is ≤ bucket and one
// whose framed length is > bucket, as close to the edge as the stream allows.
func edge(label string, l, bucket int) (fits, spills []byte) {
	lo, hi := 0, bucket*3
	for lo < hi { // smallest n whose gzip spills
		mid := (lo + hi) / 2
		if 39+l+gzipLen(padPlaintext(newStream(label), mid)) > bucket {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	n := lo
	spills = padPlaintext(newStream(label), n)
	for m := n - 1; m >= 0; m-- {
		if p := padPlaintext(newStream(label), m); 39+l+gzipLen(p) <= bucket {
			return p, spills
		}
	}
	return nil, spills
}

func genFrames(f Files, _ string) error {
	k1 := EpochKey1(AnchorAMK, AnchorUser)
	s := newStream("frames.json")
	counters := []int64{1, 9, 10, 99999}
	var out []fullFrame
	i := 0
	for _, bucket := range []int{1024, 4096, 16384, 65536} {
		for side := 0; side < 2; side++ {
			c := counters[i%len(counters)]
			i++
			env := blob.Envelope{UserID: AnchorUser, Stream: blob.StreamHot, WriterID: AnchorWriterID, WriterCounter: c}
			l := len(env.AAD())
			fits, spills := edge(fmt.Sprintf("frames.json %d", bucket), l, bucket)
			p, name := fits, fmt.Sprintf("bucket %d, fills to the edge", bucket)
			if side == 1 {
				p, name = spills, fmt.Sprintf("bucket %d, one step past the edge", bucket)
			}
			prev := [32]byte(s.bytes(32))
			nonce := s.bytes(12)
			sealed, err := blobtest.SealWithNonce3(env, 1, k1, prev, nonce, p)
			if err != nil {
				return err
			}
			if blob.LooksSealed(sealed.Bytes) != nil {
				return fmt.Errorf("frames.json %s: the frame trips LooksSealed; change the stream label", name)
			}
			got, err := blobtest.Open3(env, k1, prev, sealed.Bytes)
			if err != nil || !bytes.Equal(got, p) {
				return fmt.Errorf("frames.json %s: does not open: %v", name, err)
			}
			file := fmt.Sprintf("frames/%d-%s-c%d.bin", bucket, map[int]string{0: "fit", 1: "spill"}[side], c)
			f[CryptoDir+"/"+file] = sealed.Bytes
			h := blob.Hash(prev, sealed)
			gl := gzipLen(p)
			out = append(out, fullFrame{name, file, AnchorUser, AnchorWriterID, c, l, 1, k1, prev[:], nonce,
				sealed.SizeBucket, gl, 39 + l + gl, string(p), sum(sealed.Bytes), h[:]})
		}
	}
	return f.json(CryptoDir+"/frames.json", struct {
		Note   string      `json:"note"`
		Frames []fullFrame `json:"frames"`
	}{
		Note: "spec 01 §6.3–§6.5, full frames: G = gzip(plaintext) (Go compress/gzip, level 9, mtime 0); the bucket is the smallest " +
			"with 39 + L + |G| ≤ bucket; R = u32be(|G|) ‖ G ‖ zeros. Byte identity of G across implementations is not required " +
			"(§6.7): a reader opens each .bin with k_e, the envelope and prev_hash and must get plaintext back exactly. " +
			"Counters 1, 9, 10 and 99999 give AAD lengths 83, 83, 84 and 87.",
		Frames: out,
	})
}

// ---------------------------------------------------------------------------
// chain.json: spec 01 §7.
// ---------------------------------------------------------------------------

type chainRow struct {
	Counter  int64 `json:"writer_counter"`
	PrevHash H     `json:"prev_hash"`
	Frame    H     `json:"frame"`
	BlobHash H     `json:"blob_hash"`
}

type v1Step struct {
	Prev     H      `json:"prev_hash"`
	Fill     string `json:"fill_byte"`
	Length   int    `json:"length"`
	BlobHash H      `json:"blob_hash"`
}

func genChain(f Files, _ string) error {
	k1 := EpochKey1(AnchorAMK, AnchorUser)
	s := newStream("chain.json")
	prev := blob.ZeroHash
	var rows []chainRow
	for c := int64(1); c <= 5; c++ {
		env := blob.Envelope{UserID: AnchorUser, Stream: blob.StreamHot, WriterID: AnchorWriterID, WriterCounter: c}
		sealed, err := blobtest.SealWithNonce3(env, 1, k1, prev, s.bytes(12), padPlaintext(s, 40*int(c)))
		if err != nil {
			return err
		}
		h := blob.Hash(prev, sealed)
		// A copy: prev is reassigned below, and prev[:] would alias it, so
		// every row would list the last hash.
		rows = append(rows, chainRow{c, bytes.Clone(prev[:]), sealed.Bytes, h[:]})
		prev = h
	}
	var steps []v1Step
	p := blob.ZeroHash
	for _, fill := range []byte{0xab, 0xcd} {
		b := bytes.Repeat([]byte{fill}, 1024)
		h := sha256.Sum256(append(append([]byte(nil), p[:]...), b...))
		steps = append(steps, v1Step{bytes.Clone(p[:]), hex.EncodeToString([]byte{fill}), 1024, h[:]})
		p = h
	}
	// Each listed prev_hash is its predecessor's blob_hash (0^32 first).
	for i, r := range rows {
		want := make([]byte, 32)
		if i > 0 {
			want = rows[i-1].BlobHash
		}
		if !bytes.Equal(r.PrevHash, want) {
			return fmt.Errorf("chain.json: row %d's prev_hash is not its predecessor's blob_hash", i)
		}
	}
	for i, st := range steps {
		want := make([]byte, 32)
		if i > 0 {
			want = steps[i-1].BlobHash
		}
		if !bytes.Equal(st.Prev, want) {
			return fmt.Errorf("chain.json: v1 step %d's prev_hash is not its predecessor's blob_hash", i)
		}
	}
	if hex.EncodeToString(steps[0].BlobHash) != "b972e78fb27a0866f41fd72ab4687e18aed94a66c8e32314ac654e8247c3e3d3" ||
		hex.EncodeToString(steps[1].BlobHash) != "1eb123521be8de11640db812996ae32d973f6ed53d3eff1f3e080fa377761eb4" {
		return errors.New("chain.json: the v1 golden steps do not reproduce")
	}
	return f.json(CryptoDir+"/chain.json", struct {
		Note    string     `json:"note"`
		UserID  uuid.UUID  `json:"user_id"`
		Writer  string     `json:"writer_id"`
		KE      H          `json:"k_e"`
		Rows    []chainRow `json:"rows"`
		V1Steps []v1Step   `json:"v1_chain_steps"`
	}{
		Note: "spec 01 §7: blob_hash[c] = SHA256(blob_hash[c−1] ‖ frame[c]), blob_hash[0] = 0^32, per (user, writer, hot). " +
			"rows is a 5-frame chain of real sealed frames (each opens under k_e after its prev_hash); v1_chain_steps reproduces " +
			"conformance/blob/manifest.json's chain_steps.",
		UserID: AnchorUser, Writer: AnchorWriterID, KE: k1, Rows: rows, V1Steps: steps,
	})
}

// ---------------------------------------------------------------------------
// predicate.json: spec 01 §8.1, the cases Go, Swift and SQL must agree on.
// ---------------------------------------------------------------------------

// Patch overwrites bytes at an offset.
type Patch struct {
	At  int `json:"at"`
	Hex H   `json:"hex"`
}

// PredicateCase is one predicate.json case. A frame is the first N bytes of
// the filler stream with Patches applied, or Frame verbatim when it is set.
type PredicateCase struct {
	Name    string  `json:"name"`
	N       int     `json:"n"`
	Patches []Patch `json:"patches,omitempty"`
	Frame   H       `json:"frame,omitempty"`
	Want    string  `json:"want"` // "ok" or the first failing check's name
}

// FillerLabel names the filler stream: block i = SHA256(utf8(label) ‖ u32be(i)).
const FillerLabel = "predicate-filler"

// Filler is the first n bytes of the filler stream.
func Filler(n int) []byte {
	out := make([]byte, 0, n+32)
	for i := uint32(0); len(out) < n; i++ {
		h := sha256.Sum256(binary.BigEndian.AppendUint32([]byte(FillerLabel), i))
		out = append(out, h[:]...)
	}
	return out[:n]
}

// Build returns the case's frame.
func (c PredicateCase) Build() []byte {
	if c.Frame != nil {
		return append([]byte(nil), c.Frame...)
	}
	b := Filler(c.N)
	for _, p := range c.Patches {
		copy(b[p.At:], p.Hex)
	}
	return b
}

func header(epoch uint32, l int) []Patch {
	h := []byte{blob.Version3}
	h = binary.BigEndian.AppendUint32(h, epoch)
	h = binary.BigEndian.AppendUint16(h, uint16(l))
	return []Patch{{0, h}}
}

func genPredicate(f Files, root string) error {
	var cs []PredicateCase
	add := func(name string, n int, want string, p ...Patch) {
		cs = append(cs, PredicateCase{Name: name, N: n, Patches: p, Want: want})
	}
	for _, n := range blob.Buckets {
		add(fmt.Sprintf("bucket %d", n), n, "ok", header(1, 83)...)
	}
	add("empty", 0, blob.CheckBucket)
	add("one byte", 1, blob.CheckBucket, Patch{0, []byte{3}})
	add("1023 bytes", 1023, blob.CheckBucket, header(1, 83)...)
	add("1025 bytes", 1025, blob.CheckBucket, header(1, 83)...)
	add("2048 bytes (between rungs)", 2048, blob.CheckBucket, header(1, 83)...)
	for _, v := range []byte{0x00, 0x01, 0x02, 0x04, 0xff} {
		h := header(1, 83)
		h[0].Hex[0] = v
		add(fmt.Sprintf("version %02x", v), 1024, blob.CheckVersion, h...)
	}
	for _, e := range []struct {
		epoch uint32
		want  string
	}{{0, blob.CheckEpoch}, {1, "ok"}, {0x7fffffff, "ok"}, {0x80000000, blob.CheckEpoch}, {0x80000001, blob.CheckEpoch}, {0xffffffff, blob.CheckEpoch}} {
		add(fmt.Sprintf("epoch %08x", e.epoch), 1024, e.want, header(e.epoch, 83)...)
	}
	add("aad_len L + 67 = n", 1024, "ok", header(1, 1024-67)...)
	add("aad_len L + 67 = n + 1", 1024, blob.CheckAADLen, header(1, 1024-66)...)
	add("aad_len 0xffff", 1024, blob.CheckAADLen, header(1, 0xffff)...)
	add("aad_len L + 67 = n at 4096", 4096, "ok", header(1, 4096-67)...)
	at := func(name string, from int, b []byte, want string) {
		add(name, 1024, want, append(header(1, 50), Patch{from, b})...)
	}
	at("AT-P2 zero nonce [57,69)", 57, make([]byte, 12), blob.CheckNonce)
	at("AT-P2 zero tag [1008,1024)", 1008, make([]byte, 16), blob.CheckTag)
	at("AT-P2 zero tail [976,1008)", 976, make([]byte, 32), blob.CheckTail)
	at("AT-P2 gzip at [73,76)", 73, []byte{0x1f, 0x8b, 0x08}, blob.CheckGzip)
	at("AT-P2 gzip at [72,75) is not the window", 72, []byte{0x1f, 0x8b, 0x08}, "ok")
	at("AT-P2 gzip at [74,77) is not the window", 74, []byte{0x1f, 0x8b, 0x08}, "ok")
	at("nonce with one non-zero byte", 57, append(make([]byte, 11), 1), "ok")
	at("tail with one non-zero byte", 976, append(make([]byte, 31), 1), "ok")
	{
		// ledgerd's v1 plaintext fixture (spec 01 V-B), verbatim.
		v1, err := os.ReadFile(filepath.Join(root, "conformance/blob/hot-dev-a-7.bin"))
		if err != nil {
			return err
		}
		cs = append(cs, PredicateCase{Name: "ledgerd v1 fixture conformance/blob/hot-dev-a-7.bin", N: len(v1), Frame: v1, Want: blob.CheckVersion})
	}
	{
		// A sealed frame (A09) passes.
		a := anchorFrame1()
		cs = append(cs, PredicateCase{Name: "anchor frame A09", N: len(a), Frame: a, Want: "ok"})
	}
	for _, c := range cs {
		got := "ok"
		var re *blob.RefusalError
		if err := blob.LooksSealed(c.Build()); errors.As(err, &re) {
			got = re.Check
		}
		if got != c.Want {
			return fmt.Errorf("predicate.json %q: LooksSealed says %s, the case says %s", c.Name, got, c.Want)
		}
	}
	return f.json(CryptoDir+"/predicate.json", struct {
		Note   string          `json:"note"`
		Filler string          `json:"filler"`
		Checks []string        `json:"checks"`
		Cases  []PredicateCase `json:"cases"`
	}{
		Note: "spec 01 §8.1: Go LooksSealed, Swift LooksSealed and SELECT hasala_frame_is_sealed($1) must agree on every case " +
			"(SQL: true for ok, false otherwise). A frame is the first n bytes of the filler stream with each patch written at its " +
			"offset, or frame verbatim when present.",
		Filler: "block i = SHA256(utf8(\"" + FillerLabel + "\") ‖ u32be(i)), i = 0, 1, …; the stream is the blocks concatenated",
		Checks: []string{blob.CheckBucket, blob.CheckVersion, blob.CheckEpoch, blob.CheckAADLen, blob.CheckNonce, blob.CheckTag, blob.CheckTail, blob.CheckGzip},
		Cases:  cs,
	})
}
