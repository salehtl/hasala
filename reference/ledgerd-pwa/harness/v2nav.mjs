/**
 * The v2 product, reachable — the ceremony, the fixture data and the screen map.
 *
 * # Why this exists rather than a reuse of `nav.mjs`
 *
 * `nav.mjs` is v1's, and it no longer sits next door: `web/harness/`'s v1 forks
 * were deleted on 2026-08-10 and the canonical copy left with v1 in the
 * 2026-08-11 repo split — it is `frontend/harness/nav.mjs` in `salehtl/ledger`,
 * and there is no `frontend/` in this repo at all. It taps v1's Settings hub
 * rows against a vite serving v1's own tree, and it has no idea what a passkey
 * is. Point it at a v2 change and it reports a clean screen it never loaded —
 * the failure mode this whole directory exists to prevent. Nothing here
 * imports it.
 *
 * `v2settings.mjs` got as far as one screen, and everything it learned that
 * still holds was carried over here. It used to carry its own copy of the walk
 * and died when two steps in that copy — the recovery type-back and the whole
 * verification gate — stopped existing. Since 2026-08-12 it calls {@link
 * ceremony} instead, as does `recovery.mjs`, so onboarding is described in this
 * file and nowhere else. Keep it that way: four copies of a walk is four things
 * to break, and it is exactly how those two runners died.
 *
 * # Three things this module owns
 *
 *  1. **{@link ceremony}** — sign-up through to the product shell. `BootGate` is
 *     in front of every screen and there is no way past it but a real account,
 *     so every runner in this family starts here.
 *  2. **{@link seed}** — fixture data, authored through the app's own CSV import.
 *     There is no HTTP seam to write through: v2's screens read a local
 *     projection of an append-only op log, so the only honest way to put a
 *     transaction on a screen is to make the app author the op. That also means
 *     the fixtures exercise the importer, which is a second thing measured for
 *     free.
 *  3. **{@link SCREENS}** — every product surface, as the literal taps a user
 *     performs. There is no URL routing to shortcut through, so a screen that
 *     becomes unreachable in the UI becomes unreachable here too. **That failure
 *     is a finding, not a harness bug.**
 *
 * # The fixtures are hostile on purpose
 *
 * Bugs hide in the happy path. `seed` writes a merchant wider than any phone, the
 * widest number the formatter can emit, a foreign currency with no configured
 * rate, and a category name long enough to wrap a chip. v1's `seed.mjs` found
 * more defects with that list than every other technique in this directory
 * combined.
 */

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const ORIGIN = process.env.LEDGER_HARNESS_ORIGIN ?? "http://localhost:5177";

/** iPhone 14 Pro, and the 320px stress width every grid is sized against. */
export const VIEWPORTS = {
  phone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 },
  small: { viewport: { width: 320, height: 568 }, deviceScaleFactor: 2 },
};

/**
 * A resident-key software authenticator, which is what makes the walk possible.
 *
 * The passkey routes verify real signatures — `api.NewServer`'s dev-auth block
 * replaces the ID-token verifiers and never touches `s.Passkeys` — so there is no
 * flag that gets a session without one. Chromium's CDP authenticator signs for
 * real and go-webauthn accepts it like any other.
 */
export const VIRTUAL_AUTHENTICATOR = {
  protocol: "ctap2",
  transport: "internal",
  hasResidentKey: true,
  hasUserVerification: true,
  isUserVerified: true,
  automaticPresenceSimulation: true,
};

export async function settle(page, ms = 400) {
  await page.waitForTimeout(ms);
}

/**
 * A context with the authenticator already installed. Chromium only — CDP.
 *
 * `hasTouch` is off by default and opt-in per runner. It is not cosmetic: with
 * it off the context accepts no touch input at all, so a synthesised touch
 * gesture silently does nothing — which made a scroll check report the left
 * edge of a drill-in unscrollable when the middle of it was equally
 * unscrollable, i.e. when the runner could not scroll anything. It is left off
 * for the capture runs because Tailwind gates `hover:` on `(hover: hover)`, and
 * flipping that mid-review would change every screenshot for a reason unrelated
 * to any change under test.
 */
export async function newSignedOutContext(browser, { viewport = "phone", colorScheme = "light", hasTouch = false } = {}) {
  const context = await browser.newContext({ ...VIEWPORTS[viewport], colorScheme, hasTouch });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  // The id is returned, not discarded: `recovery.mjs` lifts the credential out of
  // one authenticator and installs it in another to model "I cleared my site
  // data" — the passkey lives in the platform keychain and survives the clear —
  // and `WebAuthn.getCredentials` needs the id to do it.
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", { options: VIRTUAL_AUTHENTICATOR });
  return { context, page, cdp, authenticatorId };
}

/**
 * Sign up and walk onboarding to the product shell.
 *
 * `onStep(id, page)` is called once per onboarding screen, before the press that
 * leaves it — that is the only moment those screens are on the glass, and they
 * are unreachable afterwards. A runner that wants to audit onboarding passes a
 * hook; one that only wants the product passes nothing.
 *
 * `skip: true` takes "Set this up later" at every step it is offered, which is a
 * genuinely different end state — the Home screen then carries three setup tasks
 * — and is itself worth capturing.
 *
 * `mailRoute` selects the mail-stage branch WHEN the deployment offers a choice —
 * i.e. when `--gmail-fixtures` configured a broker and the `mail-route` screen
 * appears (spec §3, D11). It follows the bank-step precedent below: the route
 * screen is waited for conditionally, never hard, so a stack WITHOUT the broker
 * (every existing runner) skips straight past it exactly as before.
 *
 *   - `"forward"` (the default) takes the forwarding card, landing on the address
 *     phase the walk has always used — so an unqualified `ceremony` is unchanged.
 *   - `"mailbox"` takes the Gmail card and walks the real connect ceremony against
 *     fakegmail: guidance → the popup (opened inside the gesture, the Task 14
 *     WebKit fix) → auto-approve → the BroadcastChannel claim → a sealed token →
 *     backfill window → the catching-up confirmation, which advances the walk.
 */
export async function ceremony(page, invite, { onStep = async () => {}, skip = false, mailRoute = "forward" } = {}) {
  await page.goto(ORIGIN, { waitUntil: "domcontentloaded" });

  await page.getByTestId("welcome").waitFor({ timeout: 60_000 });
  await onStep("onb-welcome", page);
  await page.getByLabel("Invite code").first().fill(invite);
  await page.getByRole("button", { name: /Create my account/i }).click();

  await page.getByTestId("welcome-created").waitFor({ timeout: 60_000 });
  await onStep("onb-created", page);
  await page.getByRole("button", { name: /^Not now$/i }).click();

  await page.getByTestId("onboarding-recovery").waitFor({ timeout: 60_000 });
  // The words are read before the press, because this is the only screen that
  // ever shows them and a runner may want to keep them.
  const phrase = await page.$$eval('[data-testid="recovery-phrase-words"] li', (items) =>
    items.map((li) => li.textContent.replace(/^\d+/, "").trim()),
  );
  await onStep("onb-recovery", page);
  await page.getByRole("button", { name: /^I have written these down$/i }).click();

  /*
   * The mail stage. It begins on ONE of three screens, and this race waits for
   * whichever this build lands on rather than hard-waiting one that may not
   * exist (the bank-step precedent, generalised):
   *
   *   - `mail-route`     — a broker is configured (--gmail-fixtures), so the user
   *                        chooses between the Gmail mailbox and forwarding (D11).
   *   - `bank`           — an older build that still asks for banks (removed
   *                        2026-08-10; kept tolerated so an old checkout does not
   *                        hang here for sixty seconds blaming the wrong screen).
   *   - `inbound-address` — the forwarding-only build every existing runner hits.
   */
  let inbound = null;
  let mailboxConnected = false;

  const route = page.getByTestId("mail-route");
  const bank = page.getByTestId("bank");
  await Promise.race([
    route.waitFor({ timeout: 15_000 }).catch(() => {}),
    bank.waitFor({ timeout: 15_000 }).catch(() => {}),
    page.getByTestId("inbound-address").waitFor({ timeout: 15_000 }).catch(() => {}),
  ]);

  if ((await route.count()) > 0) {
    await onStep("mail-route", page);
    if (skip) {
      /*
       * The BUTTON inside the skip block, not the block.
       *
       * `SkipStep`'s test id is on the wrapper div — the consequence sentence
       * AND the control — and Playwright clicks an element's centre. As soon as
       * the consequence wrapped to two lines that centre stopped landing on the
       * button, the press did nothing, and the run blamed the screen sixty
       * seconds later for not being the finish screen. Same rule the vitest
       * suite already follows (`notAGate.test.tsx`'s `skipButton`): find the
       * block by its step, then the control inside it by its label.
       */
      await page.getByTestId("mail-route-skip").getByRole("button", { name: /^Set this up later$/i }).click();
    } else if (mailRoute === "mailbox") {
      mailboxConnected = await walkMailboxConnect(page, onStep);
    } else {
      // The forwarding card lands on the address phase the block below drives.
      await page.getByTestId("mail-route-forward").click();
    }
  } else if ((await bank.count()) > 0) {
    await onStep("onb-bank", page);
    if (skip) {
      await page.getByRole("button", { name: /^Set this up later$/i }).click();
    } else {
      await page.getByTestId("bank-row-dib").click();
      await page.getByTestId("bank-row-enbd").click();
      await page.getByRole("button", { name: /^Continue$/ }).click();
    }
  }

  /*
   * The forwarding route, which is provider-picker-first since the Gmail-primary
   * rework: an address phase (only when boot could not mint one before the walk
   * mounted), then "Which mail provider do you use?", then that provider's
   * steps.
   *
   * The address phase is waited for CONDITIONALLY, the same way the mail-route
   * screen above is. `boot` reads `GET /api/v1/address`, and that read is what
   * MINTS the address — so on a live stack the walk usually starts already past
   * `address_issued` and lands straight on the provider question. A hard wait
   * for a screen that a healthy stack skips is how a runner ends up blaming the
   * wrong step for sixty seconds.
   */
  if (!mailboxConnected) {
    const pick = page.getByTestId("provider-pick-list");
    const addressPhase = page.getByTestId("address");
    // The hand-off is in the race because a SKIPPED mail stage lands on it
    // directly: skipping the address skips forwarding with it, so there is no
    // provider question to answer. Without it in the list this block sat out a
    // full 60s timeout on every skip run before finding the finish screen it
    // was already looking at.
    await Promise.race([
      pick.waitFor({ timeout: 60_000 }).catch(() => {}),
      addressPhase.waitFor({ timeout: 60_000 }).catch(() => {}),
      page.getByTestId("onboarding-finish").waitFor({ timeout: 60_000 }).catch(() => {}),
    ]);

    if ((await addressPhase.count()) > 0) {
      inbound = (await page.getByTestId("inbound-address").textContent()).trim();
      await onStep("onb-address", page);
      if (skip) {
        await page.getByRole("button", { name: /^Set this up later$/i }).click();
      } else {
        await page.getByRole("button", { name: /^I have my address$/i }).click();
      }
    }

    if (!skip) {
      await pick.waitFor({ timeout: 60_000 });
      await onStep("onb-provider-pick", page);
      // Gmail, because it is the row a real user is most likely to take and the
      // one whose steps are longest — the worst layout case of the five.
      await page.getByTestId("provider-pick-gmail").click();
      await settle(page, 300);
      if (inbound === null && (await page.getByTestId("inbound-address").count()) > 0) {
        inbound = (await page.getByTestId("inbound-address").textContent()).trim();
      }
      await onStep("onb-forwarding-steps", page);
      await page.getByRole("button", { name: /^I have set up forwarding$/i }).click();
    } else if ((await pick.count()) > 0) {
      // The address skip carries the forwarding step with it, so reaching the
      // picker at all means only the forwarding half was skippable from here.
      await onStep("onb-provider-pick", page);
      await page.getByRole("button", { name: /^Set this up later$/i }).click();
    }
  }

  /*
   * The hand-off. There is no home-currency step any more: that ceremony is
   * Settings' (it is the one irreversible choice in the product, and the end of
   * a corridor is the worst place to ask for one), and the money plan is an
   * app-shell banner rather than a control on this screen.
   */
  await page.getByTestId("onboarding-finish").waitFor({ timeout: 60_000 });
  await onStep("onb-finish", page);
  await page.getByRole("button", { name: /^Open ledger$/i }).click();

  const loops = await reachShell(page);
  await settle(page, 600);

  /*
   * The inbound address, from the SERVER rather than from whichever screen
   * happened to print it.
   *
   * It used to be scraped off the address/forwarding screen, which worked only
   * because every walk passed one. Two things ended that: `boot` reads
   * `GET /api/v1/address` and that read MINTS the address, so a healthy stack
   * walks straight past the address phase; and the skip path now goes from the
   * route screen to the hand-off without a screen carrying the address at all.
   * A runner that needs somewhere to post mail (`v2settings.mjs`) was handed
   * `null` and failed at the SMTP call, several steps away from the cause.
   *
   * `/api/v1/address` is the same route boot reads and is idempotent after the
   * first mint, so asking again costs nothing and cannot disagree with what the
   * walk was shown. Best-effort: a runner that does not need it must not fail
   * here.
   */
  if (inbound === null) {
    inbound = await page
      .evaluate(async () => {
        // The bearer the app itself uses. `webSecretStore(PROFILE)` is
        // localStorage under `ledger-v2:<profile>:<key>`, and the key is
        // `client/src/store/sqlite.ts`'s `SECRET_SESSION`. Read rather than
        // re-derived: a second way to mint a token would be a second thing to
        // keep in step with sign-in.
        const token = localStorage.getItem("ledger-v2:ledger:session_token");
        if (token === null || token === "") return null;
        const res = await fetch("/api/v1/address", {
          headers: { accept: "application/json", authorization: `Bearer ${token}` },
        });
        if (!res.ok) return null;
        const body = await res.json();
        return typeof body.address === "string" ? body.address : null;
      })
      .catch(() => null);
  }

  return { phrase, inbound, loops };
}

/**
 * The Gmail mailbox connect sub-flow (spec §3, D11) — the ONLY real-browser
 * exercise of the connect ceremony the feature has (everything else is
 * vitest/jsdom). It is reached only under `--gmail-fixtures`.
 *
 * The tap on "Connect with Google" is what opens the popup, and it must open
 * INSIDE the gesture — the Task 14 WebKit fix. Playwright's click is a real user
 * activation, so `window.open` succeeds; the popup then navigates to fakegmail's
 * consent page, is auto-approved, redirects through the server callback, and the
 * callback page broadcasts the claim on the origin-scoped BroadcastChannel. This
 * walk never has to touch the popup: it waits for the app to reach the backfill
 * screen, which it only does once a refresh token is sealed on this device.
 *
 * Returns true once the catching-up confirmation's Continue has advanced the
 * walk to the currency step. Throws — loudly, with the on-screen reason — if the
 * connect ends in the error state instead, because a silent failure here is a
 * connect ceremony that looks connected and holds nothing.
 */
async function walkMailboxConnect(page, onStep) {
  await page.getByTestId("mail-route-mailbox").click();

  await page.getByTestId("mailbox-guidance").waitFor({ timeout: 60_000 });
  await onStep("mailbox-guidance", page);

  // The tap that opens the popup. Synchronous inside the gesture (Task 14): the
  // DEK was read on mount, so nothing awaits between here and window.open.
  await page.getByRole("button", { name: /^Connect with Google$/ }).click();

  // The ceremony resolves to the backfill screen; a failure resolves to the
  // error screen. Wait for whichever, and make the error the loud one.
  const backfill = page.getByTestId("mailbox-backfill");
  const error = page.getByTestId("mailbox-error");
  await Promise.race([
    backfill.waitFor({ timeout: 60_000 }).catch(() => {}),
    error.waitFor({ timeout: 60_000 }).catch(() => {}),
  ]);
  if ((await error.count()) > 0) {
    const why = await page.getByTestId("mailbox-error-notice").textContent().catch(() => "(no notice)");
    throw new Error(`mailbox connect landed on the error screen: ${String(why).trim().slice(0, 200)}`);
  }
  if ((await backfill.count()) === 0) {
    throw new Error("mailbox connect reached neither the backfill nor the error screen within 60s");
  }

  await onStep("mailbox-backfill", page);
  await page.getByRole("button", { name: /^Start catching up$/ }).click();

  await page.getByTestId("mailbox-catching-up").waitFor({ timeout: 60_000 });
  await onStep("mailbox-catching-up", page);
  await page.getByRole("button", { name: /^Continue$/ }).click();
  await settle(page, 400);
  return true;
}

/**
 * Wait for the product shell, and get there anyway when onboarding takes the
 * walk back.
 *
 * **"Open ledger" does not always open the ledger.** `done()` re-runs boot, which
 * re-derives every fact, and `forwardingDeclared` is derived from
 * `firstMailConfirmedAt` alone — "DEMONSTRATED, not remembered", in
 * `resumeFacts`'s own words. A user who pressed "I have set up forwarding" made
 * an in-memory fact that no reducer persists, so at the next boot the
 * `forwarding_configured` milestone is unmet, it is not in `skipped` either, and
 * `stepFor` walls on it. The finish screen hands them straight back to the step
 * they just completed.
 *
 * That is a product finding, not a harness problem, so this reports each loop
 * rather than papering over it — and then takes "Set this up later", which is the
 * one answer the walk does persist, so the rest of the run has a product to
 * measure. Returns the steps it was bounced back to.
 */
// The mail-stage ids (`mail-route`, and the mailbox sub-flow's `mailbox-*`) sit
// at the same `keys_secured` position as `address`. They are listed so a bounce
// back onto any of them after "Open ledger" is recognised as an onboarding step
// rather than an unknown screen (reachShell), the same reason `address` is here.
const ONBOARDING_STEP_IDS = [
  "forwarding",
  "provider-pick",
  "address",
  "bank",
  "mail-route",
  "mailbox-guidance",
  "mailbox-backfill",
  "mailbox-catching-up",
  // Kept although the walk no longer renders it: an old checkout, or a build
  // mid-rebase, still can — and a screen this list does not name is reported as
  // "unknown", which blames the harness for a product state it understands.
  "home-currency",
  "onboarding-recovery",
  "onboarding-finish",
];

/** Whichever of the two states the app has settled into, and what it is showing. */
async function whereAreWe(page) {
  return page.evaluate((stepIds) => {
    const shown = (el) => el !== null && el.getBoundingClientRect().width > 0;
    const settings = [...document.querySelectorAll("button")].find((b) => (b.getAttribute("aria-label") ?? b.textContent.trim()) === "Settings");
    if (shown(settings ?? null)) return { at: "shell" };
    const ids = [...document.querySelectorAll("[data-testid]")].filter((e) => shown(e)).map((e) => e.getAttribute("data-testid"));
    const step = stepIds.find((id) => ids.includes(id));
    if (step !== undefined) {
      return { at: "onboarding", step, heading: document.querySelector("h1")?.textContent.trim() ?? "" };
    }
    return { at: "unknown", ids: ids.slice(0, 12) };
  }, ONBOARDING_STEP_IDS);
}

async function reachShell(page, { attempts = 5 } = {}) {
  const loops = [];
  for (let attempt = 0; attempt < attempts; attempt++) {
    // Poll rather than race two waitFors: the onboarding screens carry a
    // per-step test id and no shared one, so there is no single locator that
    // means "still in onboarding" to wait on.
    let state = { at: "unknown" };
    for (let tick = 0; tick < 40; tick++) {
      state = await whereAreWe(page);
      if (state.at !== "unknown") break;
      await settle(page, 500);
    }
    if (state.at === "shell") return loops;
    if (state.at === "unknown") throw new Error(`neither the shell nor an onboarding step is on screen: ${JSON.stringify(state.ids)}`);

    // Landing back on the finish screen is the walk re-offering its exit, not a
    // bounce to a step already done — press its button and say nothing.
    if (state.step !== "onboarding-finish") {
      loops.push({ step: state.step, heading: state.heading });
    }

    const later = page.getByRole("button", { name: /^Set this up later$/i }).first();
    const open = page.getByRole("button", { name: /^Open ledger$/i }).first();
    if ((await later.count()) > 0) {
      console.log(`  !!  onboarding sent the walk back to "${state.heading}" (${state.step}) after Open ledger — taking "Set this up later"`);
      await later.click();
    } else if ((await open.count()) > 0) {
      await open.click();
    } else {
      throw new Error(`stuck at onboarding step "${state.step}" with no way forward`);
    }
    await settle(page, 1000);
  }
  throw new Error(`onboarding looped ${attempts} times without reaching the product`);
}

// ---------------------------------------------------------------------------
// Fixture data
// ---------------------------------------------------------------------------

/**
 * The hostile rows, as a bank would export them.
 *
 * Each one is here because it breaks a layout somewhere, and the comment says
 * where. Widths are quoted at the 390px viewport.
 */
const HOSTILE_ROWS = [
  // 73 characters — several times wider than a 390px viewport, so every surface
  // that shows a merchant has to wrap it or truncate it, and one that does
  // neither runs off the screen. The single most productive fixture in v1's seed.
  ["2026-08-01", "EMIRATES NBD DIRECT DEBIT COLLECTION SERVICES MIDDLE EAST FZ LLC DUBAI AE", "-1250.75", "Bills"],
  // The widest string the formatter emits: 9,999,999.99 is 12 glyphs plus AED.
  // Deliberately UNCATEGORISED, so it also reaches the review deck — that card
  // sizes one hero number and is the surface most likely to clip it.
  ["2026-08-02", "PROPERTY PURCHASE SETTLEMENT", "-9999999.99", ""],
  // Income, so the row renders the credit register and the sign flips.
  ["2026-08-02", "SALARY AUGUST", "28500.00", "Income"],
  // A category label long enough to wrap a chip and a filter pill.
  ["2026-08-03", "NOON.COM", "-89.00", "Shopping and online marketplaces"],
  // Sub-unit precision, which is where rounding shows.
  ["2026-08-03", "PARKING RTA", "-2.05", "Transport"],
  // Non-ASCII, which changes glyph width and line-breaking.
  ["2026-08-04", "مقهى العربية — Arabian Coffee House", "-34.50", "Eating out"],
  // A refund against a merchant that also has a debit, so the pair can be linked.
  ["2026-08-04", "NOON.COM", "45.00", "Shopping and online marketplaces"],
  // No category at all: this is what lands in the review deck.
  ["2026-08-05", "CARREFOUR MALL OF THE EMIRATES", "-312.40", ""],
  ["2026-08-05", "TALABAT", "-58.25", ""],
  ["2026-08-06", "DUBAI TAXI CORPORATION", "-27.00", ""],
  ["2026-08-06", "SPINNEYS MOTOR CITY", "-143.60", ""],
  ["2026-08-07", "NETFLIX.COM", "-56.00", ""],
  ["2026-08-07", "APPLE.COM/BILL", "-9.99", ""],
  ["2026-08-08", "ADNOC SERVICE STATION 1042", "-180.00", ""],
  ["2026-08-08", "STARBUCKS DIFC", "-24.00", ""],
  // Enough rows that the list scrolls and the review deck stacks.
  ["2026-08-09", "AMAZON.AE", "-215.30", ""],
  ["2026-08-09", "DEWA UTILITY BILL", "-430.00", ""],
  ["2026-08-09", "ETISALAT POSTPAID", "-315.00", ""],
];

/** A second file in a currency with no configured rate — the unset-FX path. */
const FOREIGN_ROWS = [
  ["2026-08-05", "UBER TRIP HELP.UBER.COM", "-18.40", ""],
  ["2026-08-06", "GITHUB.COM", "-4.00", ""],
];

function csv(rows) {
  const esc = (v) => (/[",]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
  return ["Date,Description,Amount,Category", ...rows.map((r) => r.map(esc).join(","))].join("\n") + "\n";
}

/**
 * Write fixture transactions by driving the app's own import screen.
 *
 * The screens read a projection of the op log, so there is no database to insert
 * into and no HTTP route that would author an op on a user's behalf. Import is
 * the one path a user has for bulk data, so it is the one the harness uses: no
 * backdoor exists, and building one would be a fixture that proves nothing about
 * the product.
 *
 * Must be called with the product shell on screen.
 */
export async function seed(page) {
  const dir = mkdtempSync(join(tmpdir(), "ledger-v2-fixtures-"));
  const files = [
    { path: join(dir, "statement-aed.csv"), body: csv(HOSTILE_ROWS), currency: "AED" },
    { path: join(dir, "statement-usd.csv"), body: csv(FOREIGN_ROWS), currency: "USD" },
  ];
  for (const f of files) writeFileSync(f.path, f.body);

  let imported = 0;
  for (const f of files) {
    await openSettings(page);
    // Not anchored: `HubRow` renders its label AND its value inside one button,
    // so the accessible name is "Import a statement" followed by whatever the
    // row currently says on the right.
    await page.getByRole("button", { name: /Import a statement/i }).first().click();
    await page.getByRole("dialog").waitFor({ timeout: 15_000 });
    await page.getByTestId("import-file").setInputFiles(f.path);
    await page.getByTestId("import-preview").waitFor({ timeout: 15_000 });

    // The currency field applies to the whole file; the second import is the
    // no-configured-rate case and has to say so.
    const currency = page.locator("#import-currency");
    await currency.fill(f.currency);
    await settle(page, 300);

    const commit = page.getByTestId("import-commit");
    if (await commit.isEnabled()) {
      await commit.click();
      await page.getByTestId("import-done").waitFor({ timeout: 20_000 });
      const said = await page.getByTestId("import-done").textContent();
      imported += Number(said.match(/^(\d+)/)?.[1] ?? 0);
    } else {
      // A refused batch is a finding about the importer, not something to work
      // around silently: the caller sees a smaller count than it asked for.
      const problems = await page.getByTestId("import-problems").textContent().catch(() => "(none listed)");
      console.log(`  !!  ${f.currency} import refused: ${problems.slice(0, 200)}`);
    }
    await page.keyboard.press("Escape");
    await settle(page, 300);
    await closeOverlay(page);
  }
  return { imported, files: files.map((f) => f.path) };
}

// ---------------------------------------------------------------------------
// Getting around
// ---------------------------------------------------------------------------

/**
 * Tap a bottom-nav tab.
 *
 * Matched by prefix, not exactly: `BottomNav` renames the Review tab to
 * "Review, 12 need review" the moment the badge is non-zero, so an exact match
 * worked in the first pass — when the imported rows had not yet folded into the
 * needs-review lane — and then could not find the tab in the second.
 */
export async function gotoTab(page, label) {
  await page.getByRole("button", { name: new RegExp(`^${label}(,|$)`) }).last().click();
  await settle(page, 500);
}

/**
 * Open Settings, or notice it is already open.
 *
 * Idempotent because it has to be: a caller that opens Settings twice used to
 * spend thirty seconds retrying a click on the TopBar gear while the open
 * panel's own `<h1>Settings</h1>` sat on top of it, and the error named the
 * heading rather than the cause.
 */
export async function openSettings(page) {
  const open = page.getByRole("heading", { name: "Settings", level: 1 });
  if ((await open.count()) === 0) {
    await page.getByRole("button", { name: "Settings" }).first().click();
  }
  await page.getByTestId("settings-sync").waitFor({ timeout: 30_000 });
  await settle(page, 500);
}

/**
 * Open the Transaction-mailbox Settings drill-in, or report it is not there.
 *
 * The row (`settings-row-mailbox`) is config-gated: it exists only when a broker
 * is deployed (spec §2.3), i.e. only under `--gmail-fixtures`. So this returns
 * `false` rather than throwing when the row is absent, which is what lets the
 * optional screen/sub entries below skip cleanly on the plain stack. On success
 * it leaves the drill-in (`mailbox-settings`) on screen. Settings must already be
 * open.
 */
export async function openMailboxDrillIn(page) {
  const row = page.getByTestId("settings-row-mailbox");
  if ((await row.count()) === 0) return false;
  await row.scrollIntoViewIfNeeded();
  await row.click();
  await page.getByTestId("mailbox-settings").waitFor({ timeout: 15_000 });
  // Wait for the grant-status query to SETTLE into one of the panel's terminal
  // states before returning. The drill-in mounts in a loading state and the
  // `readGrantStatus` query re-renders it a beat later, replacing the scroller
  // node — which drops `v2shoot`'s scroll tag mid-capture and reads as "the
  // scroll did nothing". Waiting for a terminal testid stabilises the DOM so the
  // capture measures and scrolls the same node.
  await page
    .locator(
      '[data-testid="mailbox-settings-never-connected"], [data-testid="mailbox-settings-connected-label"], ' +
        '[data-testid="mailbox-settings-error"], [data-testid="mailbox-settings-another-device"], ' +
        '[data-testid="mailbox-settings-reconnect"]',
    )
    .first()
    .waitFor({ timeout: 15_000 })
    .catch(() => {});
  await settle(page, 500);
  return true;
}

/**
 * Run the real connect ceremony from the Settings drill-in's never-connected
 * state — the reliable path to a connected mailbox in the harness.
 *
 * This is the SAME `connectMailbox` ceremony the onboarding route runs: the tap
 * on "Connect a transaction mailbox" opens the consent popup INSIDE the gesture
 * (the Task 14 WebKit fix), which navigates to fakegmail, is auto-approved,
 * returns through the server callback, and hands the claim back over the
 * origin-scoped BroadcastChannel. It resolves once the drill-in shows the active
 * state's connected label, which only appears after a refresh token is sealed on
 * this device. Settings must be open; leaves the drill-in on screen, connected.
 */
export async function connectMailboxFromSettings(page) {
  // Idempotent about the drill-in: a caller may have opened (and audited) it
  // already. Opening it a second time stacks a second panel, and the connect
  // button on the buried one then intercepts every click.
  if ((await page.getByTestId("mailbox-settings").count()) === 0) {
    if (!(await openMailboxDrillIn(page))) {
      throw new Error("connectMailboxFromSettings: no settings-row-mailbox — is the stack up with --gmail-fixtures?");
    }
  }
  await page.getByTestId("mailbox-settings-connect").click();
  await page.getByTestId("mailbox-settings-connected-label").waitFor({ timeout: 60_000 });
  await settle(page, 400);
  return (await page.getByTestId("mailbox-settings-connected-label").textContent()).trim();
}

/**
 * Back out of a full-screen drill-in (Settings, Held mail).
 *
 * The control is `IconButton label={`Back from ${title}`}` — not "Back", and not
 * "Close". Matching the shorter names found nothing, fell through to Escape,
 * which a `SettingsPage` does not listen for, and left the panel open over
 * whatever the next step tried to press.
 */
export async function closeOverlay(page) {
  // The TOP panel's back button, not the first in the DOM. With Held mail open
  // over Settings there are two, the buried one comes first, and clicking it
  // retries against the panel covering it until the timeout.
  const handles = await page.$$('button[aria-label^="Back from "]');
  let back = null;
  for (const handle of handles) {
    if (await handle.evaluate((el) => el.closest("[inert]") === null)) back = handle;
  }
  if (back === null) return;
  await back.click({ timeout: 10_000 });
  // The panel animates out and calls `onClose` on exit-complete, so the caller
  // must not race the unmount.
  await settle(page, 700);
}

/**
 * Every product surface, as taps.
 *
 * `open` is handed a page showing the Home tab with no overlay, and must leave
 * the named surface on screen. `reset` puts it back. Keeping the contract that
 * strict is what lets a runner iterate the list without the order mattering.
 */
export const SCREENS = [
  { id: "home", open: async (page) => gotoTab(page, "Home") },
  { id: "transactions", open: async (page) => gotoTab(page, "Transactions") },
  { id: "insights", open: async (page) => gotoTab(page, "Insights") },
  { id: "review", open: async (page) => gotoTab(page, "Review") },
  { id: "settings", open: async (page) => openSettings(page), reset: closeOverlay },
  {
    id: "held-mail",
    open: async (page) => {
      await openSettings(page);
      await page.getByRole("button", { name: /^Held mail/ }).first().click();
      await settle(page, 600);
    },
    reset: async (page) => {
      await closeOverlay(page);
      await closeOverlay(page);
    },
  },
  {
    // The Transaction-mailbox drill-in. `optional`: the row exists only where a
    // broker is deployed (--gmail-fixtures), so a runner on the plain stack must
    // skip it rather than fail. `open` returns "skip" when the row is absent, and
    // v2shoot honours that. Whichever mailbox STATE the account is in — the
    // never-connected offer, or the active connection — is the surface audited;
    // `mailbox.mjs` is the runner that connects first to capture the active one.
    id: "mailbox-settings",
    optional: true,
    // The panel re-renders while it is measured (a status effect that re-runs and
    // remounts its body) and resets its own scroll, so multi-segment capture
    // reads as "the scroll did nothing" on a screen that is fine. `audit()` still
    // measures the whole surface (it is scroll-independent), and `mailbox.mjs`
    // captures the connected/catch-up states in full. See v2shoot's `capture`.
    singleSegment: true,
    open: async (page) => {
      await openSettings(page);
      if (!(await openMailboxDrillIn(page))) {
        // Close the Settings hub this opened before bailing — a "skip" gets no
        // `reset`, and a left-open Settings covers the bottom nav the next screen
        // taps.
        await closeOverlay(page);
        return "skip";
      }
      return undefined;
    },
    reset: async (page) => {
      await closeOverlay(page);
      await closeOverlay(page);
    },
  },
];

/**
 * The dialogs Settings owns, by the label that opens each.
 *
 * Listed rather than crawled because the crawl cannot tell an opener from a
 * toggle, and pressing every button on Settings signs the harness out halfway
 * through. Order matches the screen.
 *
 * The matchers are **unanchored on purpose**: `HubRow` puts its label and its
 * current value inside one button, so the accessible name of the text-size row
 * is "Text size" followed by "Default". Anchoring matched nothing and the whole
 * dialog sweep silently covered zero screens.
 */
export const SETTINGS_DIALOGS = [
  { id: "text-size", match: /^Text size/ },
  { id: "import", match: /Import a statement/ },
  { id: "export", match: /Download my data/ },
  { id: "categories", match: /Your categories/ },
  // `via` walks a drill-in first. Settings became a list of one-line rows on
  // 2026-08-10, so a control that used to sit in an expanded panel now lives one
  // screen in — the sweep has to make the same two taps a person makes, and
  // reported "no row matching" until it did.
  { id: "mail-check", match: /^Check my mail setup$/, via: /^Is mail arriving\?/ },
  { id: "forwarding", match: /Forwarding instructions/ },
  // Only rendered while no home currency is set — it is a one-shot ceremony and
  // the row is gone once it has been used. `optional` says so, rather than the
  // sweep reporting a missing row every run against a configured account.
  // Since the Gmail-primary rework this is the ONLY place the ceremony exists:
  // it left the walk, so a freshly-ceremonied account always has this row.
  { id: "home-currency", match: /^Set my home currency$/, via: /^Home currency/, optional: true },
  { id: "add-device", match: /Add a device/, via: /^Other devices/ },
  { id: "delete-account", match: /Delete account/ },
  { id: "sign-out", match: /^Sign out/ },
];

/**
 * Open every `InfoTip` on the current screen and report where its panel landed.
 *
 * This is the check the operator asked for by name. The panel is width-capped to
 * the viewport but positioned against its **trigger**, so a tip on a control near
 * the right edge opens past it — a defect no unit test can see, because jsdom has
 * no layout and every rectangle it reports is zero.
 *
 * Returns one row per tip: the trigger's accessible name, the panel's measured
 * box, and whether it stayed inside the viewport and clear of the bottom nav.
 */
export async function measureInfoTips(page) {
  /*
   * Only the live layer. Drill-ins STACK — Held mail opened from Settings leaves
   * Settings mounted underneath — and `AppShell` takes the covered layer out of
   * the tab order with `inert` rather than unmounting it. An inert button is
   * still laid out and still passes `isVisible()`, so the first version of this
   * spent thirty seconds retrying a click on Settings' plan tip through the Held
   * mail panel sitting on top of it.
   */
  /*
   * When a Dialog is open, only the tips INSIDE it count.
   *
   * Since `Dialog` gained `useInertBackground` the filter below would catch
   * these on its own — the page beneath a sheet is inert now, and `audit.mjs`
   * no longer reports `background-layer-not-inert` on the Settings dialogs. The
   * explicit scope stays because it says what this crawler means rather than
   * inheriting it: a tip reached through an open sheet is a click on the scrim,
   * so the sheet closes, no panel opens, and the run fills with "opened no
   * panel" for a control the user could never have pressed.
   */
  const dialog = await page.$('[role="dialog"]');
  const scope = dialog ?? page;
  const handles = await scope.$$('button[aria-label^="About "]');
  const triggers = [];
  for (const handle of handles) {
    const live = await handle.evaluate((el) => {
      const r = el.getBoundingClientRect();
      return el.closest("[inert]") === null && r.width > 0 && r.height > 0;
    });
    if (live) triggers.push(handle);
  }

  const rows = [];
  for (const trigger of triggers) {
    const about = await trigger.getAttribute("aria-label");
    await trigger.scrollIntoViewIfNeeded().catch(() => {});
    try {
      // Short, because a tip that cannot be pressed is itself the finding and
      // thirty seconds of retries buries it in a wall of Playwright log.
      await trigger.click({ timeout: 5000 });
    } catch {
      rows.push({ about, opened: false, unreachable: true });
      continue;
    }
    await settle(page, 250);
    const measured = await page.evaluate(() => {
      // Same reason as the trigger filter: a note left open on a buried layer
      // would be measured instead of the one just opened.
      const panel = [...document.querySelectorAll('[role="note"]')].find((el) => el.closest("[inert]") === null) ?? null;
      if (panel === null) return null;
      const r = panel.getBoundingClientRect();
      /*
       * "Covered" is measured, not inferred from the bottom nav's box.
       *
       * Overlapping the nav's rectangle is only a defect when the nav actually
       * paints on top: inside a Dialog the sheet is above the nav, so a panel
       * that crosses that line is still perfectly visible. Sampling what is
       * really at the panel's bottom edge answers the question the box cannot.
       */
      const probeY = Math.min(r.bottom - 2, window.innerHeight - 1);
      const hit = document.elementFromPoint(Math.min(Math.max(r.left + r.width / 2, 0), window.innerWidth - 1), Math.max(probeY, 0));
      const coveredBy = hit === null || panel.contains(hit) ? null : (hit.closest("nav") !== null ? "bottom nav" : hit.tagName.toLowerCase());
      return {
        left: Math.round(r.left),
        right: Math.round(r.right),
        top: Math.round(r.top),
        bottom: Math.round(r.bottom),
        vw: document.documentElement.clientWidth,
        vh: document.documentElement.clientHeight,
        coveredBy,
      };
    });
    if (measured === null) {
      rows.push({ about, opened: false });
    } else {
      const overflowRight = Math.max(0, measured.right - measured.vw);
      const overflowLeft = Math.max(0, -measured.left);
      const overflowBottom = Math.max(0, measured.bottom - measured.vh);
      rows.push({
        about,
        opened: true,
        ...measured,
        overflowRight,
        overflowLeft,
        overflowBottom,
        ok: overflowRight === 0 && overflowLeft === 0 && overflowBottom === 0 && measured.coveredBy === null,
      });
      await page.keyboard.press("Escape");
      await settle(page, 200);
    }
  }
  return rows;
}
