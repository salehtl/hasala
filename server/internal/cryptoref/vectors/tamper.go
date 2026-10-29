package vectors

import (
	"bytes"
	"compress/flate"
	"crypto/ed25519"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	. "github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// tamper.json: spec 01 §15.3's T-cases. Each case is a page the reader is
// served and, where the table has one, the upload the server must refuse or
// accept. The reader outcome is computed by cryptoref.ReadPage and must equal
// the table's (the generator refuses to write a disagreement); the server
// verdict is the table's, and internal/api's TestTamperUploadsGetTheirVerdict
// posts every upload to the real handler and requires it.

// Tamper actors. W is the anchor writer; W2 a second live writer; R a revoked
// writer. DWK seeds are patterned (spec 01 §15.5 for W).
var (
	TamperW2       = "ios-1b2c3d4e-5f60-4b7c-9d8e-0f1a2b3c4d5e"
	TamperW2Seed   = Range(0xa0, 0xbf)
	TamperR        = "ios-2c3d4e5f-6071-4c8d-ae9f-1a2b3c4d5e6f"
	TamperRSeed    = Range(0xe0, 0xff)
	TamperOtherKey = bytes.Repeat([]byte{0x22}, 32) // K_1' (T17) and K_2 (T07)
)

// TamperRow is a row as served, or as uploaded.
type TamperRow struct {
	Stream     string `json:"stream"`
	WriterID   string `json:"writer_id"`
	Counter    int64  `json:"writer_counter"`
	SizeBucket int    `json:"size_bucket"`
	PrevHash   H      `json:"prev_hash"`
	BlobHash   H      `json:"blob_hash"`
	HeadSig    H      `json:"head_sig"`
	Blob       H      `json:"blob"`
}

// ServerVerdict is the upload's expected answer: status 200, or a status, an
// error code and, for plaintext_refused, the check.
type ServerVerdict struct {
	Status int    `json:"status"`
	Error  string `json:"error,omitempty"`
	Check  string `json:"check,omitempty"`
}

// TamperUpload is POST /api/v1/sync's body (hex instead of b64) and the
// account state it is posted into: the anchor user, writer W bound to the
// session, the anchor frame at counter 1 already stored, and current_epoch.
type TamperUpload struct {
	ServerEpoch   uint32        `json:"server_epoch"`
	WriterRevoked bool          `json:"writer_revoked"`
	WriterID      string        `json:"writer_id"`
	Stream        string        `json:"stream"`
	Row           TamperRow     `json:"blob"`
	HeadSig       H             `json:"head_sig"`
	Verdict       ServerVerdict `json:"verdict"`
}

// TamperState is the reader state: the defaults of spec 01 §15.3 unless a case
// changes them.
type TamperState struct {
	Keys        map[string]H         `json:"keys"` // epoch (decimal) → K_e
	EpochHWM    uint32               `json:"epoch_hwm"`
	ServerEpoch uint32               `json:"server_epoch"`
	Pinned      map[string]tamperPin `json:"pinned_heads"`
	Roster      map[string]rosterRow `json:"roster"`
	OwnWriter   string               `json:"own_writer,omitempty"`
	OwnHead     int64                `json:"own_authored_head,omitempty"`
}

type tamperPin struct {
	Counter int64 `json:"counter"`
	Hash    H     `json:"blob_hash"`
}

type rosterRow struct {
	Pubkey       H      `json:"pubkey"`
	Live         bool   `json:"live"`
	FinalCounter *int64 `json:"final_counter,omitempty"`
	FinalHead    H      `json:"final_head,omitempty"`
}

// TamperCase is one case.
type TamperCase struct {
	ID     string        `json:"id"`
	Name   string        `json:"name"`
	State  TamperState   `json:"reader_state"`
	Page   []TamperRow   `json:"page"`
	Reader PageResult    `json:"reader"`
	Expect string        `json:"reader_expected"`
	After  *PageResult   `json:"reader_after_unlock,omitempty"` // T07
	Upload *TamperUpload `json:"upload"`
	Note   string        `json:"note,omitempty"`
}

// TamperFile is tamper.json.
type TamperFile struct {
	Note       string       `json:"note"`
	UserID     uuid.UUID    `json:"user_id"`
	WriterID   string       `json:"writer_id"`
	DWKSeed    H            `json:"writer_dwk_seed"`
	Frame1     H            `json:"stored_frame_counter_1"`
	Frame1Hash H            `json:"stored_blob_hash_counter_1"`
	Frame1Sig  H            `json:"stored_head_sig_counter_1"`
	Schema     int          `json:"reader_schema"`
	KnownTypes []string     `json:"reader_known_op_types"`
	Cases      []TamperCase `json:"cases"`
}

var knownTypes = []string{"txn_categorized", "txn_annotated"}

const baseOp = `{"v":4,"type":"txn_categorized","op_id":"01JA4A1B2C3D4E5F6G7H8J9K0M","authored_at":"2026-10-09T15:20:11.042Z",` +
	`"entity":{"kind":"txn","id":"01JA3M5Q8Z9X2K7V4T6R1N0BCD"},"parent_version":3,` +
	`"payload":{"category":"groceries","needs_review":false,"source":{"kind":"user"}}}`

func opBlob(v int, ops ...string) []byte {
	return []byte(fmt.Sprintf(`{"v":%d,"kind":"ops","ops":[%s]}`, v, strings.Join(ops, ",")))
}

func headSig(seed []byte, user uuid.UUID, counter int64, hash []byte, writer string) []byte {
	m, err := keyproto.HeadMessage(user, uint64(counter), hash, writer)
	if err != nil {
		panic(err)
	}
	return ed25519.Sign(ed25519.NewKeyFromSeed(seed), m)
}

// served is a row chained after prev and head-signed by seed (nil: unsigned).
func served(frame []byte, writer string, counter int64, prev []byte, seed []byte) TamperRow {
	h := blob.Hash([32]byte(prev), blob.Sealed{Bytes: frame})
	r := TamperRow{Stream: blob.StreamHot, WriterID: writer, Counter: counter, SizeBucket: len(frame),
		PrevHash: prev, BlobHash: h[:], Blob: frame}
	if seed != nil {
		r.HeadSig = headSig(seed, AnchorUser, counter, h[:], writer)
	}
	return r
}

func sealAt(user uuid.UUID, writer string, counter int64, epoch uint32, key []byte, prev []byte, nonce []byte, region []byte) []byte {
	env := blob.Envelope{UserID: user, Stream: blob.StreamHot, WriterID: writer, WriterCounter: counter}
	header, err := blob.Header3(env, epoch)
	if err != nil {
		panic(err)
	}
	f, err := blobtest.SealRegion3(key, header, [32]byte(prev), nonce, region)
	if err != nil {
		panic(err)
	}
	return f
}

// regionFor builds R for a payload G in the smallest bucket that holds it at
// L = 83.
func regionFor(g []byte) []byte {
	bucket, err := blob.BucketFor(39 + 83 + len(g))
	if err != nil {
		panic(err)
	}
	r, err := blobtest.Region3(g, bucket-35-83)
	if err != nil {
		panic(err)
	}
	return r
}

func gz(p []byte) []byte {
	g, err := blobtest.Gzip(p)
	if err != nil {
		panic(err)
	}
	return g
}

func genTamper(f Files, root string) error {
	k1 := EpochKey1(AnchorAMK, AnchorUser)
	frame1 := anchorFrame1()
	h1 := blob.Hash(blob.ZeroHash, blob.Sealed{Bytes: frame1})
	w := AnchorWriterID
	wSeed := AnchorDWKSeed
	pub := func(seed []byte) H { return H(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)) }
	zero := int64(0)

	baseState := func() TamperState {
		return TamperState{
			Keys: map[string]H{"1": k1}, EpochHWM: 1, ServerEpoch: 1,
			Pinned: map[string]tamperPin{w: {1, h1[:]}},
			Roster: map[string]rosterRow{
				w:        {Pubkey: pub(wSeed), Live: true},
				TamperW2: {Pubkey: pub(TamperW2Seed), Live: true},
				TamperR:  {Pubkey: pub(TamperRSeed), Live: false, FinalCounter: &zero, FinalHead: make([]byte, 32)},
			},
		}
	}
	sealBase := func(plain []byte) []byte {
		return sealAt(AnchorUser, w, 2, 1, k1, h1[:], AnchorFrameNonce2, regionFor(gz(plain)))
	}
	base := sealBase(opBlob(4, baseOp))
	upload := func(r TamperRow, v ServerVerdict) *TamperUpload {
		sig := r.HeadSig
		r.HeadSig = nil // the batch's head_sig travels beside the blobs
		return &TamperUpload{ServerEpoch: 1, WriterID: r.WriterID, Stream: r.Stream, Row: r, HeadSig: sig, Verdict: v}
	}
	accept := ServerVerdict{Status: 200}
	refused := func(check string) ServerVerdict {
		return ServerVerdict{Status: 400, Error: "plaintext_refused", Check: check}
	}

	var cases []TamperCase
	add := func(id, name string, st TamperState, page []TamperRow, expect string, up *TamperUpload, note string) *TamperCase {
		cases = append(cases, TamperCase{ID: id, Name: name, State: st, Page: page, Expect: expect, Upload: up, Note: note})
		return &cases[len(cases)-1]
	}
	// mutate builds a served row from a mutated copy of the base frame.
	mutate := func(fn func([]byte) []byte) TamperRow {
		return served(fn(append([]byte(nil), base...)), w, 2, h1[:], wSeed)
	}
	one := func(r TamperRow) []TamperRow { return []TamperRow{r} }

	r := served(base, w, 2, h1[:], wSeed)
	add("T01", "no mutation", baseState(), one(r), "opened", upload(r, accept), "")

	for _, v := range []struct {
		id     string
		b      byte
		expect string
	}{{"T02", 0x01, "tampered(legacyFrame)"}, {"T03", 0x02, "tampered(legacyFrame)"}, {"T03", 0x00, "tampered(legacyFrame)"}, {"T04", 0x04, "updateRequired"}} {
		r := mutate(func(b []byte) []byte { b[0] = v.b; return b })
		add(v.id, fmt.Sprintf("version → 0x%02x", v.b), baseState(), one(r), v.expect, upload(r, refused(blob.CheckVersion)), "")
	}
	epoch := func(e uint32) func([]byte) []byte {
		return func(b []byte) []byte { binary.BigEndian.PutUint32(b[1:5], e); return b }
	}
	r = mutate(epoch(0))
	add("T05", "epoch → 0", baseState(), one(r), "tampered(badHeader)", upload(r, refused(blob.CheckEpoch)), "")
	r = mutate(epoch(2))
	add("T06", "epoch → 2, server epoch 1", baseState(), one(r), "tampered(epochInvalid)",
		upload(r, ServerVerdict{Status: 409, Error: "stale_epoch"}), "")
	{
		st := baseState()
		st.ServerEpoch = 2
		up := upload(r, accept)
		up.ServerEpoch = 2
		add("T07", "epoch → 2, server epoch 2, no K_2", st, one(r), "needsUnlock(2)", up,
			"reader_after_unlock holds K_2 = 22×32; the frame was sealed under K_1 at epoch 1, so it fails AEAD")
	}
	aadLen := func(l uint16) func([]byte) []byte {
		return func(b []byte) []byte { binary.BigEndian.PutUint16(b[5:7], l); return b }
	}
	r = mutate(aadLen(84))
	add("T08", "aad_len + 1", baseState(), one(r), "tampered(aadMismatch)", upload(r, ServerVerdict{Status: 400, Error: "aad_mismatch"}), "")
	r = mutate(aadLen(82))
	add("T08", "aad_len − 1", baseState(), one(r), "tampered(aadMismatch)", upload(r, ServerVerdict{Status: 400, Error: "aad_mismatch"}), "")
	r = mutate(aadLen(0xffff))
	add("T08", "aad_len → 0xffff", baseState(), one(r), "tampered(badHeader)", upload(r, refused(blob.CheckAADLen)), "")
	for i := 7; i < 7+83; i++ {
		i := i
		r := mutate(func(b []byte) []byte { b[i] ^= 0x01; return b })
		add("T09", fmt.Sprintf("AAD byte %d XOR 01", i-7), baseState(), one(r), "tampered(aadMismatch)",
			upload(r, ServerVerdict{Status: 400, Error: "aad_mismatch"}), "")
	}
	for i := 90; i < 102; i++ {
		i := i
		r := mutate(func(b []byte) []byte { b[i] ^= 0x01; return b })
		add("T10", fmt.Sprintf("nonce byte %d XOR 01", i-90), baseState(), one(r), "setAside(aeadFailed, alarm)", upload(r, accept), "")
	}
	ctLen := len(base) - 102 - 16
	for _, j := range ctOffsets(ctLen) {
		j := j
		r := mutate(func(b []byte) []byte { b[102+j] ^= 0x01; return b })
		add("T11", fmt.Sprintf("ciphertext byte %d XOR 01", j), baseState(), one(r), "setAside(aeadFailed, alarm)", upload(r, accept), "")
	}
	for i := len(base) - 16; i < len(base); i++ {
		i := i
		r := mutate(func(b []byte) []byte { b[i] ^= 0x01; return b })
		add("T12", fmt.Sprintf("tag byte %d XOR 01", i-(len(base)-16)), baseState(), one(r), "setAside(aeadFailed, alarm)", upload(r, accept), "")
	}
	other := Hex(Anchors["A10 blob_hash"])
	add("T13", "row prev_hash ≠ the pinned head", baseState(), one(served(base, w, 2, other, wSeed)), "tampered(chainBreak)", nil,
		"a server-side splice: there is no upload")
	{
		fork := sealAt(AnchorUser, w, 2, 1, k1, other, AnchorFrameNonce2, regionFor(gz(opBlob(4, baseOp))))
		add("T14", "fork splice: frame 2 sealed after H′, served after frame 1 with consistent hashes", baseState(),
			one(served(fork, w, 2, h1[:], wSeed)), "setAside(aeadFailed, alarm)", nil,
			"the chain verifies and the head is W's own signature; the AEAD binding of prev_hash is what refuses it (C1)")
	}
	{
		r2 := served(base, w, 2, h1[:], nil)
		r3 := served(base, w, 3, r2.BlobHash, wSeed)
		add("T15", "frame 2 also served at counter 3, chain recomputed", baseState(), []TamperRow{r2, r3},
			"tampered(aadMismatch)", nil, "row 0 opens; row 1 stops the page")
	}
	{
		u2 := uuid.MustParse("3b0e5c1a-7d2f-4e8a-9b6c-1f2e3d4c5b6a")
		fr := sealAt(u2, w, 2, 1, k1, h1[:], AnchorFrameNonce2, regionFor(gz(opBlob(4, baseOp))))
		add("T16", "another user's frame, chain recomputed", baseState(), one(served(fr, w, 2, h1[:], wSeed)),
			"tampered(aadMismatch)", nil, "")
	}
	{
		st := baseState()
		st.Keys = map[string]H{"1": TamperOtherKey}
		add("T17", "the device holds K_1′ ≠ K_1", st, one(served(base, w, 2, h1[:], wSeed)), "setAside(aeadFailed, alarm)", nil, "")
	}
	{
		short := served(base[:1023], w, 2, h1[:], wSeed)
		short.SizeBucket = 1024
		add("T18", "truncated to 1023 bytes", baseState(), one(short), "tampered(rowShape)", upload(short, ServerVerdict{Status: 400, Error: "bad_bucket"}), "")
		long := served(append(append([]byte(nil), base...), 0x5a), w, 2, h1[:], wSeed)
		long.SizeBucket = 1024
		add("T18", "extended to 1025 bytes", baseState(), one(long), "tampered(rowShape)", upload(long, ServerVerdict{Status: 400, Error: "bad_bucket"}), "")
	}
	{
		reg := regionFor(gz(opBlob(4, baseOp)))
		binary.BigEndian.PutUint32(reg, uint32(len(reg)-3))
		r := served(sealAt(AnchorUser, w, 2, 1, k1, h1[:], AnchorFrameNonce2, reg), w, 2, h1[:], wSeed)
		add("T19", "authenticated R with m = |R| − 3", baseState(), one(r), "setAside(regionMalformed)", upload(r, accept), "")
	}
	{
		var raw bytes.Buffer
		fw, _ := flate.NewWriter(&raw, 9)
		_, _ = fw.Write(opBlob(4, baseOp))
		_ = fw.Close()
		r := served(sealAt(AnchorUser, w, 2, 1, k1, h1[:], AnchorFrameNonce2, regionFor(raw.Bytes())), w, 2, h1[:], wSeed)
		add("T20", "authenticated raw deflate (no gzip wrapper)", baseState(), one(r), "setAside(payloadInvalid)", upload(r, accept), "")
	}
	{
		g := gz(opBlob(4, baseOp))
		trail := append(append([]byte(nil), g...), 'x', 'x')
		r := served(sealAt(AnchorUser, w, 2, 1, k1, h1[:], AnchorFrameNonce2, regionFor(trail)), w, 2, h1[:], wSeed)
		add("T21", "authenticated gzip followed by two trailing bytes", baseState(), one(r), "setAside(payloadInvalid)", upload(r, accept), "")
		two := append(append([]byte(nil), g...), g...)
		r = served(sealAt(AnchorUser, w, 2, 1, k1, h1[:], AnchorFrameNonce2, regionFor(two)), w, 2, h1[:], wSeed)
		add("T21", "authenticated gzip with two members", baseState(), one(r), "setAside(payloadInvalid)", upload(r, accept), "")
	}
	for _, x := range []struct {
		id     string
		n      int
		expect string
	}{{"T22", blob.MaxPlaintext, "opened"}, {"T23", blob.MaxPlaintext + 1, "setAside(payloadInvalid)"}} {
		p := opBlob(4, baseOp)
		p = append(p, bytes.Repeat([]byte{' '}, x.n-len(p))...)
		r := served(sealBase(p), w, 2, h1[:], wSeed)
		add(x.id, fmt.Sprintf("authenticated gzip of op JSON padded with whitespace to %d bytes", x.n), baseState(), one(r),
			x.expect, upload(r, accept), "")
	}
	{
		r := served(sealBase(opBlob(99, baseOp)), w, 2, h1[:], wSeed)
		add("T24", `authenticated op blob "v": 99`, baseState(), one(r), "setAside(opsUndecodable)", upload(r, accept),
			"only the reader's schema + 1 stops sync; a larger version is set aside")
	}
	{
		v1, err := os.ReadFile(filepath.Join(root, "conformance/blob/hot-dev-a-7.bin"))
		if err != nil {
			return err
		}
		r := served(v1, w, 2, h1[:], wSeed)
		add("T25", "ledgerd conformance/blob/hot-dev-a-7.bin", baseState(), one(r), "tampered(legacyFrame)", upload(r, refused(blob.CheckVersion)), "")
	}
	{
		env := blob.Envelope{UserID: AnchorUser, Stream: blob.StreamHot, WriterID: w, WriterCounter: 2}
		header, _ := blob.Header3(env, 1)
		reg := regionFor(gz(opBlob(4, baseOp)))
		fr := append(append(append(append([]byte(nil), header...), bytes.Repeat([]byte{0x5a}, 12)...), reg...), bytes.Repeat([]byte{0xa5}, 16)...)
		r := served(fr, w, 2, h1[:], wSeed)
		add("T26", "forgot to encrypt: v3 header, nonce and tag, cleartext R", baseState(), one(r), "setAside(aeadFailed, alarm)",
			upload(r, refused(blob.CheckTail)), "")
	}
	{
		r := served(base, w, 2, h1[:], wSeed)
		r.Stream = "cold"
		add("T27", "row stream cold", baseState(), one(r), "tampered(rowShape)", upload(r, ServerVerdict{Status: 400, Error: "bad_stream"}), "")
	}
	{
		r := served(base, "ingest", 2, h1[:], nil)
		r.HeadSig = headSig(wSeed, AnchorUser, 2, r.BlobHash, w) // no head message exists for a malformed id
		add("T28", "row writer_id ingest", baseState(), one(r), "tampered(rowShape)", upload(r, ServerVerdict{Status: 400, Error: "bad_writer_id"}), "")
		unk := "ios-3d4e5f60-7182-4d9e-bfa0-2b3c4d5e6f70"
		fr := sealAt(AnchorUser, unk, 2, 1, k1, h1[:], AnchorFrameNonce2, regionFor(gz(opBlob(4, baseOp))))
		r = served(fr, unk, 2, h1[:], wSeed)
		add("T28", "row writer_id not in the roster", baseState(), one(r), "tampered(unknownWriter)",
			upload(r, ServerVerdict{Status: 403, Error: "writer_mismatch"}),
			"server: spec 02 §9.4 answers an upload naming a writer other than the session's with 403 writer_mismatch")
	}
	{
		st := baseState()
		st.OwnWriter, st.OwnHead = w, 1
		add("T29", "own writer: a frame above the authored head that this device did not author", st,
			one(served(base, w, 2, h1[:], wSeed)), "tampered(ownChainConflict)", nil, "")
	}
	{
		r := served(base, w, 2, h1[:], nil)
		add("T30", "the last row of W in the page carries no head_sig", baseState(), one(r), "tampered(headUnsigned)",
			upload(r, ServerVerdict{Status: 400, Error: "bad_signature"}), "")
		r = served(base, w, 2, h1[:], TamperW2Seed)
		add("T31", "head_sig by another writer's DWK", baseState(), one(r), "tampered(headInvalid)",
			upload(r, ServerVerdict{Status: 400, Error: "bad_signature"}), "")
		r = served(base, w, 2, h1[:], nil)
		r.HeadSig = headSig(wSeed, AnchorUser, 2, other, w)
		add("T32", "head_sig over another blob_hash", baseState(), one(r), "tampered(headInvalid)",
			upload(r, ServerVerdict{Status: 400, Error: "bad_signature"}), "")
		r = served(base, w, 2, h1[:], nil)
		r.HeadSig = headSig(wSeed, AnchorUser, 3, r.BlobHash, w)
		add("T32", "head_sig over another counter", baseState(), one(r), "tampered(headInvalid)",
			upload(r, ServerVerdict{Status: 400, Error: "bad_signature"}), "")
		r = served(base, w, 2, h1[:], nil)
		r.HeadSig = headSigUser(wSeed, uuid.MustParse("3b0e5c1a-7d2f-4e8a-9b6c-1f2e3d4c5b6a"), 2, r.BlobHash, w)
		add("T32", "head_sig over another user", baseState(), one(r), "tampered(headInvalid)",
			upload(r, ServerVerdict{Status: 400, Error: "bad_signature"}), "")
	}
	{
		forged := sealBase(opBlob(4, baseOp, strings.Replace(baseOp, "groceries", "transport", 1)))
		r := served(forged, w, 2, h1[:], TamperRSeed)
		add("T33", "forged row: opens under K_1, consistent chain, appended to live W, signed by a revoked writer's DWK", baseState(),
			one(r), "tampered(headInvalid)", nil, "proves R-02: a K_1 holder cannot forge as W")
	}
	{
		st := baseState()
		one1 := int64(1)
		st.Roster[w] = rosterRow{Pubkey: pub(wSeed), Live: false, FinalCounter: &one1, FinalHead: h1[:]}
		r := served(base, w, 2, h1[:], wSeed)
		up := upload(r, ServerVerdict{Status: 403, Error: "writer_revoked"})
		up.WriterRevoked = true
		add("T34", "revoked W with pinned (1, h1): a validly signed row at counter 2", st, one(r), "tampered(afterRevocation)", up, "")
		st2 := baseState()
		two := int64(2)
		st2.Roster[w] = rosterRow{Pubkey: pub(wSeed), Live: false, FinalCounter: &two, FinalHead: other}
		add("T35", "revoked W with pinned (2, A10's hash): the row at counter 2 has another blob_hash", st2,
			one(served(base, w, 2, h1[:], wSeed)), "tampered(afterRevocation)", nil, "")
	}
	{
		reserved := strings.Replace(strings.Replace(baseOp, "txn_categorized", "profile_set", 1), "01JA4A1B2C3D4E5F6G7H8J9K0M", "01JA4A1B2C3D4E5F6G7H8J9K0N", 1)
		r := served(sealBase(opBlob(4, baseOp, reserved)), w, 2, h1[:], wSeed)
		add("T36", "a valid op plus the reserved profile_set at the reader's schema", baseState(), one(r),
			"setAside(opsUndecodable)", upload(r, accept), "the whole blob is set aside; none of its ops is applied")
	}

	{
		unk := "ios-3d4e5f60-7182-4d9e-bfa0-2b3c4d5e6f70"
		zeroHash := make([]byte, 32)
		multi := "not in spec 01 §15.3: a page with more than one fault; the first failing step in the reader's order decides"
		u := served(base, unk, 2, h1[:], wSeed)
		cold := served(base, w, 2, h1[:], wSeed)
		cold.Stream = "cold"
		add("M01", "unknown writer at row 0, row shape fault at row 1", baseState(), []TamperRow{u, cold},
			"tampered(unknownWriter)", nil, multi)
		st := baseState()
		st.OwnWriter, st.OwnHead = w, 1
		add("M02", "own-writer conflict at row 0, unknown writer at row 1", st,
			[]TamperRow{served(base, w, 2, h1[:], wSeed), u}, "tampered(ownChainConflict)", nil, multi)
		add("M03", "chain break at row 0, unknown writer at row 1", baseState(),
			[]TamperRow{served(base, w, 2, other, wSeed), u}, "tampered(unknownWriter)", nil, multi)
		a := served(base, TamperW2, 1, zeroHash, nil)
		b := served(base, w, 2, h1[:], nil)
		c := served(base, TamperW2, 2, a.BlobHash, TamperRSeed)
		add("M04", "W2's last row is badly signed, W's last row comes first and is unsigned", baseState(),
			[]TamperRow{a, b, c}, "tampered(headUnsigned)", nil, multi+"; writers are checked in the order of their last row")
		st = baseState()
		one1 := int64(1)
		st.Roster[w] = rosterRow{Pubkey: pub(wSeed), Live: false, FinalCounter: &one1, FinalHead: h1[:]}
		add("M05", "revoked W with pinned (1, h1): an unsigned row at counter 2", st,
			one(served(base, w, 2, h1[:], nil)), "tampered(afterRevocation)", nil, multi+"; the pin is checked before the head signature")
		add("M06", "revoked R with pinned (0, 0^32): a row at counter 1 signed by another writer's DWK", baseState(),
			one(served(base, TamperR, 1, zeroHash, wSeed)), "tampered(afterRevocation)", nil, multi)
		add("M07", "W unsigned at row 0, revoked R past its pin at row 1", baseState(),
			[]TamperRow{b, served(base, TamperR, 1, zeroHash, TamperRSeed)}, "tampered(headUnsigned)", nil, multi)
		add("M08", "revoked R past its pin at row 0, W unsigned at row 1", baseState(),
			[]TamperRow{served(base, TamperR, 1, zeroHash, TamperRSeed), b}, "tampered(afterRevocation)", nil, multi)
		r := mutate(epoch(blob.MaxEpoch + 1))
		add("M09", "epoch → 2^31, above the largest epoch", baseState(), one(r), "tampered(badHeader)", nil, "")
	}

	// Run the reference reader and require the table's outcome.
	for i := range cases {
		c := &cases[i]
		c.Reader = ReadPage(readerState(c.State), toRows(c.Page))
		if got := describe(c.Reader); got != c.Expect {
			return fmt.Errorf("tamper.json %s %q: the reference reader says %s, spec 01 §15.3 says %s", c.ID, c.Name, got, c.Expect)
		}
		if c.ID == "T07" {
			st := c.State
			st.Keys = map[string]H{"1": k1, "2": TamperOtherKey}
			after := ReadPage(readerState(st), toRows(c.Page))
			if describe(after) != "setAside(aeadFailed, alarm)" {
				return fmt.Errorf("tamper.json T07 after unlock: %s", describe(after))
			}
			c.After = &after
		}
		if c.Upload != nil && c.Upload.Verdict.Status == 200 && blob.LooksSealed(c.Upload.Row.Blob) != nil {
			return fmt.Errorf("tamper.json %s %q: an accepted upload trips LooksSealed", c.ID, c.Name)
		}
	}
	h1sig := headSig(wSeed, AnchorUser, 1, h1[:], w)
	return f.json(CryptoDir+"/tamper.json", TamperFile{
		Note: "spec 01 §15.3. reader_state defaults: K_1 only, epoch_hwm 1, server current_epoch 1, W pinned at counter 1 " +
			"(the anchor frame A09). Each page is what the server serves; rows are chained and, where a case does not vary it, " +
			"head-signed by W so that the case isolates the check it names. reader is spec 01 §6.6's result (rows opened in " +
			"order; hard_stop names the row that stopped the page). upload, where present, is POST /api/v1/sync into an account " +
			"holding the anchor frame at counter 1 under W, with W bound to the session, and verdict is the answer. Ops in the " +
			"plaintexts follow 03c's envelope; the reader knows reader_known_op_types at reader_schema.",
		UserID: AnchorUser, WriterID: w, DWKSeed: wSeed, Frame1: frame1, Frame1Hash: h1[:], Frame1Sig: h1sig,
		Schema: 4, KnownTypes: knownTypes, Cases: cases,
	})
}

func headSigUser(seed []byte, user uuid.UUID, counter int64, hash []byte, writer string) []byte {
	m, err := keyproto.HeadMessage(user, uint64(counter), hash, writer)
	if err != nil {
		panic(err)
	}
	return ed25519.Sign(ed25519.NewKeyFromSeed(seed), m)
}

// ctOffsets is "first, last and every 64th" of a ciphertext of n bytes.
func ctOffsets(n int) []int {
	var out []int
	for j := 0; j < n; j += 64 {
		out = append(out, j)
	}
	if out[len(out)-1] != n-1 {
		out = append(out, n-1)
	}
	return out
}

func readerState(t TamperState) ReaderState {
	st := ReaderState{
		User: AnchorUser, Roster: map[string]RosterEntry{}, Heads: map[string]Head{}, Keys: map[uint32][]byte{},
		EpochHWM: t.EpochHWM, ServerEpoch: t.ServerEpoch, OwnWriter: t.OwnWriter, OwnHead: t.OwnHead,
		Schema: 4, KnownTypes: map[string]bool{},
	}
	for _, k := range knownTypes {
		st.KnownTypes[k] = true
	}
	for e, k := range t.Keys {
		var n uint32
		fmt.Sscan(e, &n)
		st.Keys[n] = k
	}
	for w, p := range t.Pinned {
		st.Heads[w] = Head{Counter: p.Counter, Hash: [32]byte(p.Hash)}
	}
	for w, r := range t.Roster {
		e := RosterEntry{Pub: r.Pubkey, Live: r.Live, FinalHead: r.FinalHead}
		if r.FinalCounter != nil {
			e.FinalCounter = *r.FinalCounter
		}
		st.Roster[w] = e
	}
	return st
}

func toRows(page []TamperRow) []Row {
	out := make([]Row, len(page))
	for i, r := range page {
		out[i] = Row{Stream: r.Stream, WriterID: r.WriterID, WriterCounter: r.Counter, SizeBucket: r.SizeBucket,
			Blob: r.Blob, BlobHash: r.BlobHash, PrevHash: r.PrevHash, HeadSig: r.HeadSig}
	}
	return out
}

// describe renders a page result as the table's outcome: the hard stop, or
// the outcome of the page's last row.
func describe(p PageResult) string {
	if p.Stop != nil {
		return p.Stop.Outcome.String()
	}
	if len(p.Rows) == 0 {
		return "empty"
	}
	return p.Rows[len(p.Rows)-1].String()
}
