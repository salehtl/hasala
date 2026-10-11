package main

// The build-graph and source fences of spec 02 §4.4. They are what keeps
// hasalad blind: the oracle packages, the test sealers and every retired
// ledgerd capability stay out of the binary, and no code reachable from it
// can encrypt, decrypt or hold a review bypass.
//
// Two third-party edges are tolerated by name, and only those two (recorded
// as a deviation from fences 1 and 5 in WS-1's branch notes):
//
//   - github.com/jackc/pgx/v5/pgconn imports golang.org/x/text/secure/precis
//     (SASLprep for SCRAM). hasalad authenticates to Postgres by peer auth,
//     but the package is linked regardless.
//   - github.com/go-webauthn/x/revoke imports golang.org/x/crypto/ocsp (the
//     attestation metadata path of go-webauthn), so x/crypto stays in go.mod
//     as an `// indirect` requirement.
//
// No package of this module may import either, directly or through anything
// other than those two edges.

import (
	"bufio"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/api"
)

const module = "github.com/salehtl/hasala/server"

type listedPackage struct {
	ImportPath string
	Dir        string
	GoFiles    []string
	Imports    []string
	Standard   bool
}

// deps is `go list -deps -json ./cmd/hasalad`: every package linked into the
// binary, tests excluded.
func deps(t *testing.T) []listedPackage {
	t.Helper()
	if _, err := exec.LookPath("go"); err != nil {
		t.Fatalf("the fences need the go tool on PATH (run inside the devShell): %v", err)
	}
	cmd := exec.Command("go", "list", "-deps", "-json", module+"/cmd/hasalad")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("go list -deps: %v", err)
	}
	var pkgs []listedPackage
	dec := json.NewDecoder(strings.NewReader(string(out)))
	for dec.More() {
		var p listedPackage
		if err := dec.Decode(&p); err != nil {
			t.Fatal(err)
		}
		pkgs = append(pkgs, p)
	}
	if len(pkgs) < 20 {
		t.Fatalf("go list returned %d packages; the fences would be vacuous", len(pkgs))
	}
	return pkgs
}

func own(pkgs []listedPackage) []listedPackage {
	var out []listedPackage
	for _, p := range pkgs {
		if p.ImportPath == module || strings.HasPrefix(p.ImportPath, module+"/") {
			out = append(out, p)
		}
	}
	return out
}

func rel(importPath string) string { return strings.TrimPrefix(importPath, module+"/") }

// Fences 1, 5 and F7-1's import half.
func TestFenceTheBuildGraph(t *testing.T) {
	pkgs := deps(t)
	forbidden := []string{
		module + "/internal/authtest", module + "/internal/pgtest",
		module + "/internal/blob/blobtest", module + "/internal/oplog/opref",
		module + "/internal/oplog/oplogtest",
		module + "/internal/norm", module + "/internal/tmpl", module + "/internal/dict",
		module + "/oracle",
		module + "/internal/cryptoref",
		module + "/internal/console", module + "/internal/testflight",
		"github.com/emersion/",
	}
	for _, p := range pkgs {
		for _, f := range forbidden {
			if p.ImportPath == f || strings.HasPrefix(p.ImportPath, strings.TrimSuffix(f, "/")+"/") {
				t.Errorf("hasalad links %s (spec 02 §4.4)", p.ImportPath)
			}
		}
	}
	tolerated := map[string]string{
		"golang.org/x/text/":   "github.com/jackc/pgx/v5/pgconn",
		"golang.org/x/crypto/": "github.com/go-webauthn/x/revoke",
	}
	for _, p := range pkgs {
		for _, imp := range p.Imports {
			for prefix, only := range tolerated {
				if !strings.HasPrefix(imp, prefix) || strings.HasPrefix(p.ImportPath, prefix) {
					continue
				}
				if p.ImportPath != only {
					t.Errorf("%s imports %s; only %s may, and only until spec 02 §4.4's fence can be met",
						p.ImportPath, imp, only)
				}
			}
		}
	}
}

// Fences 2 and 5's go.mod halves.
func TestFenceGoMod(t *testing.T) {
	f, err := os.Open("../../go.mod")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.Contains(line, module+"/oracle") {
			t.Errorf("server/go.mod requires the oracle module: %q", line)
		}
		if strings.HasPrefix(line, "golang.org/x/crypto ") && !strings.HasSuffix(line, "// indirect") {
			t.Errorf("server/go.mod requires golang.org/x/crypto directly: %q", line)
		}
		for _, gone := range []string{"emersion/go-smtp", "emersion/go-msgauth", "webpush-go", "xuri/excelize"} {
			if strings.Contains(line, gone) {
				t.Errorf("server/go.mod still requires a retired module: %q", line)
			}
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
}

// sourceFile is one parsed non-test file of a package reachable from hasalad.
type sourceFile struct {
	pkg, path string
	file      *ast.File
	imports   map[string]string // local name -> import path
}

func reachableSources(t *testing.T) []sourceFile {
	t.Helper()
	var out []sourceFile
	fset := token.NewFileSet()
	for _, p := range own(deps(t)) {
		for _, name := range p.GoFiles {
			path := filepath.Join(p.Dir, name)
			f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
			if err != nil {
				t.Fatal(err)
			}
			imps := map[string]string{}
			for _, is := range f.Imports {
				ip, _ := strconv.Unquote(is.Path.Value)
				local := ip[strings.LastIndex(ip, "/")+1:]
				if is.Name != nil {
					local = is.Name.Name
				}
				imps[local] = ip
			}
			out = append(out, sourceFile{pkg: rel(p.ImportPath), path: path, file: f, imports: imps})
		}
	}
	return out
}

// Fences 3 and 6, and F7's literal halves. Comments are not scanned.
func TestFenceTheSource(t *testing.T) {
	files := reachableSources(t)
	banned := []string{
		"gmail.googleapis.com", "oauth2.googleapis.com/token", "authentication-results",
		"/.well-known/", "smtp", "vapid", "x-forwarded-for", "true-client-ip",
	}
	onlyIn := map[string]string{
		"api.cloudflare.com":            "internal/mail",
		"api.appstoreconnect.apple.com": "internal/testflight",
		"challenges.cloudflare.com":     "internal/turnstile",
	}
	bypass := regexp.MustCompile(`(?i)(dev|demo|review)[-_]?(auth|login|bypass)`)
	reviewAllowed := func(pkg, path string) bool {
		base := filepath.Base(path)
		return pkg == "internal/accounts" || pkg == "internal/console" || pkg == "internal/invites" ||
			(pkg == "internal/auth" && base == "signup.go") || (pkg == "internal/api" && base == "account.go")
	}
	scanned := 0
	for _, sf := range files {
		scanned++
		for _, is := range sf.file.Imports {
			if ip, _ := strconv.Unquote(is.Path.Value); ip == "crypto/pbkdf2" && sf.pkg != "internal/authkeys" {
				t.Errorf("%s imports crypto/pbkdf2 outside internal/authkeys", sf.path)
			}
		}
		ast.Inspect(sf.file, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.BasicLit:
				if x.Kind != token.STRING {
					return true
				}
				s, err := strconv.Unquote(x.Value)
				if err != nil {
					s = x.Value
				}
				lower := strings.ToLower(s)
				for _, b := range banned {
					if strings.Contains(lower, b) {
						t.Errorf("%s: string literal contains %q (spec 02 §4.4 fence 3)", sf.path, b)
					}
				}
				for lit, pkg := range onlyIn {
					if strings.Contains(lower, lit) && sf.pkg != pkg {
						t.Errorf("%s: %q outside %s", sf.path, lit, pkg)
					}
				}
				if bypass.MatchString(s) {
					t.Errorf("%s: string literal %q looks like a review or dev bypass (fence 6)", sf.path, s)
				}
				if (strings.Contains(lower, "review_account") || strings.Contains(lower, "invite_codes.review")) &&
					!reviewAllowed(sf.pkg, sf.path) {
					t.Errorf("%s: reads the review flag (fence 6)", sf.path)
				}
			case *ast.Ident:
				if x.Name == "PlaintextSealer" {
					t.Errorf("%s: identifier PlaintextSealer (fence 3)", sf.path)
				}
				if bypass.MatchString(x.Name) {
					t.Errorf("%s: identifier %s looks like a review or dev bypass (fence 6)", sf.path, x.Name)
				}
				if x.Name == "ReviewAccount" && !reviewAllowed(sf.pkg, sf.path) {
					t.Errorf("%s: identifier ReviewAccount (fence 6)", sf.path)
				}
			case *ast.CallExpr:
				sel, ok := x.Fun.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				id, ok := sel.X.(*ast.Ident)
				if !ok {
					return true
				}
				switch call := sf.imports[id.Name] + "." + sel.Sel.Name; call {
				case "crypto/aes.NewCipher", "crypto/cipher.NewGCM":
					t.Errorf("%s: calls %s; the server never encrypts or decrypts user data (fence 3)", sf.path, call)
				case "crypto/ecdsa.Sign", "crypto/ecdsa.SignASN1":
					t.Errorf("%s: calls %s (fence 3)", sf.path, call)
				}
			}
			return true
		})
	}
	if scanned < 20 {
		t.Fatalf("scanned %d files; the fence would be vacuous", scanned)
	}
}

// Fence 4: the corpus database is the oracle's alone.
func TestFenceCorpusDatabase(t *testing.T) {
	name := "HASALA_" + "CORPUS_DB"
	root := "../.."
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && path == filepath.Join(root, "oracle") {
			return filepath.SkipDir
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(b), name) {
			t.Errorf("%s names %s outside server/oracle (fence 4)", path, name)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// F7-1: serve answers 404 for console paths. Nothing here touches the
// database: an unknown path never reaches a handler.
func TestFenceServeHasNoConsole(t *testing.T) {
	h := (&api.Server{}).Handler()
	for _, path := range []string{"/console", "/console/", "/console/login", "/admin", "/admin/", "/ui/", "/"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code != http.StatusNotFound {
			t.Errorf("serve answered %d for %s, want 404", w.Code, path)
		}
	}
}

// Spec 01 §12.2's fences and AT-X4: no production file computes K_blob, K_1,
// K_pv or a wrap key (the server holds no data key and cannot open the phrase
// box), so the domain strings those derivations use appear in hasalad only as
// keyproto's registry constants and are referenced from nowhere else; and no
// retired ledgerd domain string appears at all.
func TestFenceNoDataKeyDerivationAndNoRetiredDomain(t *testing.T) {
	dataKey := map[string]bool{
		"DomainRecoveryKey": true, "DomainWrapRecovery": true, "DomainWrapPRF": true, "DomainWrap": true,
		"DomainPRFSaltUnlock": true, "DomainAMKCommitment": true, "DomainEpochKey": true, "DomainBlobKey": true,
		"DomainBlob": true, "DomainKeyringKey": true, "DomainKeyring": true, "DomainPassword": true,
		"DomainPhraseBoxKey": true, "DomainPhraseBox": true,
	}
	dataKeyLiterals := []string{
		"hasala/v1/recovery-key", "hasala/v1/wrap", "hasala/v1/prf-salt/unlock", "hasala/v1/amk-commitment",
		"hasala/v1/epoch-key", "hasala/v1/blob", "hasala/v1/keyring", "hasala/v1/password", "hasala/v1/phrase-box",
	}
	retired := []string{
		"ledger-v2-writer-registration", "ledger-v2-writer-revocation", "ledger/v2 account-delete",
		"ledger-v2-account-keys", "ledger-v2-prf-wrap-v1", "ledger-v2-prf-unlock-v1", "ledger-v2-ingest-key",
		"ledger-v2-device-comparison", "ledger-phase2-encv2", "ledger/dict/key-epoch/v1", "hasala-stepup-v1",
	}
	// Tolerated by name until account deletion moves to step-up account.delete
	// with spec 01's DeletionMessage (D16): purge still verifies ledgerd's
	// deletion message, under ledgerd's domain, so that one domain never names
	// two formats.
	tolerated := map[string]string{"ledger/v2 account-delete": "internal/purge"}
	for _, sf := range reachableSources(t) {
		isRegistry := sf.pkg == "internal/keyproto" && filepath.Base(sf.path) == "domains.go"
		ast.Inspect(sf.file, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.SelectorExpr:
				if id, ok := x.X.(*ast.Ident); ok && sf.imports[id.Name] == module+"/internal/keyproto" && dataKey[x.Sel.Name] {
					t.Errorf("%s references keyproto.%s: hasalad derives no data or wrap key (spec 01 §12.2)", sf.path, x.Sel.Name)
				}
			case *ast.BasicLit:
				if x.Kind != token.STRING {
					return true
				}
				s, err := strconv.Unquote(x.Value)
				if err != nil {
					s = x.Value
				}
				for _, r := range retired {
					if strings.Contains(s, r) && tolerated[r] != sf.pkg {
						t.Errorf("%s: retired domain string %q (spec 01 §3, AT-X4)", sf.path, r)
					}
				}
				if !isRegistry {
					for _, d := range dataKeyLiterals {
						if strings.HasPrefix(s, d) {
							t.Errorf("%s: data-key domain literal %q outside keyproto's registry", sf.path, s)
						}
					}
				}
			}
			return true
		})
	}
}
