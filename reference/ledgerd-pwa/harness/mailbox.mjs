/**
 * The Gmail transaction-mailbox connect ceremony, driven in a real browser
 * against the fake Google/Gmail (`--gmail-fixtures`).
 *
 *   harness/v2stack.sh up --gmail-fixtures      # prints an invite
 *   bun harness/mailbox.mjs <invite>           # Chromium: connect + drill-in + catch-up
 *   bun harness/mailbox.mjs <invite> webkit    # WebKit: the popup-in-gesture fix (Task 14)
 *
 * # What it proves that vitest cannot
 *
 * Every other check on this feature is vitest/jsdom, which has no popup, no
 * BroadcastChannel across a browsing-context-group switch, and no real
 * `window.open`. This is the ONLY exercise of the live ceremony:
 *
 *   the tap opens the consent popup INSIDE the gesture (the Task 14 WebKit fix)
 *   → the popup navigates to fakegmail's consent page → auto-approve → the server
 *   callback mints a claim → the callback page broadcasts it on the origin-scoped
 *   channel → the app claims, seals the refresh token, and shows the connected
 *   burner address decoded from the id_token.
 *
 * It connects from the SETTINGS drill-in's never-connected state, which runs the
 * identical `connectMailbox` ceremony the onboarding route does. (The onboarding
 * `mail-route` screen is gated on a `mailboxConfigured` probe that, in this dev
 * harness, resolves false on its first onboarding mount — see the Task 16 report
 * — so Settings is the reliable entry; the ceremony code exercised is the same.)
 *
 * # WebKit
 *
 * WebKit is the primary PWA platform and the one the popup-in-gesture fix is FOR:
 * it drops the tap's user activation across an await, so a popup opened after one
 * is blocked. Playwright cannot give WebKit a CDP virtual authenticator, so this
 * signs in with `webauthn.mjs`'s software ES256 authenticator (as `operator.mjs`
 * does) and then drives the same Settings connect. A WebKit run that reaches the
 * connected label is the fix verified on the engine that needed it.
 */

import { chromium, webkit } from "playwright";

import { audit, summarize } from "./audit.mjs";
import { ceremony, connectMailboxFromSettings, newSignedOutContext, openMailboxDrillIn, openSettings, settle } from "./v2nav.mjs";
import { authenticatorScript } from "./webauthn.mjs";

const ORIGIN = process.env.LEDGER_HARNESS_ORIGIN ?? "http://localhost:5177";
const RP_ID = process.env.LEDGER_HARNESS_RP_ID ?? "localhost";
const STATE_DIR = process.env.LEDGER_HARNESS_DIR ?? "/tmp/ledger-v2-harness";
const GMAIL_PORT = process.env.LEDGER_V2_GMAIL_PORT ?? "2527";
const FAKE_GMAIL = `http://127.0.0.1:${GMAIL_PORT}`;
const OUT = new URL(".", import.meta.url).pathname + "shots/mailbox/";

const INVITE = process.argv[2];
const ENGINE = process.argv[3] === "webkit" ? "webkit" : "chromium";
if (!INVITE) {
  console.error("usage: bun harness/mailbox.mjs <invite> [webkit]");
  process.exit(2);
}

let failed = false;
const ok = (w, d = "") => console.log(`  ok    ${w}${d ? ` — ${d}` : ""}`);
const bad = (w, d = "") => {
  console.error(`  FAIL  ${w}${d ? ` — ${d}` : ""}`);
  failed = true;
};

/**
 * Route the browser's Gmail REST calls to fakegmail. The client hard-codes
 * `gmail.googleapis.com` (web/src/v2/mailbox/gmail.ts) and CSP fences the fetch
 * to exactly those paths, so the harness cannot inject a base URL — it fulfils
 * the request from fakegmail at the network layer instead, which is the one seam
 * that lets the fetch lane run offline against the synthetic mailbox.
 */
async function routeGmailToFake(context) {
  await context.route("https://gmail.googleapis.com/**", async (route) => {
    const url = new URL(route.request().url());
    const target = FAKE_GMAIL + url.pathname + url.search;
    try {
      const res = await fetch(target, { method: route.request().method(), headers: { Authorization: "Bearer harness" } });
      const body = await res.text();
      await route.fulfill({ status: res.status, contentType: res.headers.get("content-type") ?? "application/json", body });
    } catch (err) {
      await route.abort();
    }
  });
}

async function auditScreen(page, where) {
  const result = await audit(page);
  const bads = result.issues.filter((i) => i.severity === "high" || i.severity === "medium");
  if (bads.length === 0) {
    ok(`geometry clean: ${where}`, `${result.issues.length} low`);
  } else {
    bad(`geometry findings: ${where}`);
    for (const s of summarize(bads)) console.log(`        ${s.severity} ${s.kind} ×${s.count} — ${s.examples[0]?.detail ?? ""}`);
  }
}

async function run() {
  const { mkdirSync } = await import("node:fs");
  mkdirSync(OUT, { recursive: true });

  let context, page, browser;
  if (ENGINE === "webkit") {
    // The engine the popup-in-gesture fix is for, with a software authenticator
    // because Playwright's virtual one is Chromium-only.
    context = await webkit.launchPersistentContext(`${STATE_DIR}/webkit-mailbox-profile`, {
      viewport: { width: 390, height: 844 },
    });
    await context.addInitScript(authenticatorScript(RP_ID));
    page = context.pages()[0] ?? (await context.newPage());
  } else {
    browser = await chromium.launch();
    ({ context, page } = await newSignedOutContext(browser, { viewport: "phone", colorScheme: "light" }));
  }
  page.on("pageerror", (e) => bad("page error", e.message));

  try {
    // Sign up and walk to the product shell (forward route — the reliable entry).
    await ceremony(page, INVITE, { mailRoute: "forward" });
    ok(`signed up and reached the shell (${ENGINE})`);

    await openSettings(page);
    if (!(await openMailboxDrillIn(page))) {
      bad("the Transaction-mailbox row is present", "no settings-row-mailbox — is the stack up with --gmail-fixtures?");
      return;
    }
    await auditScreen(page, "drill-in (never connected)");
    await page.screenshot({ path: `${OUT}${ENGINE}-1-never-connected.png` });

    // The ceremony: the tap opens the popup inside the gesture.
    const label = await connectMailboxFromSettings(page).catch((e) => {
      bad("the connect ceremony completed", e.message);
      return null;
    });
    if (label === null) {
      await page.screenshot({ path: `${OUT}${ENGINE}-connect-fail.png` }).catch(() => {});
      return;
    }
    if (!/Connected as .+@/.test(label)) bad("the connected label shows the burner address", `got ${JSON.stringify(label)}`);
    else ok("connected, and the id_token email is on the glass", label);
    await auditScreen(page, "drill-in (active)");
    await page.screenshot({ path: `${OUT}${ENGINE}-2-connected.png` });

    // Catch up now — the fetch lane, offline against fakegmail via routing.
    // Best-effort: templates are not seeded on this scratch DB, so the synthetic
    // bank mail lands as needs-review rather than filed, which is still a full
    // pass through the lane. Chromium only (routing on the persistent context).
    if (ENGINE === "chromium") {
      await routeGmailToFake(context);
      const catchup = page.getByTestId("mailbox-settings-catchup");
      if ((await catchup.count()) > 0) {
        await catchup.click();
        const summary = page.getByTestId("mailbox-settings-catchup-summary");
        await summary.waitFor({ timeout: 30_000 }).catch(() => {});
        if ((await summary.count()) > 0) {
          ok("catch-up ran a real fetch cycle against fakegmail", (await summary.textContent()).replace(/\s+/g, " ").trim().slice(0, 80));
          await page.screenshot({ path: `${OUT}${ENGINE}-3-catchup.png` });
        } else {
          console.log("  --    catch-up produced no summary (fetch lane not exercised); see the report");
        }
        await auditScreen(page, "drill-in (after catch-up)");
      }
    }

    ok(`mailbox connect verified on ${ENGINE}`);
  } finally {
    if (browser) await browser.close();
    else await context.close();
  }
}

await run();
process.exitCode = failed ? 1 : 0;
