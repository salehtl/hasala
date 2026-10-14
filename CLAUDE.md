# Hasala

Hasala (حصّالة) is a private, iOS-native budgeting app for the UAE. It is the
public successor to ledgerd (ledger 2.0). Today it ships to a small TestFlight
beta; every deployment is **QA** until a production VPS exists.

## Layout

| Path | What it is |
| --- | --- |
| `server/` | The Go backend `hasalad` (module `github.com/salehtl/hasala/server`), forked from ledgerd at `4b01e36`. Postgres. |
| `server/oracle/` | A separate Go module: ledgerd's frozen v1 reference packages (`v1ref`), the corpus reader and the corpus gates. Test-time oracle only; the server's build graph cannot reach it. |
| `ios/` | The native SwiftUI app and its Swift packages (`HasalaCore` = the ported client core; `HasalaKit` = the design system, read models and the Maya mock). |
| `conformance/` | Shared fixtures. Go, the TypeScript reference and Swift must all produce byte-identical output against them. |
| `reference/ledgerd-client/` | ledgerd's TypeScript client core. **Reference and fixture oracle only** — the Swift port must match it. Not shipped. |
| `reference/ledgerd-pwa/` | ledgerd's React PWA. Reference for product logic (`src/lib/`) only. Not shipped. |
| `web/` | The hasala.app website: Astro + Bun, static output. See "Website" below. |
| `design/` | Logo and exported assets. Not in this tree yet. The UI source of truth is a private Paper design file. |
| `infra/qa/` | The QA deployment as code: `nix/module.nix` is `nixosModules.hasala` (`services.hasala`: Hasala's own PostgreSQL 17 on a unix socket, migrations, `hasalad serve` and `hasalad console` on loopback, the tunnel, encrypted backups), `cloudflared/` the ingress golden file, lint and fixtures, `nix/tests/` the eval and VM checks, `HOST-PR.md` the host-side change (placeholders only). Host names, addresses, accounts and credentials never go here. |
| `docs/` | `docs/legal/` holds the privacy policy, terms, security and support pages that the website renders (`status: "final"`; a page that still has an `[[OWNER: ...]]` note must go back to `status: "draft"`). Hasala's architecture and decisions will live in `docs/` too; not in this tree yet. ledgerd's design history (plans, specs, task reports, reviews) is archived privately and is not part of this repository; code comments that cite it say "ledgerd design archive". |

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
- CI is `.github/workflows/ci.yml`, on every pull request and push to `main`
  (and by hand, `workflow_dispatch`), without the private fixtures. Jobs
  `gate` (`check.sh --fence-only` before anything else, then
  `nix flake check --no-build`, a build of every check except `qa-vm`, and
  `scripts/check.sh` in the devShell), `vuln`
  (`govulncheck ./...` in `server/` and `server/oracle/`, failing on anything
  reachable) and `secrets` (the real-mail fence and the HasalaCore lints
  `ios/scripts/check-imports.sh --no-manifest` and `check-forbidden.sh`, then
  gitleaks over the full history) are the required checks. Keep those job
  names: required status checks match them by name. `swift` (HasalaCore on a
  Mac), `ios` and `ios-ui` (the app on a Mac, below), `web` (the website, see
  "Website") and `nixos-vm` (builds `checks.x86_64-linux.qa-vm` with KVM) are
  not required.
- CI is path-aware on pull requests and fails closed. Its first job,
  `changes`, lists the pull request's changed paths (`git diff -z`, so any
  file name matches as written), and each of `gate`/`vuln`, `swift`, `web`
  and `nixos-vm` is skipped only when every changed path is on that job's
  list of paths it does not read; any other path, including one nobody
  anticipated (a new top-level directory, `go.work`, `.gitattributes`), runs
  it. No job reads `LICENSES/`, `design/`, root `*.md`, `NOTICE` or
  `private-fixtures.lock`. `gate` and `vuln` also skip `docs/`, `web/` and
  `ios/` (except any `*.go`, `*.nix`, `go.mod`, `go.sum`, `go.work`,
  `go.work.sum`), so `infra/` runs them; `swift` reads only `ios/` and
  `conformance/`; `web` reads only `web/`, `docs/legal/` and the flake;
  `nixos-vm` reads only `infra/`, `server/` and the flake. `.github/` runs
  everything, and `secrets` always runs. Jobs are skipped by a
  job-level `if:` (a skipped required check counts as passing), never by a
  workflow-level `paths:` filter (that leaves required checks pending
  forever), and unless `changes` succeeded every job runs. A push to `main` or
  a manual run runs every job. When a job starts reading a path on its
  inert list, take it off that list in `changes`.
- `.github/workflows/vuln-weekly.yml` runs the same govulncheck on `main`
  every Monday (job `vuln-weekly`, not required), because Go advisories land
  without commits; it is a separate workflow so it never records checks on
  `main`'s head under the required names.
- `.gitleaks.toml` allowlists known public test vectors only, each scoped to
  its rule, its files and its exact value; never widen it to pass a real
  secret.
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
  toolchain needed) in `secrets` on every push and pull request, and in `gate`
  before anything else.
- The iOS app (`ios/`, macOS only) builds with Xcode 27 from the system. The
  `Hasala.xcodeproj` is generated from `ios/project.yml` by XcodeGen **2.46.0**
  (`ios/scripts/generate-project.sh`; `--check` verifies the committed project)
  and committed. The flake pins that XcodeGen (`nix build .#xcodegen`, on PATH in
  the darwin devShell); nixpkgs' own 2.44.1 writes a project without resources.
  Tests: `swift test --package-path ios/HasalaKit` (design tokens, money
  formatting, the Maya mock, text contrast) and `xcodebuild test -project
  ios/Hasala.xcodeproj -scheme Hasala -destination 'platform=iOS Simulator,name=iPhone 17'`
  (unit tests, and UI tests that run the accessibility audit at the default
  and `.accessibility3` text sizes). Design tokens are generated from
  `design/tokens/paper-tokens.json` by `swift ios/tools/tokens/generate.swift`
  (`--check` in CI). Debug builds run the synthetic Maya scenario
  (`-HasalaScenario maya|mayaHidden|mayaSample`); Release builds do not link HasalaMocks
  (`ios/Config/Shared.xcconfig` excludes it from every configuration but Debug).
  Release shows only what works (`BuildSurface`: no placeholder screens or
  controls without a screen) and only the account actions in
  `AccountSession.capabilities`; `-HasalaReleaseSurface` gives a Debug run the
  same surface, and `ios/scripts/test-release-surface.sh <simulator udid>` runs
  `ReleaseSurfaceTests` on a Release-configuration simulator build that links the
  mock. `ios/scripts/archive.sh` (below) runs a gate before it builds anything
  (exit 13): no `IntegrationStub` left under `ios/`, then
  `ios/scripts/privacy-lint.sh` (required-reason API use against the privacy
  manifest).
  `ios/scripts/check-bundle.sh <.app|.xcarchive|.ipa>` checks what a build carries:
  no test data, no resource over 5 MB but fonts and the merchant dictionary, and
  the sample seed equal to `ios/scripts/golden/maya-v1.sha256`, which must equal
  `SampleManifest.sha256` (update both when the seed is regenerated).
  inspect-ipa.sh runs it as I6b; its I9 refuses third-party crypto symbols (the
  export-compliance guard, `docs/decisions/export-compliance.md`).
  `ios/scripts/archive.sh` archives and exports a signed .ipa on the owner's Mac
  and `ios/scripts/upload.sh` uploads it; both read the App Store Connect key
  from `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` only. archive.sh inspects
  the export with `ios/scripts/inspect-ipa.sh`, whose `summary.txt` ends in
  `PASS <n>/<n> sha256=<the .ipa's>` only when every check passed; upload.sh
  uploads nothing else. inspect-ipa.sh's content checks (secrets, dev hosts,
  mock data) search every file's bytes and every plist as XML; the dev-host
  search ignores case. They do not search text that a non-plist resource holds
  as UTF-16, or compressed resources (zip, gzip, LZFSE, compressed data in
  `Assets.car`), so the endpoint guard is the exact `HasalaAPIBaseURL` check,
  not the dev-host search. `ios/scripts/tests/run.sh` runs the release-script tests
  offline (stub xcodebuild and altool, fake keys, synthetic .ipa files), and
  `ios/scripts/tests/devshell_test.sh` runs them again inside the devShell, where
  GNU coreutils come first on PATH. CI job `ios` builds and tests unsigned in
  the simulator and also runs `ios/scripts/tests/run.sh`,
  `ios/scripts/tests/devshell_test.sh` and shellcheck over `ios/scripts`; job
  `ios-ui` runs the two longest UI test classes (`CoreScreensTests`,
  `SmokeTests`) on a second runner, and `ios` skips exactly those two
  (`ios/scripts/ci-simulator-test.sh`). Neither is a required check.
- `nix build .#hasalad` builds `cmd/hasalad`, `nix flake check` builds it and
  checks formatting, `nix fmt` formats Nix and Go (never `server/oracle/v1ref`,
  which is byte-frozen). The infra checks: `ingress-lint` (both systems; the
  module's rendered tunnel config against `infra/qa/cloudflared/config.golden.yml`
  plus `lint.sh`), and on x86_64-linux `module-eval` (every module assertion
  fires on its misuse) and `qa-vm` (needs KVM). On a Mac,
  `nix flake check --no-build --all-systems` evaluates the Linux ones.
- `hasalad <mode>`: `serve`, `migrate`, `verify`, `purge-user`, `invite`
  (`mint [--review | --email]`, `list`, `revoke`), `waitlist`, `email test`,
  `console` (spec 07's operator console, minimal: waitlist approve, invites,
  email log) and `version`; configuration
  is `HASALA_*` environment variables over an optional TOML file
  (`server/config.example.toml`). Two Postgres roles: `hasala_migrate` owns the
  schema and is the only role `hasalad migrate` runs as; `hasala_runtime`
  serves, and every other mode refuses to start as the owner, as a superuser
  or behind the embedded migrations. Tests boot their own throwaway cluster
  (`internal/pgtest`; `HASALA_TEST_POSTGRES_URL` reuses one).

## Website

`web/` is the hasala.app marketing site and the public pages under it
(`/privacy`, `/terms`, `/security` and `/support` are rendered from
`docs/legal/*.md`): Astro, static output, Bun as the package manager, from the
same devShell. From `web/`:

- `bun install --frozen-lockfile` once, then `bun run dev` while editing.
- `bun run check` is `astro check`. `bun run build` writes `dist/` and then
  runs `scripts/check-dist.ts`, which fails the build if any inline script or
  style is not covered by the one CSP every page shares, if any element has a
  `style=""` attribute, if `/` loads more than 15 KB of JavaScript (gzip), or
  if a page whose address carries a code or a token could run Web Analytics
  (below).
  The CSP (`astro.config.mjs`) also admits Cloudflare Web Analytics, whose
  beacon Cloudflare injects at the edge (it is not in `dist/`); the privacy
  policy describes it. Nothing else third-party, except Turnstile in "api"
  mode. Web Analytics records paths, so it must never run on `/i`, `/i/*`,
  `/freeze` or `/waitlist/*`: `public/_headers` gives them a CSP header
  whose script-src and connect-src are the page's without Web Analytics
  (the build fills them in, `src/lib/csp-union.mjs`), `src/scripts/router.ts`
  always loads them in full, and the pages take their code or token out of
  the address bar. A new page that carries one needs the same: send no
  referrer (`referrer="no-referrer"` on `Base`) and add it to `_headers` and
  the router.
- `bun run preview` (Astro's preview server) or `bun scripts/serve-dist.ts`,
  which serves `dist/` on 127.0.0.1:4321 with the `_headers`, `_redirects`
  and trailing-slash handling of production, and gzip.
- `web/lighthouse/run.sh` runs Lighthouse CI on `/` (mobile and desktop)
  against that server. It needs Node and Chrome, so it runs in CI (job `web`),
  which keeps the reports as a workflow artifact; it asserts performance
  >= 0.9 and accessibility, best practices and SEO >= 0.95.
- PUBLIC_* settings (waitlist mode, API base, Turnstile site key) are in
  `web/.env.example`; they are public and baked into the build.
  `PUBLIC_WAITLIST_MODE` is `api` (the default: the invite form, which is
  also where people name a bank we don't read yet, posts to the API, the
  page says "Request sent", and the request appears on the waitlist in
  `hasalad console`) or `email` (a fallback while the API is down: it opens
  a pre-filled email to support@hasala.app, posts nothing and loads no
  Turnstile; without JavaScript it lands on `/joined`, which says to email
  us). Switching to `email` also needs sentences in `docs/legal/privacy.md`
  ("Asking for an invite") and `docs/legal/support.md` (asking for and
  leaving the waitlist) that say sign-ups are handled by email.

The legal pages stay `noindex` and out of the sitemap while their front
matter says `status: "draft"`; resolve every `[[OWNER: ...]]` note before
changing that. `/licenses` lists the third-party code and font the built
site ships (`web/src/data/licenses.ts`); update it, and `NOTICE`, when a new
dependency reaches `dist/`.

Deploying is done only with the owner's approval, for that deploy; CI never
deploys, and an agent deploys only when the owner has approved it. The site
is Workers Static Assets on the `hasala-aasa` Worker, on the zone route
`hasala.app/*` (`web/wrangler.jsonc`). To deploy:

1. On the QA host, in its checkout of this repository, check out the commit
   to ship (normally `main`) and enter the devShell.
2. In `web/`: `bun install --frozen-lockfile`, then `bun run deploy`. It runs
   `bun run build` (so the CSP and JS-budget checks gate it), then the
   wrangler pinned in `package.json`, under the devShell's Node.
   `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` come from the
   environment, never from a file in this repository.
3. Verify the live site:
   - `curl -sI https://hasala.app/`: 200, with `strict-transport-security`,
     `permissions-policy` and one `content-security-policy` header
     (`frame-ancestors 'none'`);
   - `curl -s https://hasala.app/ | grep -c 'http-equiv="content-security-policy"'`: 1;
   - `curl -sI https://hasala.app/privacy`: 200, and `/privacy/`: a redirect
     to `/privacy`;
   - `curl -sI https://hasala.app/i/test`: 200, `cache-control: no-store` and
     one `referrer-policy: no-referrer`;
   - `curl -s -D- -o /dev/null https://hasala.app/i/test | grep -i '^content-security-policy'`:
     one line, with `script-src`, `connect-src` and `frame-ancestors 'none'`,
     and no `cloudflareinsights` (the page's `<meta>` still names it; the
     browser enforces both, so Web Analytics cannot run). The same for
     `/freeze` and `/waitlist/confirm`;
   - `curl -sI https://hasala.app/.well-known/apple-app-site-association`: 200
     (no redirect), `content-type: application/json`;
   - `curl -sI https://hasala.app/no-such-page`: 404.

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
