package auth

import (
	"crypto/sha256"
	"encoding/base32"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// mintCode mints a printed CLI invite and returns its code.
func mintCode(t *testing.T, pool *pgxpool.Pool, note string) string {
	t.Helper()
	code, err := MintInvite(bgctx, pool, MintOptions{Note: note, Now: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	return code
}

// mustMint is a ready signup for a passkey registration: a printed invite and a
// proven signup ceremony on a fresh address, written directly (the passkey
// tests need no server keys). It returns the signup id.
func mustMint(t *testing.T, pool *pgxpool.Pool, note string) string {
	t.Helper()
	code := mintCode(t, pool, note)
	id := uuid.NewString()
	now := time.Now().UTC()
	if _, err := pool.Exec(bgctx,
		`INSERT INTO signup_ceremonies (id, user_id, invite_code_hash, email_norm, email_tag, display_name,
		   email_proven, signup_nonce, created_at, expires_at)
		 VALUES ($1, gen_random_uuid(), $2, $3, $4, 'Test User', true, $5, $6, $7)`,
		id, InviteCodeHash(code), "u-"+uuid.NewString()+"@example.test", authtest.RandBytesTB(t, 32),
		authtest.RandBytesTB(t, 32), now, now.Add(SignupTTL)); err != nil {
		t.Fatal(err)
	}
	return id
}

func countUsers(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM users`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestMintedInviteIsNeverStoredInTheClear(t *testing.T) {
	pool := pgtest.New(t)
	code := mintCode(t, pool, "for maya")
	var (
		hash  []byte
		state string
	)
	if err := pool.QueryRow(bgctx, `SELECT code_hash, state FROM invite_codes`).Scan(&hash, &state); err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256([]byte(code))
	if string(hash) != string(want[:]) || state != "active" {
		t.Fatalf("stored %x (%s), want SHA-256 of the code and active", hash, state)
	}
}

func TestInviteCodeNormalizationIsForgiving(t *testing.T) {
	code := "ABCDEFGHIJKLMNOPQRSTUVWX"
	for _, in := range []string{"abcd-efgh-ijkl-mnop-qrst-uvwx", " ABCD EFGH\tIJKL\nMNOP_QRST-UVWX "} {
		if NormalizeInviteCode(in) != code {
			t.Fatalf("NormalizeInviteCode(%q) = %q", in, NormalizeInviteCode(in))
		}
	}
	if InviteCodeHash(" - ") != nil {
		t.Fatal("a code that normalizes to nothing hashes to something")
	}
}

// A review invite is unaddressed and CLI-only (07 §2.5's CHECK).
func TestAReviewInviteCarriesNoAddress(t *testing.T) {
	pool := pgtest.New(t)
	if _, err := MintInvite(bgctx, pool, MintOptions{Review: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := MintInvite(bgctx, pool, MintOptions{Review: true, EmailTag: authtest.RandBytesTB(t, 32)}); err == nil {
		t.Fatal("an addressed review invite was accepted")
	}
}

// ---------------------------------------------------------------------------
// Entropy: the one property the whole gate rests on
// ---------------------------------------------------------------------------

// A minted code is 24 characters of RFC 4648 base32 carrying 120 bits, and
// nothing about it is predictable from another one.
//
// This exists because two mutations survived the entire package before it did:
// `inviteCodeBytes = 2` (a SIXTEEN-BIT invite code) and codes minted from an
// incrementing counter rather than crypto/rand, whose first code on a fresh
// deployment is "AEAAAAAAAAAAAAAAAAAAAAAA". Both are catastrophic and both were
// invisible, because the properties the suite checked were distinctness (a
// counter is perfectly distinct) and that the digest is what gets stored (a
// digest of a guessable input is a guessable credential). Unguessability was
// asserted only in a comment, on the same line that would have to change to
// break it.
//
// It matters more here than in most places: `403 not_invited` is a perfect
// oracle. A guesser learns, on every attempt, whether the code they tried
// exists — so entropy is the only thing between this beta and open sign-up.
//
// Every code below is minted through MintInvite, the production entry point, so
// there is no seam between what is measured and what an operator runs.
// The randomness comes from crypto/rand, measured against invite.go's syntax
// tree rather than against its output.
//
// This is the half of unguessability a statistical test CANNOT see.
// TestMintedInviteCodesAreUnguessable samples 256 codes from one process, and
// `math/rand.New(rand.NewSource(1))` passes every statistic it computes —
// uniform per position, pairwise independent, all distinct — while producing
// the SAME 256 codes on every deployment that ever runs the binary. The
// property that fails there is not the distribution, it is the seed, and the
// only place the seed is visible is the import.
//
// So: crypto/rand imported, math/rand not imported at all (in either version),
// and MintInvite actually calling rand.Read rather than importing the good
// package and using something else.
func TestTheInviteCodeSourceIsCryptoRand(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "../invites/invites.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}

	imports := map[string]bool{}
	for _, spec := range file.Imports {
		path, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			t.Fatal(err)
		}
		if spec.Name != nil && spec.Name.Name != "rand" && path == "crypto/rand" {
			t.Fatalf("crypto/rand is imported as %q; this test reads call sites by the name "+
				"`rand`, so rename it back or teach this test the alias", spec.Name.Name)
		}
		imports[path] = true
	}
	if !imports["crypto/rand"] {
		t.Fatal("invite.go does not import crypto/rand: an invite code minted from anything " +
			"else is reproducible by whoever knows the seed, and 403 not_invited tells them " +
			"when they have it right")
	}
	for _, bad := range []string{"math/rand", "math/rand/v2"} {
		if imports[bad] {
			t.Fatalf("invite.go imports %s", bad)
		}
	}

	var mint *ast.FuncDecl
	for _, d := range file.Decls {
		if fn, ok := d.(*ast.FuncDecl); ok && fn.Name.Name == "NewCode" {
			mint = fn
		}
	}
	if mint == nil {
		t.Fatal("invites.go declares no NewCode")
	}
	found := false
	ast.Inspect(mint.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "rand" && sel.Sel.Name == "Read" {
			found = true
		}
		return true
	})
	if !found {
		t.Fatal("NewCode never calls rand.Read: crypto/rand is imported and unused for the " +
			"one value that has to be unpredictable")
	}
}

func TestMintedInviteCodesAreUnguessable(t *testing.T) {
	pool := pgtest.New(t)

	const (
		sample = 256
		// A base32 character is 5 bits; the alphabet is 32 symbols.
		wantChars = 24
		wantBytes = 15
		wantBits  = 120
	)

	codes := make([]string, 0, sample)
	decoded := make([][]byte, 0, sample)
	for i := 0; i < sample; i++ {
		codes = append(codes, mintCode(t, pool, ""))
	}

	// --- Shape. A short code fails HERE, before any statistic: 2 bytes encode
	// to 4 characters, and no amount of sampling is needed to see that.
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
	for _, code := range codes {
		if len(code) != wantChars {
			t.Fatalf("code %q is %d characters, want %d: %d bits of entropy, not %d",
				code, len(code), wantChars, len(code)*5, wantBits)
		}
		for _, r := range code {
			if !strings.ContainsRune(alphabet, r) {
				t.Fatalf("code %q contains %q, which is not in the base32 alphabet %q "+
					"— the alphabet is narrower than it claims, or the encoding changed",
					code, r, alphabet)
			}
		}
		// Mint and redemption must agree on what "the same code" is, and a
		// freshly minted code is already in normal form.
		if NormalizeInviteCode(code) != code {
			t.Fatalf("NormalizeInviteCode(%q) = %q: a minted code is not in the form it is "+
				"redeemed in", code, NormalizeInviteCode(code))
		}
		raw, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(code)
		if err != nil {
			t.Fatalf("minted code %q does not decode as base32: %v", code, err)
		}
		if len(raw)*8 != wantBits {
			t.Fatalf("code %q carries %d bits, want %d", code, len(raw)*8, wantBits)
		}
		decoded = append(decoded, raw)
	}

	// --- Every position varies. This is the assertion a counter fails, and it
	// is deliberately not "the codes differ" or "no shared prefix": a
	// little-endian counter varies its LEADING bytes fastest, so 256 counter
	// codes have 256 distinct values and 256 distinct 4-character prefixes.
	// What a counter cannot do is vary byte 14.
	//
	// With crypto/rand, 256 draws from 256 values give ~162 distinct on
	// average; the floor below is a quarter of that, and a frozen position
	// scores 1.
	for i := 0; i < wantBytes; i++ {
		seen := map[byte]bool{}
		for _, raw := range decoded {
			seen[raw[i]] = true
		}
		if len(seen) < 64 {
			t.Fatalf("byte %d of the code took only %d distinct values across %d mints: that "+
				"byte is not random, so the code is far short of %d bits",
				i, len(seen), sample, wantBits)
		}
	}
	// The same measurement on the encoded form, which is what a low-entropy
	// ALPHABET would show up in: 32 symbols per position, ~32 expected.
	for i := 0; i < wantChars; i++ {
		seen := map[byte]bool{}
		for _, code := range codes {
			seen[code[i]] = true
		}
		if len(seen) < 16 {
			t.Fatalf("character %d took only %d distinct values across %d mints; the alphabet "+
				"at that position is %d symbols wide, not 32", i, len(seen), sample, len(seen))
		}
	}

	// --- No code is close to any other. Sequential minting is exactly this
	// failure: consecutive counter values share 13 or 14 of their 15 bytes.
	//
	// For crypto/rand the chance that a given pair agrees in 7 or more of 15
	// byte positions is C(15,7)·256⁻⁷ ≈ 9e-14; across the 32,640 pairs here
	// that is ~3e-9, so this is a bound, not a flake.
	const maxShared = 6
	for i := 0; i < len(decoded); i++ {
		for j := i + 1; j < len(decoded); j++ {
			shared := 0
			for k := 0; k < wantBytes; k++ {
				if decoded[i][k] == decoded[j][k] {
					shared++
				}
			}
			if shared > maxShared {
				t.Fatalf("codes %d and %d share %d of %d bytes (%q vs %q): these codes are "+
					"related to each other, which is what a counter or a seeded PRNG looks like",
					i, j, shared, wantBytes, codes[i], codes[j])
			}
		}
	}

	// --- And, as a corollary rather than the headline, they are all distinct.
	seen := map[string]bool{}
	for _, code := range codes {
		if seen[code] {
			t.Fatalf("minted %q twice in %d mints", code, sample)
		}
		seen[code] = true
	}
}
