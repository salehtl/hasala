# UI harness (v2)

**Read this before trusting a green run in this directory.** Until
2026-08-10, `web/harness/` also held a second harness — `stack.sh`,
`shoot.mjs`, `probe.mjs`, `nav.mjs`, `seed.mjs`, `gestures.mjs`, `hero.mjs`,
`ios.mjs`, `sheets.mjs` — forked from `frontend/` with the tree and still
driving **v1**: `stack.sh` built `./cmd/ledger` and ran vite in
`$REPO/frontend`, `nav.mjs` tapped v1's Settings hub rows. Pointing any of
them at a v2 change reported a clean screen it had never loaded. Those nine
files are gone. Every script left in this directory loads `web/src` and only
`web/src`. v1's own harness left with v1 in the 2026-08-11 repo split: it is
`frontend/harness/` in `salehtl/ledger`, and there is no `frontend/` here.

A way to actually *use* the app — not render a component in jsdom, but drive
the real PWA in a real browser against the real Go API (`ledgerd`), then
screenshot and audit the screens vitest and Storybook cannot reach: a control
under the bottom nav, a field that refuses to stay empty, a sheet hidden
behind the keyboard.

## Quick start

```bash
cd web
harness/v2stack.sh up                 # scratch Postgres + ledgerd + vite, prints an invite
bun harness/v2shoot.mjs <invite>     # walks sign-up, screenshots + audits every screen
harness/v2stack.sh down
```

`v2stack.sh up` starts `ledgerd` with **`--dns-fixtures`**, serving the
recorded DKIM/ARC TXT records offline so the corpus's signed bank mail
verifies. **Without it every message a harness sends reads as
`unauthenticated`, the verification step never clears, and no script can
reach the product at all.** If you write a new v2 runner or a new stack
script, it needs this flag too.

Nothing here touches production: `v2stack.sh` runs `ledgerd` and vite on
ports **8123** (API, `127.0.0.1`) and **5177** (UI, `localhost` — WebAuthn
needs a secure context) against a throwaway Postgres cluster under `/tmp`. It
opens neither `/var/lib/ledger` nor `/etc/ledger-v2` nor the running
`ledgerd` service.

## The play instance — the one you USE

Everything else in this directory drives the app for a **script**. `play.sh`
drives it for a **person**, and it is the only thing here a phone can reach.

```bash
harness/play.sh up            # vite behind the tailnet front door — hot reload
harness/play.sh up --built    # ledgerd's embedded bundle — the real PWA shell
harness/play.sh status
harness/play.sh seed          # regenerate the CSV served at /seed/
harness/play.sh invite        # another single-use invite code
harness/play.sh reset         # wipe the database and start over
harness/play.sh down          # stop everything; the DATA stays
```

The app is at **https://$LEDGER_PLAY_HOST:8446** (the host's `tailscale serve` name), tailnet only,
on a real certificate — which is what lets Face ID register a real passkey.
`rp_id` is the tailnet hostname, so a passkey made here is bound here.

**Two modes, one origin.** `--dev` puts vite behind the front door: edit
`web/src`, refresh the tab. `--built` puts `ledgerd` there instead, serving the
embedded bundle — the real service worker, a real "Add to Home Screen", the real
CSP. The origin never changes, so the account, the passkey and the data survive
a switch. Use `--dev` to judge how a screen feels and `--built` before a deploy,
because `env(safe-area-inset-*)`, the software keyboard and `dvh` only tell the
truth on the phone.

**Switching `--built` back to `--dev` leaves a stale worker in charge.**
`VitePWA` has no `devOptions`, so vite dev neither registers nor unregisters a
service worker of its own. The worker installed by `--built` keeps controlling
the origin straight through the switch, so "edit `web/src`, refresh the tab"
silently keeps showing the last built bundle. `up` prints a loud warning when
it detects this transition; the fix is to clear site data for the host, or
unregister the worker in devtools, before trusting what the tab shows.

**Filling it with data.** Open `$ORIGIN/seed/ledger-play.csv` on the device, then
Settings › Import a statement. `playseed.mjs` generates it: six months of
deterministic, *plausible* UAE spending. That is the opposite of `v2nav.mjs`'s
`HOSTILE_ROWS` on purpose — hostile fixtures answer "does this break", and this
file answers "does this feel right". Both questions are real; one file cannot
serve both.

**It is not production, and it is built not to become production.** Its own
Postgres cluster on a unix socket with no TCP port, its own data directory, its
own ports (8446 / 8124 / 5178 / 2528). `guard()` refuses on sight if any of the
four names has drifted onto a production one. `down` removes its **own**
`tailscale serve` entries by port and path — never `tailscale serve reset`,
which would take the admin console, storybook and v1 down with it.

**Reset is total.** It drops the database, so every device must clear its site
data and sign up again. A partial reset that wound the server back behind its
clients would put every device's position and hash chain ahead of the server's,
which is the permanent anomaly state the append-only log cannot recover from.

Design: `2026-08-16-play-instance-design (ledgerd design archive)`.

## The ceremony runners

Three of the four walk the real sign-in or recovery ceremony — `BootGate` is
in front of every v2 screen, and there is no way past it but a real account.
`vault.mjs` is the exception: it needs no server, no invite and no passkey,
only a page on the origin.

| script | proves | state |
| --- | --- | --- |
| `v2settings.mjs <invite>` | the Settings hub scrolled end to end, every destination it has opened and audited, the hub's row list proved complete, and its vertical rhythm measured | current |
| `recovery.mjs <invite>` | a browser with its site data cleared, given twelve words, gets its keys back — and can write again | current |
| `vault.mjs` | the key vault round trip, in Chromium **and** WebKit — no server, invite or passkey needed | current |
| `operator.mjs signup <invite> \| recover` | the whole sign-up → phrase → reload path, in WebKit | current |

> ### All four walk the current product (rebuilt 2026-08-12)
>
> They did not, for two days. `0baf410` ("onboarding proposes, it never blocks";
> `869be0b` in `salehtl/ledger`, if you are reading this from the old repo)
> deleted the **type-back quiz** from the recovery step — there is no "now type
> three of them back" screen, no `recovery-confirm-<n>` fields and no **"Finish
> setting up encryption"** button, and `RECOVERY_PHRASE_COPY` in
> `web/src/v2/onboarding.ts` records the removal in its own comment. All three
> ceremony runners filled those fields and waited for that button, so each
> stalled at the recovery step. The 2026-08-10 removal of the onboarding **bank
> step** broke the same three a second time, and the Settings restructure broke
> `v2settings.mjs` a third.
>
> The step tables were rebuilt from `v2explore.mjs`'s report — the running app
> asked what it renders, rather than the JSX guessed at. Two of the three no
> longer own a walk at all: `v2settings.mjs` and `recovery.mjs` call
> **`v2nav.mjs`'s `ceremony`**, so onboarding is described in exactly one file
> and the next screen that moves breaks one runner instead of four.
> `operator.mjs` keeps its own walk on purpose — `ceremony` drives Chromium with
> a CDP virtual authenticator, and that file exists to run on the engine that
> cannot have one.
>
> `vault.mjs` was unaffected throughout: it walks no ceremony. So is
> `addpasskey-repro.mjs`, which stops at account creation.
>
> **When a step changes again, do not guess from JSX.** Run `v2explore.mjs`,
> which asks the running app what it renders, and rebuild the table from its
> output.

> ### Rebuilt again 2026-08-12: the Gmail-primary walk
>
> The mail stage became one recommendation (connect a Gmail transaction mailbox)
> and a way past it, the forwarding route became provider-picker-first, and the
> home-currency step left the walk for Settings. `ceremony`'s table was rebuilt
> from `v2explore.mjs`'s report against a live `--gmail-fixtures` stack, not from
> the JSX. The step ids it now emits, in order:
>
> `onb-welcome` → `onb-created` → `onb-recovery` → `mail-route` (broker stacks
> only) → `onb-address` (only when boot could not mint one first) →
> `onb-provider-pick` → `onb-forwarding-steps` → `onb-finish`
>
> There is no `onb-home-currency` / `onb-home-currency-confirm` any more. The
> ceremony is still reachable, at Settings → Your money → Home currency, and
> `v2settings.mjs` opens it there.
>
> Three things that walk changed found, all of them in the harness rather than in
> the product:
>
> - **`ceremony` scraped the inbound address off whichever screen printed it.**
>   `boot` reads `GET /api/v1/address` and that read MINTS the address, so a
>   healthy stack walks straight past the address phase — and the skip path never
>   passes a screen carrying it at all. `v2settings.mjs` was handed `null` and
>   died at its SMTP call, several steps from the cause. It reads the address
>   from the server now, which is where the fact lives.
> - **The mail-stage skip clicked the skip BLOCK, not the button in it.**
>   `SkipStep`'s test id is on the wrapper (the consequence sentence AND the
>   control), and Playwright clicks an element's centre. The press did nothing and
>   the run blamed the next screen sixty seconds later.
> - **`recovery.mjs` hooked `onb-forwarding`**, a step id the walk no longer
>   emits, so its "the keys were published and stored" check ran against
>   `undefined`. It names the set of ids that can follow the phrase now.

## The screen sweep — `v2nav.mjs` and the runners built on it

Added 2026-08-10 alongside the Settings restructure. `v2nav.mjs` holds the
ceremony, the fixture data and the screen map — the literal taps that reach
each v2 screen — and the sweep runners drive it:

```bash
harness/v2stack.sh up                 # prints an invite
bun harness/v2shoot.mjs <invite>     # screenshot + geometry-audit every screen,
                                      # two widths, both themes
bun harness/v2deck.mjs <invite>      # every card in the review deck, not just
                                      # the top one
bun harness/v2edge.mjs <invite>      # drill-in left edge: back-arrow tap vs the
                                      # 24px edge-back strip, scroll under thumb
bun harness/v2subs.mjs <invite>      # the Settings drill-ins behind one-line
                                      # rows (recovery warning, bank removal copy,
                                      # home-currency permanence — which is now
                                      # the ONLY place that ceremony exists)
bun harness/v2explore.mjs <invite>   # ceremony walker that REPORTS rather than
                                      # asserts — use it to rebuild the step
                                      # table when the flow changes
```

`v2shoot.mjs` takes `--screens a,b` to narrow the walk and `--fast` to drop to
one pass; each runner documents its own flags in its header — read that first.

The sweep runners import `audit.mjs` for the in-page geometry checks. They do
**not** use `sendmail.py`: `v2nav.mjs`'s `seed` authors its fixtures through
the app's own CSV import, because v2's screens read a local projection of an
append-only op log and there is no HTTP seam to write through. `sendmail.py`'s
only caller is `v2settings.mjs`.

### What the sweep asserts about itself

Both are here because a check that cannot fail is this repo's most repeated
defect, and both have already caught themselves:

- **The fixtures must be ON A SCREEN before any screen is measured.** The importer
  reporting success is not the same as the app showing anything: one run imported
  20 rows that no screen displayed until a relaunch, and every audit in that run
  came back "clean" because there was nothing on the glass to be wrong.
- **Two identical scroll segments is a failure**, inherited from `v2settings.mjs`,
  whose first version picked an inner scroller and reported a clean 2983px screen
  it had never scrolled.

`v2shoot.mjs` also opens every `InfoTip` and measures the panel against the
viewport — the check that found the tip opening 170px off the side of the
forwarding step, a defect no unit test could see because jsdom has no layout.

### The live layer, and why three helpers filter on `[inert]`

Drill-ins **stack** — Held mail opens over Settings — and `AppShell` covers the
buried layer with `inert` rather than unmounting it. An inert button is still laid
out and still passes Playwright's `isVisible()`. Three separate helpers had to
learn this: the scroller picker (it chose the buried screen's scroller and
"captured" six identical segments), the back-button finder (it clicked the buried
panel's back arrow and retried for thirty seconds), and the tip crawler (it clicked
Settings' tip through the panel on top of it).

**`Dialog` marks the page beneath it inert too**, through `useInertBackground`
rather than a wrapper — it renders inside the subtree it covers, so it inerts its
ancestors' other children instead. It used to mark nothing, and `audit.mjs`
reported `background-layer-not-inert` on all seven Settings dialogs. The tip
crawler still scopes to inside the open `[role="dialog"]` as well as filtering on
`[inert]`: that says what it means rather than inheriting it from the app.

### Ports are overridable, because parallel sessions are normal

`v2stack.sh`'s defaults are fixed values and two agents running it at once meant
the second one's `--strictPort` vite died on the first one's port. Every collidable
name is an env var:

```bash
LEDGER_V2_HARNESS_DIR=/tmp/ledger-v2-mine \
LEDGER_V2_API_PORT=8133 LEDGER_V2_UI_PORT=5187 \
LEDGER_V2_SMTP_PORT=2536 LEDGER_V2_DB=ledger_v2_mine harness/v2stack.sh up
```

`sendmail.py` reads `LEDGER_V2_SMTP_PORT` too.


## `v2settings.mjs` — Settings in depth, and proved complete

Three runners look at Settings and each answers a different question.
`v2shoot.mjs` sweeps every screen at two widths and both themes, with a fixed
list of dialogs. `v2subs.mjs` opens the seven drill-ins for their prose. This
one goes **down**: one width, one theme, one account, the hub scrolled end to
end and audited at the bottom as well as the top, and every destination the hub
has opened, headed-checked, screenshotted and audited.

```bash
harness/v2stack.sh up
bun harness/v2settings.mjs <invite-code>
harness/v2stack.sh down
```

**The assertion that is only here is the completeness crawl.** The rows on the
screen are compared against the file's `DESTINATIONS` table in both directions:
a row on the hub that the table does not open fails the run, and a table entry
with no row on the hub fails it too. Every other runner in this directory walks
a hardcoded list, so a row added to Settings tomorrow would be covered by none
of them and nothing would say so. The 2026-08-10 restructure moved three
controls out from under this very file; the crawl is what makes that loud
instead of silent.

It walks no ceremony of its own — `v2nav.mjs`'s `ceremony` is the one
description of onboarding here — and it seeds fixture data so the rows carry
real values rather than the empty state's dashes.

Two things about the mail it posts:

- `v2stack.sh` starts `ledgerd` with `--dns-fixtures`, so the corpus's signed
  bank mail verifies DKIM offline. Without it every message reads as
  `unauthenticated`. Nothing needs that to reach the product any more — the
  verification gate stopped gating in `0baf410` — but Held mail is an empty
  state without it, and an audit of an empty state is an audit of nothing.
- `sendmail.py` posts one corpus message byte-for-byte. Rebuild a header and
  the signature stops verifying.

It sends a **forwarded** message on purpose. A direct one passes DKIM and is
still held with `attested = false` — `origin/inner.go` attests an *inner*
origin, and a message nothing relayed has none — and the client offers trust
only for attested mail.

The capture asserts its own honesty twice over. Two identical scroll segments
fail the run, because the first version of this file picked an inner 816px
scroller and reported a clean 2983px screen it had never scrolled. And the
scroller is chosen **within the topmost layer**, by the same rule `audit.mjs`
uses to pick what it audits: `SettingsPage` marks only its header inert when a
drill-in opens, never its body, so the hub's scroller is an ancestor of the
drill-in and won the largest-overflow contest on every one of the seven — seven
screens measured at the hub's height and photographed unscrolled twice. That
was caught by the identical-segments check during the 2026-08-12 rebuild, which
is the best argument for keeping it.

Screenshots land in `harness/shots/` with a machine-readable
`harness/shots/v2-settings.report.json`.

### The automated audit — `audit.mjs`

Every screenshotting runner here — `v2shoot.mjs`, `v2deck.mjs`, `v2subs.mjs`
and `v2settings.mjs` — imports `audit(page)` from `audit.mjs`, which runs
inside the page and measures laid-out geometry, catching what a screenshot
hides:

- `page-h-overflow` / `element-past-viewport` — content crossing the viewport edge
- `control-obscured` — a control whose centre point hits a *different*
  element, i.e. it cannot be tapped
- `control-under-bottom-nav` — actions trapped beneath the fixed nav
- `content-clipped-unscrollable` — `overflow-hidden` over content taller than its box
- `tap-target-too-small` — below the documented 44px minimum
- `input-font-too-small` — under 16px, which makes iOS zoom on focus
- `text-clipped-no-ellipsis`, `control-without-accessible-name`, `img-without-alt`
- `bad-value-rendered` — a literal `NaN` / `undefined` / `[object Object]` on screen

Findings are geometric facts, not opinions. Judgement calls — hierarchy,
rhythm, copy, whether a screen looks finished — are for a human or a
reviewing agent looking at the screenshots.

Precision is the point. A checker that cries wolf gets ignored, so the audit
knows about several things it would otherwise report forever, including
`.sr-only` text, `line-clamp` and the rolling-digit animation clipping on
purpose, the overlay stack (only the top layer is audited), and
`data-dense-target`, which `IconButton size="sm"` sets to claim the 36px
dense-row allowance `components/README.md` grants it. If you add a
deliberate exception to a convention, teach the audit about it in the same
commit — otherwise the next person learns to skip the output.

## `recovery.mjs` — the at-rest keys, and a browser with nothing in it

This one is about a different kind of claim than layout: **a browser whose
site data has been cleared, given twelve words, gets its keys back.** Every
layer of that is a real browser behaviour — IndexedDB actually being gone, a
`CryptoKey` actually refusing to export, WebAuthn actually finding a
discoverable credential — and jsdom simulates none of them, so it cannot be a
vitest file however well written.

```bash
harness/v2stack.sh up
bun harness/recovery.mjs <invite-code>
harness/v2stack.sh down
```

It creates an account through `v2nav.mjs`'s `ceremony`, **attempts to export
the stored private key material and requires Chromium to refuse**, declares a
bank from Settings, then throws the browser context away and does the whole
thing again from the phrase — including a write, so the recovered device is
proved able to author and not merely to read.

It also checks the ceremony's **order**, not only its outcome: while the twelve
words are on the glass the vault must still be empty. That is the observable
half of what the deleted type-back quiz used to gesture at.
`establishAccountKeys` awaits the press before it wraps, publishes or installs
anything, and this is what holds it to that. Whether the user really wrote the
words down is not checkable by any run, because the product deliberately
stopped asking.

One thing it documents rather than tests: a cleared browser is a new device
*writer*, because the writer's identity key was in the database that was just
destroyed — so it stops at the enrolment wall before the onboarding walk.
That gate is the writer roster's, not the key material's, and the script says
so where it steps around it.

### It is Chromium-only, and that shipped a bug

Its authenticator comes from CDP, which Chromium alone speaks. So this file —
the one that proves key custody — proved it on one engine, and the bug that
reached the operator was WebKit-only: **WebKit accepts an X25519 `CryptoKey`
into IndexedDB, completes the transaction, and returns `null` for that record
on every later read.** Every iPhone published a key set it could never open
and was sent back to the recovery screen on every launch, while this run was
green. Same shape as a timezone guard that passes because the box is UTC.

Two files close it, and a change to `v2/keys.ts` should run both.

## `vault.mjs` — the key vault, in Chromium **and** WebKit

```bash
bun harness/vault.mjs        # needs only a vite on the origin
```

Writes a key set through the app's own `installAccountKeys`, opens a **new**
connection, reads it back, opens the ingest key and derives with it, and
requires every export attempt to be refused — in both engines. No passkey, no
invite, no server. This is the assertion that would have caught the WebKit
loop above, and it fails on the old storage shape with `webkit: read null`.

## `operator.mjs` — the whole path, in WebKit

```bash
bun harness/operator.mjs signup <invite>   # phase one
bun harness/operator.mjs recover           # phase two
```

Sign up, twelve words, press through, **reload**, and check the next launch
does not land back on the phrase screen. It uses `webauthn.mjs`, a real ES256
software authenticator (go-webauthn verifies its signatures like any other),
because Playwright cannot give WebKit a virtual one. A **persistent profile**
is what makes the two phases separable: the passkey, the session and IndexedDB
all survive between them.

`recover` **manufactures the state it is about**. On a healthy build the
profile still holds its keys, so the screen this file exists for never appears
— and a run that then asserts nothing about the phrase would stay green while
the WebKit phrase path rotted completely, which is what it did for months. So
it deletes the key vault and leaves the session alone, which is the operator's
symptom exactly (signed in, and asked for twelve words), types the phrase, and
requires the account back with no re-keying and no new invite. Then it reloads
once more and requires the screen to stay past the step. The delete is proved
by reading the vault back through the app's own module, so a renamed database
that made it a no-op fails the run rather than skipping the test.

This is the only run that exercises phrase → keys → reload **on WebKit**.
`vault.mjs` covers the vault round trip there; `recovery.mjs` covers the phrase
in Chromium.

## `addpasskey-repro.mjs` — a targeted repro, not a pass/fail check

```bash
bun harness/addpasskey-repro.mjs <invite-code>
```

Reproduces adding a SECOND passkey on an authenticator that already holds the
first one — the same situation as an iCloud Keychain user signed into the
same Apple ID on a second device. It asserts nothing automatically: it prints
the raw `addPasskey()` result and the on-screen note, and the reader confirms
the note names this specific failure rather than a generic one.

## `transfer-sheet-repro.mjs` — the Transfer rail's sheet, photographed

```bash
bun harness/transfer-sheet-repro.mjs <invite-code>
```

Reported by hand on 2026-08-16: pulling a card to Transfer opens the category
sheet with nothing in it. Both causes were in `deckCategories` — the excluded
set was the single name `Transfer`, which is the rail's own label, and any name
the user had already *used* shadowed it, so one Transfer sort emptied the rail
for good. This walks the exact sequence: sign up, import the fixtures, open the
rail, sort a card into Transfer, open the rail again. It prints the buttons in
the sheet at both points and shoots `shots/transfer-sheet-{fresh,after-use}.png`;
it asserts nothing beyond the sheet being there, so read the two lines it prints.

## `mailbox.mjs` — the Gmail connect ceremony, and `--gmail-fixtures`

The Gmail transaction-mailbox lane's ONLY real-browser check — everything else on
it is vitest/jsdom, which has no popup, no `BroadcastChannel` across a
browsing-context-group switch, and no real `window.open`.

```bash
harness/v2stack.sh up --gmail-fixtures        # starts fakegmail + points the broker at it
bun harness/mailbox.mjs <invite>             # Chromium: connect + drill-in audit + catch-up
bun harness/mailbox.mjs <invite> webkit      # WebKit: the popup-in-gesture fix (Task 14)
```

`--gmail-fixtures` boots `fakegmail.mjs` — a Node-stdlib fake of Google's OAuth
(`/o/oauth2/v2/auth` consent, `/token`, `/revoke`) and the Gmail REST surface the
fetch lane calls (`profile`/`history`/`messages`/`messages/<id>?format=raw` over
**synthetic** RFC822 fixtures with a valid `mx.google.com` Authentication-Results,
a hostile-width merchant and an unlisted sender) — on a scratch port, and exports
`LEDGER_GOOGLE_OAUTH_CLIENT_ID/SECRET` + the `LEDGER_GOOGLE_AUTH/TOKEN/REVOKE_URL`
loopback overrides so the broker's routes mount and talk to the fake. It keeps
`--dns-fixtures`. Never a real mailbox: the repo history was rewritten once
because real mail was committed.

`mailbox.mjs` connects from the **Settings drill-in's never-connected state**,
which runs the identical `connectMailbox` ceremony the onboarding route does: the
tap opens the popup INSIDE the gesture (the Task 14 WebKit fix), the popup
navigates to fakegmail, is auto-approved, returns through the server callback, and
the callback page hands the claim back on the origin-scoped channel; the drill-in
then shows the burner address decoded from the id_token. WebKit signs in with
`webauthn.mjs`'s software authenticator (Playwright's virtual one is
Chromium-only) and drives the same connect — the fix verified on the engine it is
for. It also drives one real fetch cycle ("Catch up now") by routing
`gmail.googleapis.com` to fakegmail at the network layer, since the client
hard-codes that host.

> **The onboarding `mail-route` screen IS driven by the harness now, and the note
> that used to sit here had the diagnosis wrong.**
>
> It said the screen never appeared because the `mailboxConfigured` probe
> resolves false on its first onboarding mount. The probe was fine. The screen
> was **unreachable in the product**: it was rendered only at the `keys_secured`
> position, and `boot` reads `GET /api/v1/address`, which MINTS the address — so
> `address_issued` was already met and the machine was one position further on
> before the first frame. Every unit test of the card passed and no user on any
> online deployment could ever have seen it.
>
> `v2explore.mjs` is what found it, on 2026-08-12, by walking a real
> `--gmail-fixtures` stack and printing the screens it actually reached. Both mail
> positions go through the route choice now, and `ceremony` walks
> `mail-route` → guidance → backfill → catching-up under `mailRoute: "mailbox"`.
> Settings remains a second connect entry, and the ceremony code is the same.

`v2shoot.mjs` and `v2subs.mjs` cover the drill-in when the row is present
(`--gmail-fixtures`) and SKIP it otherwise — it is config-gated, like a
`SETTINGS_DIALOGS` `optional` entry. The drill-in re-renders while it is measured
and resets its own scroll, so its `SCREENS` entry is `singleSegment` (audit still
measures the whole surface scroll-free; `mailbox.mjs` captures the full states).

## Shared helpers

- `webauthn.mjs` — a real ES256 software WebAuthn authenticator, for the
  engine (WebKit) Playwright cannot give a virtual one. Used by `operator.mjs`
  and `mailbox.mjs`'s WebKit phase.
- `sendmail.py` — posts one corpus `.eml` byte-for-byte to the scratch SMTP
  listener. Used by `v2settings.mjs`; also runnable standalone as
  `python3 harness/sendmail.py <inbound-address> <path-to.eml>`.

## Two traps worth knowing

- **Every runner here leaves motion ALONE — no script in this directory sets
  `reducedMotion`** (checked across `web/harness/` on 2026-08-10).
  `reducedMotion: "reduce"` makes `Dialog` / `SettingsPage` skip their slide
  entirely, which would hide any bug in the slide itself. That flag belongs to
  v1's `shoot.mjs` (`frontend/harness/`, in `salehtl/ledger`), which sets it
  for stable screenshot captures — don't carry the habit over here.
- **Check which tree vite is serving** (`ls -l /proc/<vite-pid>/cwd`).
  `v2stack.sh` resolves the repo from its own location, so running it from a
  stale checkout serves that checkout — it is easy to "verify a fix" against a
  tree that does not contain it.
