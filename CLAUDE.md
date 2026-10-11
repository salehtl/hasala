# Hasala

Hasala (حصّالة) is a private, iOS-native budgeting app for the UAE. It is the
public successor to ledgerd (ledger 2.0). Today it ships to a small TestFlight
beta; every deployment is **QA** until a production VPS exists.

## Layout

| Path | What it is |
| --- | --- |
| `server/` | The Go backend `hasalad` (module `github.com/salehtl/hasala/server`), forked from ledgerd at `4b01e36`. Postgres. |
| `server/oracle/` | A separate Go module: ledgerd's frozen v1 reference packages (`v1ref`), the corpus reader and the corpus gates. Test-time oracle only; the server's build graph cannot reach it. |
| `ios/` | The native SwiftUI app and its Swift packages (`HasalaCore` = the ported client core). Not in this tree yet. |
| `conformance/` | Shared fixtures. Go, the TypeScript reference and Swift must all produce byte-identical output against them. |
| `reference/ledgerd-client/` | ledgerd's TypeScript client core. **Reference and fixture oracle only** — the Swift port must match it. Not shipped. |
| `reference/ledgerd-pwa/` | ledgerd's React PWA. Reference for product logic (`src/lib/`) only. Not shipped. |
| `design/` | Logo and exported assets. Not in this tree yet. The UI source of truth is a private Paper design file. |
| `infra/qa/` | (Planned) generic deployment notes for the QA host. Host names, addresses, accounts and credentials never go here. |
| `docs/` | Not in this tree yet: Hasala's architecture and decisions will live here. ledgerd's design history (plans, specs, task reports, reviews) is archived privately and is not part of this repository; code comments that cite it say "ledgerd design archive". |

## Build and test

Every tool comes from `flake.nix` (nixpkgs `nixos-26.05`, pinned by
`flake.lock`); the same devShell serves the QA host (x86_64-linux) and the Mac
(aarch64-darwin). Run `direnv allow` once, then prefix commands with
`direnv exec .` in non-interactive shells. The one exception to 26.05 is Go,
taken from `nixos-unstable` (1.27.2) because 26.05's 1.26.8 still has reachable
standard-library advisories; gopls, govulncheck and golangci-lint are rebuilt
with it. `server/go.mod`'s `toolchain` line is that security floor, and
`govulncheck ./...` in `server/` should report nothing reachable.

- `scripts/check.sh` is the gate: real-mail fence, toolchain floor, the
  hasalad fences (`server/cmd/hasalad/fence_test.go`), `go vet` and `go test`
  in `server/` and then `server/oracle/` against one throwaway Postgres (unix
  socket only), the reference client's typecheck and `bun test`, and the
  conformance suites. Once per checkout first:
  `(cd reference/ledgerd-client && bun install --frozen-lockfile)`.
- CI is `.github/workflows/ci.yml`, on every pull request and push to `main`,
  without the private fixtures. Jobs `gate` (`check.sh --fence-only` before
  anything else, then `nix flake check` and `scripts/check.sh` in the
  devShell), `vuln` (`govulncheck ./...` in `server/`, failing on anything
  reachable) and `secrets` (gitleaks over the full history). Keep those job
  names: required status checks match them by name. `.gitleaks.toml` allowlists
  known public test vectors only, each scoped to its rule, its files and its
  exact value; never widen it to pass a real secret.
- Real bank mail is **not** in this repository. The real-mail conformance cases
  and the signed `.eml` fixtures live in the private `salehtl/hasala-fixtures`
  repo under the same paths; set `HASALA_PRIVATE_FIXTURES` to an absolute path
  of a checkout to run the tests that read them (they skip, by name, without
  it, and `scripts/check.sh` says how many ran or were skipped). The checkout
  must match `private-fixtures.lock`; after changing the private repo, refresh it
  with `scripts/private-fixtures-lock.sh write` and commit both. Never commit a
  real message, account or card number (masked or not), name, amount, date or
  reference here — use synthetic stand-ins. No real transaction amount or date
  is committed anywhere in this tree, `server/oracle/v1ref` included.
  `scripts/check.sh`'s first step (the real-mail fence) refuses the private
  paths; CI runs it alone (`scripts/check.sh --fence-only`, no fixtures and no
  toolchain needed) on every push and pull request before anything else.
- `nix build .#hasalad` builds `cmd/hasalad`, `nix flake check` builds it and
  checks formatting, `nix fmt` formats Nix and Go (never `server/oracle/v1ref`,
  which is byte-frozen).
- `hasalad <mode>`: `serve`, `migrate`, `verify`, `purge-user`, `invite`,
  `console` (a stub until the console is built) and `version`; configuration
  is `HASALA_*` environment variables over an optional TOML file
  (`server/config.example.toml`). Two Postgres roles: `hasala_migrate` owns the
  schema and is the only role `hasalad migrate` runs as; `hasala_runtime`
  serves, and every other mode refuses to start as the owner, as a superuser
  or behind the embedded migrations. Tests boot their own throwaway cluster
  (`internal/pgtest`; `HASALA_TEST_POSTGRES_URL` reuses one).

## Decisions (2026-10-11)

- **Native Swift client**, full parity with the Paper design. The TS client core
  is **ported** to Swift (no JavaScriptCore), proven by the conformance fixtures.
- **The server is blind.** The phone encrypts every op before upload; the server
  checks framing, position and the hash chain, and **refuses plaintext**. No
  feature may need the server to read a transaction, amount, merchant or email.
- **Transactions come from Gmail, read on the phone.** OAuth tokens live in the
  device Keychain. The server only relays Gmail Pub/Sub change notices
  (`emailAddress` + `historyId`) into content-free APNs wakes. Raw bank email
  never enters the op log — store the Gmail message id and parsed fields.
  Email forwarding / SMTP ingest is retired for this iteration.
- **Categorization is on device**: user rules → shipped UAE merchant dictionary
  → Apple Foundation Models (Latin-script merchants only; it cannot read Arabic)
  → review queue.
- **Auth**: passkeys (RP ID `hasala.app`) + 12-word recovery phrase; invite
  codes; WebAuthn step-up for every auth/key/mailbox management operation.
- **Outbound mail**: Cloudflare Email Service.
- **Hosting (QA)**: the QA host behind Cloudflare Tunnel; hasalad listens on
  loopback only and has no TLS code.
- Bundle ID `app.hasala.ios`. Google OAuth consent: production, unverified
  (≤100 users).

## Core principles (inherited from ledgerd — do not violate)

- The op log is append-only and nothing validates its payload server-side. Op
  authoring is the highest-risk code in the repo.
- Money is integer minor units (fils), never a float.
- Push payloads are content-free.
- Nothing is silently dropped: unparsed or unverified mail goes to review.
- Secrets come from the environment / Keychain, never config files or the bundle.
- Two Postgres roles: `*_migrate` owns the schema, `*_runtime` serves.

## Design source of truth

The UI source of truth is a private Paper design file. It is not linked from
this repository.

## Security

Security reviews are kept private until their findings are closed, and every
finding must be closed before a non-developer tester installs a build. Report
vulnerabilities to security@hasala.app, not in a public issue.

## Licence

Source-available under the Functional Source License, Version 1.1, ALv2 Future
License (`LICENSE.md`); each version becomes Apache-2.0 two years after it is
made available. The name and marks are not licensed (`TRADEMARKS.md`). Outside
contributions are not accepted during the beta (`CONTRIBUTING.md`).
Third-party notices are in `NOTICE` and `LICENSES/`.
