/**
 * The Settings drill-ins, screenshotted and audited.
 *
 * `v2shoot.mjs` walks Settings and its dialogs; these are neither. Since the
 * 2026-08-10 restructure every subject that needs a paragraph is a screen behind
 * a one-line row, so the prose this app is careful about — the recovery warning,
 * what removing a bank does not do, the home currency's permanence — is now
 * exactly where nothing was looking.
 *
 *   harness/v2stack.sh up
 *   bun harness/v2subs.mjs <invite-code>
 */

import { mkdirSync } from "node:fs";
import { chromium } from "playwright";

import { audit, summarize } from "./audit.mjs";
import { ceremony, closeOverlay, newSignedOutContext, openSettings, seed, settle } from "./v2nav.mjs";

const HERE = new URL(".", import.meta.url).pathname;
const OUT = `${HERE}shots/`;
const INVITE = process.argv[2];
if (!INVITE) {
  console.error("usage: bun harness/v2subs.mjs <invite-code>");
  process.exit(2);
}

/**
 * Every row that opens a drill-in, by the label a person taps.
 *
 * `testid`/`optional` handle the Transaction-mailbox row: it is config-gated to a
 * broker deployment (spec §2.3), so on the plain stack it is absent and the run
 * skips it rather than failing. Under `--gmail-fixtures` it opens the drill-in in
 * whatever mailbox state the fresh account is in (never-connected here — the
 * `mailbox.mjs` runner is the one that connects first).
 */
const SUBS = [
  { id: "plan", row: /^Plan/ },
  { id: "currency", row: /^Home currency/ },
  { id: "address", row: /^Your address/ },
  { id: "mail", row: /^Is mail arriving\?/ },
  { id: "banks", row: /^Your banks/ },
  { id: "passkeys", row: /^Passkeys/ },
  { id: "devices", row: /^Other devices/ },
  { id: "mailbox", testid: "settings-row-mailbox", optional: true },
];

let failed = false;

const browser = await chromium.launch();
mkdirSync(`${OUT}subs`, { recursive: true });

try {
  const { page } = await newSignedOutContext(browser, {});
  page.on("pageerror", (e) => {
    failed = true;
    console.error("  PAGE ERROR:", e.message);
  });
  await ceremony(page, INVITE, {});
  await seed(page);
  await openSettings(page);

  for (const { id, row, testid, optional } of SUBS) {
    const opener = testid !== undefined ? page.getByTestId(testid) : page.getByRole("button", { name: row }).first();
    if ((await opener.count()) === 0) {
      if (optional) {
        console.log(`  --  ${id} — not present in this deployment (optional)`);
        continue;
      }
      failed = true;
      console.log(`FAIL  ${id} — no row matching ${testid ?? row} on Settings`);
      continue;
    }
    await opener.scrollIntoViewIfNeeded();
    await opener.click();
    await settle(page, 600);

    // The drill-in's own heading proves the row opened the screen it names.
    const heading = await page.locator("h1").last().textContent();
    await page.screenshot({ path: `${OUT}subs/${id}.png` });

    const result = await audit(page);
    const bad = result.issues.filter((i) => i.severity === "high" || i.severity === "medium");
    if (bad.length === 0) {
      console.log(`  ok  ${id} — "${heading?.trim()}" clean (${result.issues.length} low)`);
    } else {
      failed = true;
      console.log(`FAIL  ${id} — "${heading?.trim()}"`);
      for (const s of summarize(bad)) {
        console.log(`        ${s.severity} ${s.kind} ×${s.count}`);
        for (const e of s.examples.slice(0, 2)) console.log(`          ${e.el} — ${e.detail}`);
      }
    }
    await closeOverlay(page);
    await settle(page, 300);
  }
} finally {
  await browser.close();
}

process.exitCode = failed ? 1 : 0;
