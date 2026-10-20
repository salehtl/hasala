# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is a symlink to this file. Edit `CLAUDE.md`, and keep the symlink.

# Hasala

Hasala (حصّالة) is a private budget app for iPhone users in the UAE. It is a
native iOS app. It replaces ledgerd (ledger 2.0) and it is public.

At this time, Hasala goes to a small TestFlight beta. All deployments are
**QA**. This stays true until there is a production VPS.

## Layout

| Path | Contents |
| --- | --- |
| `server/` | The Go server `hasalad` (module `github.com/salehtl/hasala/server`). It uses Postgres. It is a fork of ledgerd at commit `4b01e36`. |
| `server/oracle/` | A different Go module. It contains the frozen ledgerd v1 reference packages (`v1ref`), the corpus reader and the corpus gates. Use it only as a test oracle. The server build graph cannot get access to it. |
| `ios/` | The native SwiftUI app and its Swift packages. `HasalaCore` is the client core (the port from TypeScript). `HasalaKit` is the design system, the read models and the Maya mock. |
| `conformance/` | Shared fixtures. Go, the TypeScript reference and Swift must all give output that is the same, byte for byte. |
| `reference/ledgerd-client/` | The ledgerd TypeScript client core. **Use it only as a reference and a fixture oracle.** The Swift port must agree with it. Do not ship it. |
| `reference/ledgerd-pwa/` | The ledgerd React PWA. Use only its product logic (`src/lib/`) as a reference. Do not ship it. |
| `web/` | The hasala.app website: Astro and Bun, static output. Refer to "Website" below. |
| `design/` | The logo and exported assets. They are not in this tree yet. The UI source of truth is a private Paper design file. |
| `infra/qa/` | The QA deployment as code. `nix/module.nix` is `nixosModules.hasala` (`services.hasala`). It contains: a PostgreSQL 17 for Hasala only, on a unix socket; the migrations; `hasalad serve` and `hasalad console` on loopback; the tunnel; and encrypted backups. `cloudflared/` contains the ingress golden file, the lint and the fixtures. `nix/tests/` contains the eval check and the VM check. `HOST-PR.md` is the change on the host side (placeholders only). Do not put host names, addresses, accounts or credentials here. |
| `infra/assist/` | The `hasala-assist` Cloudflare Worker (TypeScript, Bun). The app sends it one merchant name and gets a Clef category suggestion (opt-in cloud suggestions). It stores nothing and logs nothing. Its fence test fails on a storage binding, a `console.` call or AI Gateway. `scripts/check.sh` runs its typecheck and tests. Refer to `infra/assist/README.md`. |
| `docs/` | `docs/legal/` contains the privacy policy, the terms, the security page and the support page. The website shows them (`status: "final"`). If a page has an `[[OWNER: ...]]` note, set it to `status: "draft"` again. The Hasala architecture and decisions will also go in `docs/`. They are not in this tree yet. The ledgerd design history (plans, specs, task reports, reviews) is in a private archive. It is not part of this repository. Code comments that refer to it say "ledgerd design archive". |

## Build and test

All tools come from `flake.nix` (nixpkgs `nixos-26.05`, locked by
`flake.lock`). The QA host (x86_64-linux) and the Mac (aarch64-darwin) use the
same devShell.

1. Run `direnv allow` one time.
2. In a non-interactive shell, put `direnv exec .` before each command.

Go is the only tool that does not come from 26.05. Go comes from
`nixos-unstable` (1.27.2), because Go 1.26.8 in 26.05 has standard-library
advisories that are reachable. The flake builds gopls, govulncheck and
golangci-lint again with this Go. The `toolchain` line in `server/go.mod` is
the security floor. In `server/`, `govulncheck ./...` must show nothing that
is reachable.

### The gate

`scripts/check.sh` is the gate. It does these steps:

- The real-mail fence.
- The HasalaCore lints, and a check that the bundled templates
  (`ios/HasalaCore/Sources/HasalaCore/Resources/templates`) are the same as
  `server/internal/tmpl/seed`. After you change a seed template, run
  `swift ios/tools/templates/sync.swift`.
- The toolchain floor.
- The hasalad fences (`server/cmd/hasalad/fence_test.go`).
- `go vet` and `go test` in `server/`, then in `server/oracle/`. Both use one
  temporary Postgres (unix socket only).
- The typecheck and `bun test` of the reference client.
- The conformance suites. The `CONFORMANCE` table in `scripts/check.sh` names
  the Go packages and the bun test files of each fixture set. Each directory
  in `conformance/` must have an entry. When you add a fixture set, add its
  entry.
- The known failures (`KNOWN_FAILING` in `scripts/check.sh`). The gate skips
  each one by name, then runs it alone, and it must still fail.

Before the first run in a checkout, run
`(cd reference/ledgerd-client && bun install --frozen-lockfile)` one time.

### One test

- Go (in `server/` or `server/oracle/`):
  `go test -count=1 -run '^TestName$' ./internal/oplog`. Tests that use
  Postgres start their own temporary cluster.
- Reference client (in `reference/ledgerd-client/`): `bun test <file>`, and
  `bun run typecheck`.
- HasalaCore: `swift test --package-path ios/HasalaCore --filter <Target>.<Class>/<test>`.
  CI (job `swift`) runs `swift test --disable-automatic-resolution --explicit-target-dependency-import-check error`
  in `ios/HasalaCore`.
- The app: add `-only-testing:HasalaTests/<Class>/<test>` (or
  `HasalaUITests/...`) to the `xcodebuild test` command in "The iOS app".

### Before a push

`scripts/pre-push.sh` runs the fast CI checks on the paths that you changed
since `origin/main`: the fence, the HasalaCore lints, gitleaks on the new
commits, gofmt and go vet, nixfmt, the tokens, the project, the templates,
shellcheck and the web check. It takes seconds. `--all` runs all the checks.
It shows PASS, FAIL or SKIP for each check and fails on a FAIL. A check skips
when its tool is not on PATH, thus run it in the devShell.

The script is not a hook. The owner can link it in their own clone:
`ln -s ../../scripts/pre-push.sh .git/hooks/pre-push`. All worktrees of that
clone then use it. Agents do not set `core.hooksPath` and do not install
hooks.

### CI

CI is `.github/workflows/ci.yml`. It runs on each pull request and on each
push to `main`. You can also start it manually (`workflow_dispatch`). CI does
not have the private fixtures.

The required checks are these three jobs:

- `gate`: first `nix flake check --no-build`, then a build of each check
  except `qa-vm`, then `scripts/check.sh` in the devShell. In CI,
  `scripts/check.sh` skips its `govulncheck ./cmd/hasalad/...` step, because
  `vuln` scans all packages.
- `vuln`: `govulncheck ./...` in `server/` and in `server/oracle/`. The job
  fails if it finds a reachable advisory.
- `secrets`: the real-mail fence, the HasalaCore lints
  (`ios/scripts/check-imports.sh --no-manifest` and `check-forbidden.sh`),
  then gitleaks on the full history.

Do not change these job names. The required status checks find the jobs by
their names.

These jobs are not required: `swift` (HasalaCore on a Mac), `ios-build`,
`ios` and `ios-tools` (the app on a Mac, refer to "The iOS app" below), `web`
(the website, refer to "Website") and `nixos-vm` (it builds
`checks.x86_64-linux.qa-vm` with KVM).

At most five Mac jobs run at the same time in one run (the account limit).

### Path rules in CI

On a pull request and on a push to `main`, CI examines the changed paths. If
it is not sure, it runs the job.

- The first job, `changes`, makes a list of the changed paths in the pull
  request (`git diff -z`, thus each file name agrees exactly as it is
  written).
- CI skips `gate`/`vuln`, `swift`, the iOS jobs, `web` or `nixos-vm` only
  when all changed paths are on the list of paths that the job does not read.
  All other paths start the job. This includes paths that nobody expected
  (for example a new top-level directory, `go.work`, `.gitattributes`).
- No job reads `LICENSES/`, root `*.md`, `NOTICE` or
  `private-fixtures.lock`. Only the iOS jobs read `design/`.
- `gate` and `vuln` also do not read `docs/`, `web/` and `ios/`. But they read
  all `*.go`, `*.nix`, `go.mod`, `go.sum`, `go.work` and `go.work.sum` files
  in those directories. A change in `infra/` starts them.
- `swift` reads only `ios/` and `conformance/`.
- `ios-build`, `ios` and `ios-tools` read only `ios/`, `design/` and the
  flake. The devShell step of `ios-tools` reads only `ios/scripts/` and the
  flake (output `ios_scripts`).
- `web` reads only `web/`, `docs/legal/` and the flake.
- `nixos-vm` reads only `infra/` (except `infra/assist/`), `server/` and the
  flake.
- A change in `.github/` starts all jobs. `secrets` always runs.
- If `changes` does not succeed, all jobs run.
- A manual run starts all jobs.
- A push to `main` uses the same path rules for all jobs, against the commit
  that `main` was at before the push. The pull request already ran them on
  the same code, because a branch must be up to date before it merges. If CI
  cannot get that commit (a new branch, a force push), all jobs run.

Rules for a change to the CI:

1. Use a job-level `if:` to skip a job. A required check that CI skips counts
   as a pass.
2. Do not use a workflow-level `paths:` filter. It keeps the required checks
   in the pending state permanently.
3. If a job starts to read a path on its list of paths that it does not read,
   remove that path from the list in `changes`.

`.github/workflows/vuln-weekly.yml` runs the same govulncheck on `main` each
Monday (job `vuln-weekly`, not required). This is necessary because new Go
advisories occur without new commits. It is a different workflow, thus it
does not record checks on the head of `main` with the required names.

### Secrets and real mail

`.gitleaks.toml` lets through only known public test vectors. Each entry
applies only to its rule, its files and its exact value.

> **WARNING:** Do not make the `.gitleaks.toml` allowlist larger to let a
> real secret through.

Real bank mail is **not** in this repository. The real-mail conformance cases
and the signed `.eml` fixtures are in the private repository
`salehtl/hasala-fixtures`, at the same paths.

1. To run the tests that read them, set `HASALA_PRIVATE_FIXTURES` to the
   absolute path of a checkout of the private repository. Without it, these
   tests skip by name. `scripts/check.sh` shows how many ran and how many
   skipped.
2. Make sure that the checkout agrees with `private-fixtures.lock`.
3. After you change the private repository, run
   `scripts/private-fixtures-lock.sh write`. Commit the two changes.

> **WARNING:** Do not commit a real message, account number, card number
> (masked or not masked), name, amount, date or reference in this
> repository. Use synthetic data. No real transaction amount or date is in
> this tree. This is also true for `server/oracle/v1ref`.

The first step of `scripts/check.sh` is the real-mail fence. It stops the
private paths. CI runs this step alone (`scripts/check.sh --fence-only`, with
no fixtures and no toolchain) in `secrets` on each push and pull request.
`gate` runs it again as the first step of `scripts/check.sh`.

### The iOS app

The iOS app (`ios/`) builds only on macOS, with the Xcode 27 of the system.

Project file:

1. Do not edit `Hasala.xcodeproj` manually. XcodeGen **2.46.0** makes it from
   `ios/project.yml`. The project is in the repository.
2. To make the project again, run `ios/scripts/generate-project.sh`. To
   examine the committed project, add `--check`.
3. Use only the XcodeGen from the flake (`nix build .#xcodegen`; it is on
   PATH in the darwin devShell). The nixpkgs XcodeGen 2.44.1 makes a project
   without resources.

Tests:

- `swift test --package-path ios/HasalaCore` tests the client core: the unit
  tests and the conformance suite (it reads `conformance/` in place).
- `swift test --package-path ios/HasalaKit` tests the design tokens, the money
  format, the Maya mock and the text contrast.
- `xcodebuild test -project ios/Hasala.xcodeproj -scheme Hasala -destination 'platform=iOS Simulator,name=iPhone 17'`
  runs the unit tests and the UI tests. The UI tests do the accessibility
  audit at the default text size and at the `.accessibility3` text size.

Design tokens: `swift ios/tools/tokens/generate.swift` makes them from
`design/tokens/paper-tokens.json`. CI runs it with `--check`.

Debug and Release:

- Debug builds run the synthetic Maya scenario
  (`-HasalaScenario maya|mayaHidden|mayaSample`).
- Release builds do not link HasalaMocks. `ios/Config/Shared.xcconfig`
  removes it from all configurations except Debug.
- Release shows only the parts that operate (`BuildSurface`): no placeholder
  screens, and no controls that do not have a screen. It shows only the
  account actions in `AccountSession.capabilities`.
- `-HasalaReleaseSurface` gives a Debug run the same surface as Release.
- `ios/scripts/test-release-surface.sh <simulator udid>` runs
  `ReleaseSurfaceTests` on a simulator build with the Release configuration
  that links the mock.

Release scripts:

- `ios/scripts/archive.sh` runs a gate before it builds (exit 13). First, no
  `IntegrationStub` must be in `ios/`. Then it runs
  `ios/scripts/privacy-lint.sh`. This lint compares the use of
  required-reason APIs with the privacy manifest.
- `ios/scripts/check-bundle.sh <.app|.xcarchive|.ipa>` examines the contents
  of a build:
  - No test data.
  - No resource larger than 5 MB, except fonts and the merchant dictionary.
  - The sample seed must agree with `ios/scripts/golden/maya-v1.sha256`. That
    value must agree with `SampleManifest.sha256`. When you make the seed
    again, update the two values.
- `inspect-ipa.sh` runs `check-bundle.sh` as check I6b. Its check I9 stops
  third-party crypto symbols (the export-compliance guard,
  `docs/decisions/export-compliance.md`).
- `ios/scripts/archive.sh` makes an archive and exports a signed .ipa on the
  Mac of the owner. `ios/scripts/upload.sh` uploads it. The two scripts read
  the App Store Connect key only from `ASC_KEY_ID`, `ASC_ISSUER_ID` and
  `ASC_KEY_PATH`.
- `archive.sh` examines the export with `ios/scripts/inspect-ipa.sh`. Its
  `summary.txt` ends with `PASS <n>/<n> sha256=<the .ipa's>` only when all
  checks pass. `upload.sh` uploads only that .ipa.
- The content checks of `inspect-ipa.sh` (secrets, dev hosts, mock data)
  search the bytes of each file and each plist as XML. The dev-host search
  does not use case. These checks do not search UTF-16 text in a resource
  that is not a plist. They also do not search compressed resources (zip,
  gzip, LZFSE, compressed data in `Assets.car`). Thus the endpoint guard is
  the exact `HasalaAPIBaseURL` check, not the dev-host search.
- `archive.sh` makes a release only from a local branch with the name
  `main` (exit 11 on other branches). `--allow-branch` makes a TRIAL build,
  and `upload.sh` does not upload a TRIAL build. If another worktree uses
  `main`, make a release worktree on the branch `main`, then
  `git merge --ff-only origin/main` in it.
- An update of Xcode stops all simulator work. The `simctl` wrapper runs
  `xcodebuild -runFirstLaunch`, and this command waits for the admin
  password of the owner. Until the owner gives it, `simctl` and the UI
  tests stop with no error.
- `ios/scripts/tests/run.sh` runs the release-script tests offline (stub
  xcodebuild and altool, fake keys, synthetic .ipa files).
  `ios/scripts/tests/devshell_test.sh` runs them again in the devShell, where
  GNU coreutils are first on PATH.

CI for iOS:

- Job `ios-build` builds the app one time, without a signature, for the
  tests (`ios/scripts/ci-simulator-test.sh --build-only`).
- Job `ios` is a matrix of three shards (`ios (1)`, `ios (2)`, `ios (3)`).
  Each shard tests the products of `ios-build` in the simulator, without a
  build (`--from-build`), in about 40 minutes. Each shard runs `HasalaTests`
  first. Shards 1 and 2 name their UI test classes. Shard 3 skips those
  classes, thus a new class runs in shard 3. To balance the shards, move a
  class in the matrix in `ci.yml`.
- A test that fails runs one more time. If it passes then, the job passes
  and shows a warning "Flaky test" with the test name. If it fails two
  times, the job fails.
- Job `ios-tools` runs on its own runner, at the same time as `ios-build`.
  It does the checks that do not use the app build or a simulator: the
  HasalaKit tests, the design tokens, the project against `ios/project.yml`,
  `ios/scripts/tests/run.sh` and shellcheck on `ios/scripts`. It runs
  `ios/scripts/tests/devshell_test.sh` only when `ios/scripts/` or the flake
  changed.
- `ios-build`, `ios` and `ios-tools` are not required checks. CI skips them
  on the same paths. `ios` runs only when `ios-build` succeeded.

### Nix

- `nix build .#hasalad` builds `cmd/hasalad`.
- `nix flake check` builds it and examines the format.
- `nix fmt` formats Nix and Go. It does not format `server/oracle/v1ref`.
  Do not change the bytes of `server/oracle/v1ref`.
- The infra checks:
  - `ingress-lint` (on the two systems). It compares the tunnel configuration
    from the module with `infra/qa/cloudflared/config.golden.yml`, and runs
    `lint.sh`.
  - `module-eval` (on x86_64-linux). Each module assertion must fail when you
    use the module incorrectly.
  - `qa-vm` (on x86_64-linux). It must have KVM.
- On a Mac, `nix flake check --no-build --all-systems` evaluates the Linux
  checks.

### hasalad

`hasalad <mode>` has these modes: `serve`, `migrate`, `verify`,
`purge-user`, `invite` (`mint [--review | --email]`, `list`, `revoke`),
`waitlist`, `email test`, `console` and `version`. `console` is the operator
console of spec 07. It is minimal: waitlist approval, invites and the email
log.

The configuration is in `HASALA_*` environment variables. These have
priority over an optional TOML file (`server/config.example.toml`).

There are two Postgres roles:

- `hasala_migrate` owns the schema. `hasalad migrate` runs only as this role.
- `hasala_runtime` operates the server. All other modes do not start as the
  owner, as a superuser, or when the database is behind the embedded
  migrations.

Tests start their own temporary cluster (`internal/pgtest`). To use one
cluster again, set `HASALA_TEST_POSTGRES_URL`.

### Rules for agents on this Mac

- Do not write code comments. (The owner set this rule to save tokens.)
- Do not change the branch of the main checkout. Other agents use it. Do
  your work in your own worktree in `.claude/worktrees/`. Do not use
  `git stash`, because all worktrees share it.
- Search only in specific paths. Do not search all of the home folder. A
  search in `~/Music` or the iCloud folder causes a macOS permission prompt.
- Start at most four agents that use a simulator at the same time. Each
  agent uses its own simulator and its own `-derivedDataPath`, and gives
  `-jobs 4` to `xcodebuild`. Shut down the simulator when you stop, and
  delete it when the work is complete. With more simulators, the Mac uses
  all of its memory and the UI tests fail on timeouts.
- The repository merges pull requests only with squash.

## Website

`web/` is the hasala.app marketing site and its public pages. The pages
`/privacy`, `/terms`, `/security` and `/support` come from
`docs/legal/*.md`. The site uses Astro with static output. The package
manager is Bun, from the same devShell.

From `web/`:

1. Run `bun install --frozen-lockfile` one time.
2. When you edit, run `bun run dev`.
3. Run `bun run check` (this is `astro check`).
4. Run `bun run build`. It writes `dist/` and then runs
   `scripts/check-dist.ts`. The build fails if one of these conditions
   occurs:
   - The CSP that all pages share does not include an inline script or
     style.
   - An element has a `style=""` attribute.
   - `/` loads more than 15 KB of JavaScript (gzip).
   - Web Analytics can run on a page with a code or a token in its address
     (refer to below).

### Third-party scripts

The CSP (`astro.config.mjs`) also lets Cloudflare Web Analytics run.
Cloudflare adds its beacon at the edge (it is not in `dist/`). The privacy
policy tells about it. No other third-party code is on the site, except
Turnstile in "api" mode.

Web Analytics records paths.

> **WARNING:** Do not let Web Analytics run on `/i`, `/i/*`, `/freeze` or
> `/waitlist/*`.

These controls keep Web Analytics off these pages:

- `public/_headers` gives them a CSP header. Its script-src and connect-src
  are the values of the page without Web Analytics. The build adds these
  values (`src/lib/csp-union.mjs`).
- `src/scripts/router.ts` always loads these pages fully.
- The pages remove their code or token from the address bar.

If you add a page with a code or a token in its address, do these steps:

1. Set `referrer="no-referrer"` on `Base`.
2. Add the page to `_headers`.
3. Add the page to the router.

### Local servers and Lighthouse

- To serve the build, use `bun run preview` (the Astro preview server) or
  `bun scripts/serve-dist.ts`. `serve-dist.ts` serves `dist/` on
  127.0.0.1:4321. It uses the `_headers`, the `_redirects`, the
  trailing-slash rules of production and gzip.
- `web/lighthouse/run.sh` runs Lighthouse CI on `/` (mobile and desktop) on
  that server. It must have Node and Chrome, thus it runs in CI (job `web`).
  CI keeps the reports as a workflow artifact. The minimum scores are 0.9
  for performance, and 0.95 for accessibility, best practices and SEO.

### Settings

The PUBLIC_* settings (waitlist mode, API base, Turnstile site key) are in
`web/.env.example`. They are public. The build puts them in the output.

`PUBLIC_WAITLIST_MODE` has two values:

- `api` (the default). The invite form sends to the API. People also use
  this form to tell us about a bank that we do not read yet. The page shows
  "Request sent". The request shows on the waitlist in `hasalad console`.
- `email` (use this only when the API does not operate). The form opens a
  prepared email to support@hasala.app. It sends nothing and does not load
  Turnstile. Without JavaScript, the form goes to `/joined`, which tells
  people to send us an email.

If you change to `email`, also add sentences to `docs/legal/privacy.md`
("Asking for an invite") and `docs/legal/support.md` (how to ask for and
leave the waitlist). These sentences must say that we do sign-ups by email.

### Legal pages and licences

When the front matter of a legal page says `status: "draft"`, the page is
`noindex` and it is not in the sitemap. Before you change this status,
resolve all `[[OWNER: ...]]` notes.

`/licenses` shows the third-party code and fonts that the built site
contains (`web/src/data/licenses.ts`). When a new dependency goes into
`dist/`, update this file and `NOTICE`.

### Deployment

The site is Workers Static Assets on the `hasala-aasa` Worker, on the zone
route `hasala.app/*` (`web/wrangler.jsonc`). Cloudflare deploys it from
GitHub with Workers Builds (the Git integration of the Worker). The owner set
it up in the Cloudflare dashboard. There is no token in GitHub. The root
directory is `web`. The build command is
`bun install --frozen-lockfile && bun run build`. Thus the dist checks are a
gate for each deployment.

- Each branch except `main` gets a preview URL (on `workers.dev`, behind
  Cloudflare Access). Cloudflare puts the URL on the pull request. Examine
  the change there.
- A push to `main` deploys hasala.app. Usually, this push is the merge of a
  pull request. Thus a merge is a deployment to production. Only the owner
  can decide to merge. Cloudflare builds on the push. It does not wait for
  GitHub CI.
- After a production deployment, run `web/scripts/verify-live.sh`. It
  examines the live site (refer to the list below).

### Manual deployment

You can do a manual deployment from any machine. An agent can do it only with
the approval of the owner for that deployment.

1. In a clean checkout, check out the commit that you will ship (usually
   `main`). Go into the devShell.
2. In `web/`, run `bun install --frozen-lockfile`. Then run `bun run deploy`.
   This runs `bun run build` first (thus the CSP and JS-budget checks are a
   gate). Then it runs the wrangler version in `package.json`, with the Node
   of the devShell. `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` must
   come from the environment. Do not put them in a file in this repository.
3. Examine the live site. `web/scripts/verify-live.sh` does all the checks
   that follow:
   - `curl -sI https://hasala.app/`: 200, with `strict-transport-security`,
     `permissions-policy` and one `content-security-policy` header
     (`frame-ancestors 'none'`).
   - `curl -s https://hasala.app/ | grep -c 'http-equiv="content-security-policy"'`: 1.
   - `curl -sI https://hasala.app/privacy`: 200. `/privacy/` must redirect to
     `/privacy`.
   - `curl -sI https://hasala.app/i/test`: 200, `cache-control: no-store` and
     one `referrer-policy: no-referrer`.
   - `curl -s -D- -o /dev/null https://hasala.app/i/test | grep -i '^content-security-policy'`:
     one line, with `script-src`, `connect-src` and `frame-ancestors 'none'`,
     and without `cloudflareinsights`. (The `<meta>` of the page has
     `cloudflareinsights`, but the browser applies the two policies, thus Web
     Analytics cannot run.) Do the same check for `/freeze` and
     `/waitlist/confirm`.
   - `curl -sI https://hasala.app/.well-known/apple-app-site-association`: 200
     (no redirect), `content-type: application/json`.
   - `curl -sI https://hasala.app/no-such-page`: 404.

## Decisions (2026-10-11)

- **Native Swift client.** It must agree fully with the Paper design. The
  TypeScript client core has a **port** to Swift (no JavaScriptCore). The
  conformance fixtures prove that the port is correct.
- **The server is blind.** The phone encrypts each op before it uploads it.
  The server examines only the framing, the position and the hash chain. It
  **does not accept plaintext**. Do not add a feature that makes the server
  read a transaction, an amount, a merchant or an email.
- **Transactions come from Gmail. The phone reads Gmail.** The OAuth tokens
  are in the Keychain of the device. The server only relays Gmail Pub/Sub
  change notices (`emailAddress` and `historyId`) as APNs wakes that contain
  no data. Do not put raw bank email in the op log. Keep only the Gmail
  message id and the parsed fields. Email forwarding and SMTP ingest are not
  used in this version.
- **Categorization occurs on the device**, in this sequence: user rules, then
  the UAE merchant dictionary in the app, then Apple Foundation Models (only
  for merchants in Latin script; it cannot read Arabic), then the review
  queue.
- **Auth**: passkeys (RP ID `hasala.app`) and a 12-word recovery phrase;
  invite codes; a WebAuthn step-up for each operation that changes auth,
  keys or mailboxes.
- **Outbound mail**: Cloudflare Email Service.
- **Hosting (QA)**: the QA host, behind Cloudflare Tunnel. hasalad listens
  only on loopback. It has no TLS code.
- The bundle ID is `app.hasala.ios`. The Google OAuth consent is production
  and not verified (100 users or fewer).

## Core principles (from ledgerd; do not break them)

- The op log is append-only. The server does not validate its payload. The
  code that writes ops has the highest risk in the repository.
- Money is integer minor units (fils). Do not use a float for money.
- Push payloads contain no data.
- Do not drop data silently. Mail that the app cannot parse or verify goes to
  review.
- Secrets come from the environment or the Keychain. Do not put secrets in
  configuration files or in the bundle.
- There are two Postgres roles: `*_migrate` owns the schema, `*_runtime`
  operates the server.

## Design source of truth

The UI source of truth is a private Paper design file. This repository does
not have a link to it.

## Security

Keep security reviews private until all their findings are closed. Close all
findings before a tester who is not a developer installs a build. Send
vulnerability reports to security@hasala.app. Do not open a public issue.

## Licence

The source is available under the Functional Source License, Version 1.1,
ALv2 Future License (`LICENSE.md`). Each version becomes Apache-2.0 two years
after its release. The license does not include the name and the marks
(`TRADEMARKS.md`). During the beta, the project does not accept contributions
from other persons (`CONTRIBUTING.md`). The third-party notices are in
`NOTICE` and `LICENSES/`.
