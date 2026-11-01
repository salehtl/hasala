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
| `ios/` | The native SwiftUI app and its Swift packages. `HasalaCore` is the client core (the port from TypeScript). `HasalaKit` is the design system, the read models, the widget data and the Maya mock. `Hasala/` is the app (`App/`, `Features/`, and `Live/`, which connects the screens to the core). `HasalaWidgets/` is the widget extension, with its own `PrivacyInfo.xcprivacy`. Refer to "How the code fits together" below. |
| `conformance/` | Shared fixtures. Go and Swift must give output that is the same, byte for byte. Nine sets are golden files that the Swift tests own (`conformance/README.md`). The ledgerd TypeScript client core and PWA that wrote some of them were removed after commit `9b4aae2`. |
| `web/` | The hasala.app website: Astro and Bun, static output. Refer to "Website" below. |
| `design/` | The logo and exported assets. They are not in this tree yet. The UI source of truth is a private Paper design file. |
| `infra/qa/` | The QA deployment as code. `nix/module.nix` is `nixosModules.hasala` (`services.hasala`). It contains: a PostgreSQL 17 for Hasala only, on a unix socket; the migrations; `hasalad serve` and `hasalad console` on loopback; the tunnel; and encrypted backups. `cloudflared/` contains the ingress golden file, the lint and the fixtures. `nix/tests/` contains the eval check and the VM check. `HOST-PR.md` is the change on the host side (placeholders only). Do not put host names, addresses, accounts or credentials here. |
| `infra/assist/` | The `hasala-assist` Cloudflare Worker (TypeScript, Bun). The app sends it one merchant name and gets a Clef category suggestion (opt-in cloud suggestions). It stores nothing and logs nothing. Its fence test fails on a storage binding, a `console.` call or AI Gateway. `scripts/check.sh` runs its typecheck and tests. Refer to `infra/assist/README.md`. |
| `docs/` | `docs/legal/` contains the privacy policy, the terms, the security page and the support page. The website shows them (`status: "final"`). If a page has an `[[OWNER: ...]]` note, set it to `status: "draft"` again. `docs/decisions/` contains the decisions of record (refer to "Decisions" below). Read the decision of an area before you change it. `docs/runbooks/` contains the restore and the beta review runbooks. `docs/ci.md` contains the CI concurrency and cache details. The ledgerd design history (plans, specs, task reports, reviews) is in a private archive. It is not part of this repository. Code comments that refer to it say "ledgerd design archive". |

## How the code fits together

The phone does all reading and all writing of money data. The server keeps
an encrypted op log for each account and relays wakes.

On the phone (`ios/HasalaCore/Sources/HasalaCore/`):

1. `Mailbox/` runs the mail lanes (`MailboxEngine`, `GmailProvider`,
   `Outlook/OutlookProvider`). `Mailbox/Texts/` reads bank texts. `Mail/`
   decides if a message comes from the bank (`GmailTrustProbe`,
   `OutlookTrustProbe`).
2. `Norm/` normalizes the raw MIME. `Template/` (the bundled templates) and
   `Extract/` (the general and learned readers) read the fields.
3. `Categorize/` and `Cloud/` give the category (the sequence is in
   "Decisions").
4. `Domain/Author/` writes the ops. They wait in `Store/` (`LedgerStore`) and
   `Outbox/`.
5. `Sync/Pusher` seals the ops into frames (`Wire/`, `Crypto/`) and uploads
   them. `Sync/Puller` downloads and opens frames. `Replay/` folds the ops,
   and `Projection/` makes the read model that the screens use (through
   `HasalaKit/Sources/HasalaModels`).

On the server (`server/internal/`): `api` has the routes. `oplog` stores the
sealed frames and examines only the framing, the position and the hash chain.
`gmailpush` and `outlookpush` turn provider notices into content-free APNs
wakes (`pushv2`). `auth`, `authkeys`, `keyproto` and `accounts` are the
accounts, passkeys and keys. `mail` and `mailq` send outbound mail.
`cmd/hasalad/fence_test.go` makes sure that the server cannot reach Gmail,
Graph or the provider token endpoints.

## Build and test

All tools come from `flake.nix` (nixpkgs `nixos-26.05`, locked by
`flake.lock`). The QA host (x86_64-linux) and the Mac (aarch64-darwin) use the
same devShell.

1. Run `direnv allow` one time.
2. In a non-interactive shell, put `direnv exec .` before each command.

Go is the only tool that does not come from 26.05. Go comes from
`nixos-unstable` (1.27.3; pinned to a nixpkgs master commit until the channel has it), because Go 1.26.8 in 26.05 has standard-library
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
- The golden fixtures check. The sets `authres`, `categorize`, `extract`, `fx`,
  `merchant-group`, `norm-dates`, `outlook-sender`, `replay` and `sms-extract` are golden files: the Swift tests own their
  expected output, and `HASALA_UPDATE_GOLDEN=1` rewrites it
  (`conformance/README.md`). The gate fails when a branch changes one of these
  sets and changes nothing under `ios/HasalaCore/Tests`.
- The toolchain floor.
- The hasalad fences (`server/cmd/hasalad/fence_test.go`).
- `go vet` and `go test` in `server/`, then in `server/oracle/`. Both use one
  temporary Postgres (unix socket only).
- The typecheck and `bun test` of the assist worker (`infra/assist`).
- The conformance suites. The `CONFORMANCE` table in `scripts/check.sh` names
  the Go packages of each fixture set. Each directory
  in `conformance/` must have an entry. When you add a fixture set, add its
  entry.
- The known failures (`KNOWN_FAILING` in `scripts/check.sh`). The gate skips
  each one by name, then runs it alone, and it must still fail.

### One test

- Go (in `server/` or `server/oracle/`):
  `go test -count=1 -run '^TestName$' ./internal/oplog`. Tests that use
  Postgres start their own temporary cluster.
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

The last job, `ci-ok`, needs only the fast jobs: `changes`, `gate`, `vuln`
and `secrets`. It always runs. It fails if one of these jobs failed or was
cancelled. It passes when each one succeeded or was skipped. `ci-ok` is the
required check that the ruleset must name. Until the owner changes the
ruleset, the ruleset names these three jobs:

- `gate`: first `nix flake check --no-build`, then a build of each check
  except `qa-vm`, then `scripts/check.sh` in the devShell. In CI,
  `scripts/check.sh` skips its `govulncheck ./cmd/hasalad/...` step, because
  `vuln` scans all packages.
- `vuln`: `govulncheck ./...` in `server/` and in `server/oracle/`. The job
  fails if it finds a reachable advisory.
- `secrets`: the real-mail fence, the HasalaCore lints
  (`ios/scripts/check-imports.sh --no-manifest` and `check-forbidden.sh`),
  then gitleaks on the full history.

Do not change these job names or the name `ci-ok`. The required status
checks find the jobs by their names. Add a new job to the `needs` of `ci-ok`
only when it is fast and it must stop a merge. Do not add the slow jobs
(the Mac jobs, `web` and `nixos-vm`).

These jobs are slow. They are not required, and `ci-ok` does not need them,
thus they do not stop a merge: `swift` (HasalaCore on a Mac), `ios-tools`
(the iOS checks on a Mac, refer to "The iOS app" below), `web`
(the website, refer to "Website") and `nixos-vm` (it builds
`checks.x86_64-linux.qa-vm` with KVM).

### Path rules in CI

On a pull request and on a push to `main`, CI examines the changed paths. If
it is not sure, it runs the job.

- The first job, `changes`, makes a list of the changed paths in the pull
  request (`git diff -z`, thus each file name agrees exactly as it is
  written).
- CI skips `gate`/`vuln`, `swift`, `ios-tools`, `web` or `nixos-vm` only
  when all changed paths are on the list of paths that the job does not read.
  All other paths start the job. This includes paths that nobody expected
  (for example a new top-level directory, `go.work`, `.gitattributes`).
- No job reads `LICENSES/`, root `*.md`, `NOTICE` or
  `private-fixtures.lock`. Only `ios-tools` reads `design/`.
- `gate` and `vuln` also do not read `docs/`, `web/` and `ios/`. But they read
  all `*.go`, `*.nix`, `go.mod`, `go.sum`, `go.work` and `go.work.sum` files
  in those directories, and the bundled templates
  (`ios/HasalaCore/Sources/HasalaCore/Resources/templates/`). A change in
  `infra/` starts them.
- `swift` reads only `ios/` and `conformance/`, plus `server/internal/tmpl/seed/`.
- `ios-tools` reads only `ios/`, `design/` and the
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

### Concurrency and caches

A new push to a pull request cancels its older run. A newer push to `main`
cancels the Mac jobs of an older push. Only a push to `main` saves a Nix cache entry. Do not use
`magic-nix-cache-action`. `vuln-weekly.yml` and `ci-weekly.yml` run on a
schedule and are not required. The details are in `docs/ci.md`.

Rules for a change to the CI:

1. Use a job-level `if:` to skip a job. A required check that CI skips counts
   as a pass.
2. Do not use a workflow-level `paths:` filter. It keeps the required checks
   in the pending state permanently.
3. If a job starts to read a path on its list of paths that it does not read,
   remove that path from the list in `changes`.

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

- CI does not build the app and does not run `HasalaTests` or
  `HasalaUITests`. Run them with the `xcodebuild test` command in "Tests"
  above.
- Job `ios-tools` does the checks that do not use the app build or a simulator: the
  HasalaKit tests, the design tokens, the project against `ios/project.yml`,
  `ios/scripts/tests/run.sh` and shellcheck on `ios/scripts`. It runs
  `ios/scripts/tests/devshell_test.sh` only when `ios/scripts/` or the flake
  changed.
- `ios-tools` is not a required check, and `ci-ok` does not need it.

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
  - `ca-distrust` (on the two systems). It builds the CA bundle with the
    module's `hardening.distrustedCARoots` and examines that those roots are
    not trusted for servers, and that the roots of the hosts the QA host calls
    are.
  - `qa-vm` (on x86_64-linux). It must have KVM.
- On a Mac, `nix flake check --no-build --all-systems` evaluates the Linux
  checks.

### hasalad

`hasalad <mode>` has these modes: `serve`, `migrate`, `verify`,
`purge-user`, `invite` (`mint [--review | --email]`, `list`, `revoke`),
`account` (`review`, `unfreeze`), `waitlist`, `email test`, `console` and
`version`. `account unfreeze <uuid> --confirm <uuid>` lifts any freeze. It is
the out-of-band path for a holder who cannot lift their own freeze (for
example a freeze dated to a phrase recovery). Refer to
`docs/runbooks/restore.md`. `console` is the operator
console of spec 07. It is minimal: waitlist approval, invites and the email
log.

`HASALA_MIN_IOS_BUILD` (Nix: `services.hasala.minIosBuild`) is the oldest iOS
build that hasalad serves: the `CFBundleVersion` with the dot removed
(`261029.11530` is `26102911530`). `0` serves every build. `/meta` reports it,
and the app shows the "Update Hasala" wall at launch. Every other route answers
`426 upgrade_required` to an older `Hasala-Client` build, so an open app and
sign-in stop too. Raise it when a server change breaks older builds. Local builds
have build `1`, so a raised minimum also stops them against QA.

The configuration is in `HASALA_*` environment variables. These have
priority over an optional TOML file (`server/config.example.toml`).

There are two Postgres roles:

- `hasala_migrate` owns the schema. `hasalad migrate` runs only as this role.
- `hasala_runtime` operates the server. All other modes do not start as the
  owner, as a superuser, or when the database is behind the embedded
  migrations.

Tests start their own temporary cluster (`internal/pgtest`). To use one
cluster again, set `HASALA_TEST_POSTGRES_URL`.

### The restore ledger

The restore ledger (`server/internal/purgeledger`, the file
`/var/lib/hasala-ledger/purged` on the QA host) records changes that a backup
restore must not undo. `hasala-purge-replay` applies them again before
`hasalad` starts. Refer to `docs/runbooks/restore.md`.

- The ledger records account deletions, freezes and unfreezes, device
  removals, password changes, passkey removals, waitlist leaves, waitlist
  entries deleted after a bounced invite, the first view of the 12 words
  after a signup that skipped them, sign-outs of all sessions (`sessions`),
  email changes (`email`) and the operator's invite revocations
  (`invite-revoked`). It records only internal IDs and
  times. Do not add an email address or a name.
- A deletion's line is written before its commit. When the commit fails and
  the account is still there, `purge-cancelled` cancels that line, and the
  replay purges the account only if a later deletion line names it. Known
  limit: a process stop between the append and the commit leaves the line, and
  the next replay purges that account although the database was not restored. A
  failed commit whose read-back cannot reach the database behaves the same way.
- `hasalad account unfreeze` records its unfreeze in the ledger, with the
  same kind as the holder's. No command freezes an account as the operator
  yet. When you add one, record the freeze in the ledger.
- A line with only two fields is an account deletion. Each other event has a
  third field (its kind). Do not change the format of an existing kind. Old
  lines must stay readable.
- The replay applies an unfreeze too. A replay never leaves a holder-frozen
  account with no passkey and no password: it lifts that freeze and records
  an `account_unfrozen` event.
- The ledger has times in whole seconds. The replay compares a database time
  with a ledger time at second precision.
- When you add a change that a restore must not undo, record it in the ledger
  and add its replay. The replay must be safe to run two times, and a replay
  on a database that was not restored must apply nothing.

- The reader skips a line of a kind it does not know, with a log line, and
  keeps it in the file. Parsing of each known kind stays strict: a malformed
  line fails the whole ledger.

> **WARNING:** Older `hasalad` builds fail on a kind they do not know. Then
> `hasala-purge-replay` fails and `hasalad` does not start. A build from before
> the event kinds (before branch `legal/accuracy-fixes`) fails on each line
> with a third field. A build from before `onboarding/w5-review-fixes` fails on
> each kind newer than itself (for example `phrase-seen`, `sessions`, `email`
> and `invite-revoked`). A build from before `hardening/ledger-and-limits`
> skips `sessions`, `email` and `invite-revoked`, so its replay does not apply
> them again. A build from before `security/server-lifecycle` skips
> `purge-cancelled`, so its replay purges an account whose deletion was
> cancelled. Before you deploy one of these, copy the ledger file. Then,
> in this order: list the accounts whose latest deletion or `purge-cancelled`
> line is `purge-cancelled`; remove every deletion line of those accounts; remove
> all `purge-cancelled` lines; remove each other line the build cannot read.

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
3. Run `bun run check` (this is `astro check`) and `bun run test`.
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
  ledgerd TypeScript client core was **ported** to Swift (no JavaScriptCore).
  The conformance fixtures prove that the port is correct.
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
- **Transactions also come from Outlook (2026-10-20). The phone reads it.**
  Only personal Microsoft accounts (`consumers`), Microsoft Graph v1.0, no
  MSAL. The phone lists the Inbox with a `$filter` on the known bank sender
  addresses (`OutlookSenders.known`), with immutable ids. A message is the
  bank's only when its `From` is a known sender, it is in the Inbox and its
  domain publishes DMARC `p=reject`; else it goes to Review. Junk waits for
  review, and Deleted Items is left out. The server holds no Microsoft token
  and does not call Graph. It relays Graph notices as content-free wakes and
  keeps only the SHA-256 of each link's `clientState`. Refer to
  `docs/decisions/outlook-mailbox.md` and
  `docs/decisions/outlook-trust-runbook.md`.
- **Transactions also come from bank texts (2026-10-26). The phone reads
  them.** The person makes one Shortcuts automation (Message Contains ".", no
  sender, Run Immediately, Hasala › Add bank text); Shortcuts needs a sender or
  a phrase, and every DIB payment text has a full stop in its amount. It hands
  each such incoming text to the app on the phone. An account uses bank email or bank texts, not both: texts work
  only while the account has no mailbox link, on every device. The phone keeps
  only payment texts and drops all other texts at once, with no storage; when
  it is not sure, a text with a payment shape goes to Review. Nothing sends a
  text off the phone, and hasalad never sees one. Do not put a raw text in the
  op log. The text key is an HMAC under a secret that stays on the device, and
  a key never drops a text (a repeat is a held probable copy). An iPhone authors
  at most 200 automation texts a day; over that a text fails with a message and
  needs a paste. A text from the
  automation files with no review when the account has no mailbox link, its
  fields were read, and an SMS template read it or the two readers agree on
  amount, currency and direction (each at 0.8 or more, as for mail). There is
  no sender check and no card check (2026-10-29). Held hits, transfer partners,
  marked texts, a repeat of a text in the same minute, a text with a mail twin,
  a text of the same payment as a nearby text row that has no bank or was read
  another way, a reader debit beside a transfer text, a reading whose only
  direction word is ambiguous ("transfer", "sent") or that moves money between
  two of the person's own accounts, and a text that names a standing
  instruction, a clearing or an investment account wait in Review, and a paste
  always does. Apple's on-device
  model does not read texts. Learned text layouts (from bank senders and from
  texts with no sender) stay in memory only. A text row uses `entry_method: mailbox` with no `gates.ar`,
  `provenance` or `dedupe`. A mail that may repeat a text row's payment waits
  in Review and never files itself (D10). Refer to
  `docs/decisions/bank-texts.md`.
- **No card or account linking (2026-10-29).** No code path writes
  `card_linked` or makes an account from a card (texts, Gmail, Outlook). Mail
  files with a confirmed or unconfirmed recipient (a mismatch never files) and
  has no card gate. The fold still reads the `card_linked` and `account_set`
  ops of older builds. Refer to `docs/decisions/filing-without-cards.md`.
- **Categorization occurs on the device**, in this sequence: user rules, then
  the UAE merchant dictionary in the app, then the person's last pick for
  that merchant group and direction (`LastPick`: the newest filed row they
  sorted themselves into one category, source `user`, not split; a
  suggestion only, it never files a row, and a debit pick keeps the models
  from being asked about that group), then Apple Foundation Models (only
  for merchants in Latin script; it cannot read Arabic), then the review
  queue.
- **Merchant suggestions (2026-10-20) are the one exception.** They are opt-in
  and off by default, and each device has its own switch. With the switch on,
  when rules and the dictionary give no category and the person has no
  last pick for that merchant group's debits (a pick on a credit, or a split
  row, does not count), the phone sends one merchant string and the built-in category names
  to Clef (Workers AI) first. Apple's model is the fallback. The phone calls the
  `infra/assist/` Worker directly. That Worker has no account identity and
  stores and logs nothing. hasalad never sees these requests. A suggestion
  does not file a row (`needs_review` stays true). There is one exception:
  "Sort automatically", a second opt-in. With it, a Clef answer at or above
  the auto-file threshold (0.7, margin 0.4; 2026-10-29) files the row with
  `needs_review: false`. Apple's model never files a row
  (`ModelTier.autoConfirm = false`). With the switch on, Hasala works
  through what waits in Review by itself while the app is open
  (2026-10-23, `BacklogSorter.ensure()`), still one name per request,
  within the per-device day cap. Do not send other data
  through this path: no amount, date, card, bank, custom category name or
  email. Refer to `docs/decisions/cloud-suggestions.md`.
- **Sorting rework and rebuild (2026-10-23)**: Review shows one card per payment. The merchant group
  (`MerchantGroup.key`, from the raw merchant and the dictionary only) stays behind the
  scenes. A rule comes only
  from "Always use it" (off by default). It also files every payment of that merchant
  group and direction whose spelling the rule holds (at most 8 exact patterns), in every
  month, except the ones the person sorted (`RuleReach.ruled`); no rule is made after
  repeated filings. The pick sheet always starts from a bucket, and its New category row
  adds a category and sorts the card in one atomic edit (`.addCategoryAndSort`). The app
  has no **Not this** and writes no new rejections. The op
  `merchant_category_rejected` (from #182) stays readable and travels alone in its wire
  blob; rejections already in the log apply after the model's answer, so the Cloudflare
  request does not change. Trust on a phone may only raise the auto-file bar. Refer to
  `docs/decisions/sorting-rework.md`. The crowd merchant list is a proposal only
  (`docs/decisions/crowd-merchant-list.md`).
- **Template-free reading (2026-10-23; decided, app work pending)**: templates will read
  first. When no template reads a mail, general rules and the sender's layouts learned
  on the phone will read it, with promo lines removed. Every mail of a sender, template
  hits included, trains its layouts, and they persist on the phone. A row will file with
  no review only with today's trust gates and a template hit or the two readers'
  agreement on amount, currency and direction (each reader's confidence 0.8 or more,
  and no direction that rests only on transfer or sent words); otherwise
  Review is prefilled. Pending transfer notices are to be disregarded. When a mail shows
  AED and a foreign amount, the AED amount is to count. The app is to merge DIB's
  transfer notice and debit alert for one movement without the person; today it still
  flags the pair in Review. Learned layouts stay on the phone. `ios/tools/extract-bench`
  measures the readers. Refer to `docs/decisions/template-free-reading.md`.
- **Auth**: passkeys (RP ID `hasala.app`) and a 12-word recovery phrase;
  invite codes; a WebAuthn step-up for each operation that changes auth,
  keys or mailboxes.
- **Recovery phrase (2026-10-15, amended 2026-10-22)**: no word check. The
  invariant is "nothing is published before the words were shown to the
  person". A passkey signup with PRF and a synced passkey may publish first
  and show the 12 words later; their first view goes in the restore ledger
  (`phrase-seen`). Refer to `docs/decisions/recovery-phrase-no-quiz.md`.
- **Recurring items (2026-10-21)**: a recurring item is a `bill` in the code.
  There is no new op type: `bill_set` gains optional keys that older builds
  ignore. Matching and detection are computed from the log on each device and
  are not written as ops. Refer to `docs/decisions/recurring-items.md`.
- **Op version ceiling (2026-10-31)**: a next-version row stops sync only when
  `/meta` reports that a shipped build writes that version. Raise
  `OpVersionCeiling` and deploy `hasalad` before a build that writes a new
  schema. Refer to `docs/decisions/op-version-ceiling.md`.
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
