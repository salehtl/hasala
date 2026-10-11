// Package vectors writes conformance/crypto-v3/ (spec 01 §15.1, owned by Go,
// WS-2) and conformance/api-v1/messages.json and stepup.json (spec 02 §22,
// the key half of WS-3). Go writes the expectations; the Swift client reads
// them and never regenerates them, and no harness recomputes its own
// expectation (critic §5.5).
//
// Generate is deterministic: every input is fixed (the anchors of spec 01
// §15.5 and seeded or patterned values), Go's Ed25519 signatures are
// deterministic, and the only randomized primitive, P-256 signing, is used
// with a fixed-stream reader so that even the sample DAK signatures are
// stable bytes (they are still verify-only: CryptoKit's differ every run).
// TestCommittedVectorsAreCurrent regenerates everything and compares it with
// the files on disk byte for byte.
//
// TEST AND VECTORS ONLY: cmd/hasalad never links this package.
package vectors

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
)

// CryptoDir and APIDir are the two output directories, relative to the
// repository root.
const (
	CryptoDir = "conformance/crypto-v3"
	APIDir    = "conformance/api-v1"
	specRef   = "spec 01 §15 (draft 2026-10-11, review 2); spec 02 §22"
	regen     = "cd server && go run ./cmd/gen-crypto-vectors"
)

// H is binary data that encodes as lowercase hex in JSON.
type H []byte

// MarshalJSON writes lowercase hex; nil is JSON null.
func (h H) MarshalJSON() ([]byte, error) {
	if h == nil {
		return []byte("null"), nil
	}
	return json.Marshal(hex.EncodeToString(h))
}

// UnmarshalJSON reads lowercase hex or null.
func (h *H) UnmarshalJSON(b []byte) error {
	if string(b) == "null" {
		*h = nil
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	v, err := hex.DecodeString(s)
	if err != nil {
		return err
	}
	*h = v
	return nil
}

func sum(b []byte) H { s := sha256.Sum256(b); return s[:] }

// Files is the generated tree: repository-relative path → bytes.
type Files map[string][]byte

func (f Files) json(path string, v any) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	f[path] = buf.Bytes()
	return nil
}

// Generate builds every file. root is the repository root; it is read only for
// ledgerd's v1 fixture conformance/blob/hot-dev-a-7.bin (tamper case T25).
func Generate(root string) (Files, error) {
	f := Files{}
	steps := []func(Files, string) error{
		genDerive, genWraps, genPhraseBox, genPhrase,
		genFrameAEAD, genFrames, genChain, genPredicate, genTamper,
		genPassword, genCodes, genApproval,
		genMessages, genStepUp,
	}
	for _, s := range steps {
		if err := s(f, root); err != nil {
			return nil, err
		}
	}
	if err := genManifest(f); err != nil {
		return nil, err
	}
	return f, nil
}

type manifestFile struct {
	Path   string `json:"path"`
	SHA256 H      `json:"sha256"`
}

type manifestDomain struct {
	ID     string `json:"id"`
	String string `json:"string"`
}

func genManifest(f Files) error {
	var crypto, api []manifestFile
	paths := make([]string, 0, len(f))
	for p := range f {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		e := manifestFile{SHA256: sum(f[p])}
		switch {
		case filepath.Dir(p) == APIDir:
			e.Path = filepath.Base(p)
			api = append(api, e)
		default:
			rel, _ := filepath.Rel(CryptoDir, p)
			e.Path = filepath.ToSlash(rel)
			crypto = append(crypto, e)
		}
	}
	var domains []manifestDomain
	for _, d := range registry() {
		domains = append(domains, manifestDomain{d.ID, d.String})
	}
	return f.json(CryptoDir+"/manifest.json", struct {
		Note       string           `json:"note"`
		Spec       string           `json:"spec"`
		Regenerate string           `json:"regenerate"`
		Domains    []manifestDomain `json:"domains"`
		Files      []manifestFile   `json:"files"`
		APIFiles   []manifestFile   `json:"api_v1_files"`
	}{
		Note: "Written by Go (WS-2) from fixed inputs; Swift reads these files and never regenerates them. " +
			"Every file is listed with its SHA-256; Go's TestCommittedVectorsAreCurrent regenerates the tree " +
			"and requires it byte for byte. Binary values are lowercase hex. Key material here is synthetic, " +
			"from the anchor inputs of spec 01 §15.5 or patterned seeds named in each file.",
		Spec: specRef, Regenerate: regen, Domains: domains, Files: crypto, APIFiles: api,
	})
}

// Write writes every file under root, creating directories, and removes
// nothing.
func Write(root string, f Files) error {
	for p, b := range f {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(full, b, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// stream is a deterministic byte stream: SHA-256 in counter mode over a label.
// It feeds P-256 signing (so the sample signatures are reproducible here) and
// any filler that must be "random-looking" yet byte-stable.
type stream struct {
	label string
	n     uint64
	buf   []byte
}

func newStream(label string) *stream { return &stream{label: label} }

func (s *stream) Read(p []byte) (int, error) {
	for i := range p {
		if len(s.buf) == 0 {
			h := sha256.Sum256([]byte(fmt.Sprintf("%s|%d", s.label, s.n)))
			s.n++
			s.buf = h[:]
		}
		p[i] = s.buf[0]
		s.buf = s.buf[1:]
	}
	return len(p), nil
}

func (s *stream) bytes(n int) []byte {
	b := make([]byte, n)
	_, _ = io.ReadFull(s, b)
	return b
}
