package cryptoref

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// The reader's order of checks (spec 01 §6.6, R0–R10, with §7.1's R2b), as a
// reference for the tamper suite. The device's reader is Swift's; this one
// exists so the generator can state, and the Go tests can check, what each
// tamper case must produce. It is deliberately literal: every step in the
// spec's order, the first failing step deciding the outcome.

// Outcome is what the reader does with one row.
type Outcome struct {
	Kind   string `json:"kind"`             // opened | tampered | updateRequired | needsUnlock | setAside
	Reason string `json:"reason,omitempty"` // tampered and setAside reasons, as spec 01 §6.6 names them
	Alarm  bool   `json:"alarm,omitempty"`  // setAside(aeadFailed) raises the integrity alarm
	Epoch  uint32 `json:"epoch,omitempty"`  // needsUnlock(e)
}

// HardStop reports whether the outcome stops the whole page.
func (o Outcome) HardStop() bool {
	return o.Kind == "tampered" || o.Kind == "updateRequired" || o.Kind == "needsUnlock"
}

func (o Outcome) String() string {
	switch {
	case o.Kind == "needsUnlock":
		return fmt.Sprintf("needsUnlock(%d)", o.Epoch)
	case o.Reason != "" && o.Alarm:
		return o.Kind + "(" + o.Reason + ", alarm)"
	case o.Reason != "":
		return o.Kind + "(" + o.Reason + ")"
	}
	return o.Kind
}

func tampered(r string) Outcome { return Outcome{Kind: "tampered", Reason: r} }
func setAside(r string, alarm bool) Outcome {
	return Outcome{Kind: "setAside", Reason: r, Alarm: alarm}
}

// Row is one pulled op-log row as the device sees it.
type Row struct {
	Stream        string `json:"stream"`
	WriterID      string `json:"writer_id"`
	WriterCounter int64  `json:"writer_counter"`
	SizeBucket    int    `json:"size_bucket"`
	Blob          []byte `json:"-"`
	BlobHash      []byte `json:"-"`
	PrevHash      []byte `json:"-"`
	HeadSig       []byte `json:"-"` // nil on every row of a batch but its last
}

// RosterEntry is one verified roster entry (spec 01 §10.13).
type RosterEntry struct {
	Pub          []byte
	Live         bool
	FinalCounter int64  // revoked writers: the pinned final head
	FinalHead    []byte // revoked writers
}

// Head is a pinned (counter, blob_hash).
type Head struct {
	Counter int64
	Hash    [32]byte
}

// ReaderState is everything the reader consults.
type ReaderState struct {
	User        uuid.UUID
	Roster      map[string]RosterEntry
	Heads       map[string]Head   // pinned heads; absent = (0, 0^32)
	Keys        map[uint32][]byte // K_e in the Keychain
	EpochHWM    uint32
	ServerEpoch uint32 // current_epoch, as a re-read of GET /keys would report
	OwnWriter   string // this device's writer, or ""
	OwnHead     int64  // this device's authored head
	Schema      int    // the reader's SCHEMA_VERSION
	KnownTypes  map[string]bool
}

// PageResult is what the reader makes of one page: the outcome of every row
// it opened, and the hard stop that ended the page, if one did. A hard stop in
// R0–R2b names its row before any blob is opened, so Rows is then empty.
type PageResult struct {
	Rows []Outcome `json:"rows"`
	Stop *Stop     `json:"hard_stop,omitempty"`
}

// Stop is a hard stop and the row (0-based, in page order) it names.
type Stop struct {
	Row     int     `json:"row"`
	Outcome Outcome `json:"outcome"`
}

// ReadPage runs §6.6 over one pulled page.
func ReadPage(st ReaderState, rows []Row) PageResult {
	stop := func(i int, o Outcome) PageResult {
		return PageResult{Rows: []Outcome{}, Stop: &Stop{Row: i, Outcome: o}}
	}
	// R0 and R1, and the own-writer rule, for every row first.
	for i, r := range rows {
		if !rowShapeOK(r) {
			return stop(i, tampered("rowShape"))
		}
		if _, ok := st.Roster[r.WriterID]; !ok {
			return stop(i, tampered("unknownWriter"))
		}
		if st.OwnWriter != "" && r.WriterID == st.OwnWriter && r.WriterCounter > st.OwnHead {
			return stop(i, tampered("ownChainConflict"))
		}
	}
	// R2: each writer's rows chain from its pinned head.
	tip := map[string]Head{}
	for w, h := range st.Heads {
		tip[w] = h
	}
	for i, r := range rows {
		h := tip[r.WriterID]
		if r.WriterCounter != h.Counter+1 || !bytes.Equal(r.PrevHash, h.Hash[:]) {
			return stop(i, tampered("chainBreak"))
		}
		got := sha256.Sum256(append(append([]byte(nil), r.PrevHash...), r.Blob...))
		if !bytes.Equal(got[:], r.BlobHash) {
			return stop(i, tampered("chainBreak"))
		}
		tip[r.WriterID] = Head{Counter: r.WriterCounter, Hash: got}
	}
	// R2b: each writer's last row in the page is head-signed under its roster
	// DWK; a revoked writer's rows stop at its pinned final head.
	last := map[string]int{}
	for i, r := range rows {
		last[r.WriterID] = i
	}
	writers := make([]string, 0, len(last))
	for w := range last {
		writers = append(writers, w)
	}
	sort.Slice(writers, func(a, b int) bool { return last[writers[a]] < last[writers[b]] })
	for _, w := range writers {
		e := st.Roster[w]
		for i, r := range rows {
			if r.WriterID != w || e.Live {
				continue
			}
			if r.WriterCounter > e.FinalCounter ||
				(r.WriterCounter == e.FinalCounter && !bytes.Equal(r.BlobHash, e.FinalHead)) {
				return stop(i, tampered("afterRevocation"))
			}
		}
		i := last[w]
		r := rows[i]
		if r.HeadSig == nil {
			return stop(i, tampered("headUnsigned"))
		}
		msg, err := keyproto.HeadMessage(st.User, uint64(r.WriterCounter), r.BlobHash, w)
		if err != nil || !keyproto.VerifyEd25519(e.Pub, msg, r.HeadSig) {
			return stop(i, tampered("headInvalid"))
		}
	}
	// R3–R10 per row.
	out := PageResult{Rows: []Outcome{}}
	for i, r := range rows {
		o := st.open(r)
		if o.Kind == "updateRequired" && !st.Roster[r.WriterID].Live {
			o = setAside("opsUndecodable", false)
		}
		if o.HardStop() {
			out.Stop = &Stop{Row: i, Outcome: o}
			return out
		}
		out.Rows = append(out.Rows, o)
	}
	return out
}

var writerGrammarOK = keyproto.ValidWriterID

func rowShapeOK(r Row) bool {
	return r.Stream == blob.StreamHot && writerGrammarOK(r.WriterID) && r.WriterCounter >= 1 &&
		r.SizeBucket == len(r.Blob) && blob.IsBucket(len(r.Blob)) &&
		len(r.BlobHash) == 32 && len(r.PrevHash) == 32
}

// open is R3–R10 for one row whose chain and head already verified.
func (st ReaderState) open(r Row) Outcome {
	b := r.Blob
	// R3
	switch {
	case b[0] > blob.Version3:
		return Outcome{Kind: "updateRequired"}
	case b[0] != blob.Version3:
		return tampered("legacyFrame")
	}
	// R4
	n := len(b)
	l := int(binary.BigEndian.Uint16(b[5:7]))
	e := binary.BigEndian.Uint32(b[1:5])
	if l+67 > n || e == 0 || e > blob.MaxEpoch {
		return tampered("badHeader")
	}
	if e > st.EpochHWM && st.ServerEpoch < e {
		return tampered("epochInvalid")
	}
	// R5
	want := blob.Envelope{UserID: st.User, Stream: blob.StreamHot, WriterID: r.WriterID, WriterCounter: r.WriterCounter}.AAD()
	if subtle.ConstantTimeCompare(b[blob.FixedHeaderSize:blob.FixedHeaderSize+l], want) != 1 {
		return tampered("aadMismatch")
	}
	// R6
	key, ok := st.Keys[e]
	if !ok {
		return Outcome{Kind: "needsUnlock", Epoch: e}
	}
	// R7
	region, err := blobtest.OpenRegion3(key, [32]byte(r.PrevHash), b)
	if err != nil {
		return setAside("aeadFailed", true)
	}
	// R8
	g, err := blobtest.RegionPayload(region)
	if err != nil {
		return setAside("regionMalformed", false)
	}
	// R9
	pt, err := blobtest.GunzipStrict(g)
	if err != nil {
		return setAside("payloadInvalid", false)
	}
	// R10
	return st.decode(pt)
}

// decode is R10 with the blob as the unit: a version above the reader's
// schema stops; any other envelope failure of any op sets the whole blob
// aside. It checks only the envelope fields R10 names, against the reader's
// known op types; the op specs own the rest.
func (st ReaderState) decode(pt []byte) Outcome {
	var env struct {
		V    *int              `json:"v"`
		Kind string            `json:"kind"`
		Ops  []json.RawMessage `json:"ops"`
	}
	if err := json.Unmarshal(pt, &env); err != nil || env.V == nil || env.Kind != "ops" {
		return setAside("opsUndecodable", false)
	}
	if *env.V > st.Schema+1 {
		return setAside("opsUndecodable", false)
	}
	if *env.V > st.Schema {
		return Outcome{Kind: "updateRequired"}
	}
	for _, raw := range env.Ops {
		var op struct {
			V    *int   `json:"v"`
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &op); err != nil || op.V == nil {
			return setAside("opsUndecodable", false)
		}
		if *op.V > st.Schema+1 {
			return setAside("opsUndecodable", false)
		}
		if *op.V > st.Schema {
			return Outcome{Kind: "updateRequired"}
		}
		if !st.KnownTypes[op.Type] {
			return setAside("opsUndecodable", false)
		}
	}
	return Outcome{Kind: "opened"}
}
