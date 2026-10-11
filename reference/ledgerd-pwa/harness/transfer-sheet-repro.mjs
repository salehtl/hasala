/**
 * The Transfer rail's sheet, photographed — a targeted repro, not a runner.
 *
 * Reported 2026-08-16: pulling a card to Transfer opens the category sheet and
 * there is nothing in it to pick. Two causes, both in `deckCategories`: the
 * excluded set was ONE name, "Transfer", which is the rail's own label; and any
 * used name shadowed it, so one Transfer sort emptied the rail for good.
 *
 * This signs up, imports the hostile fixtures, sorts one card into Transfer,
 * and comes back to the same rail — the exact sequence that used to empty it.
 * It asserts nothing beyond "the sheet has buttons": read the shots.
 *
 *   LEDGER_HARNESS_ORIGIN=http://localhost:5197 bun harness/transfer-sheet-repro.mjs <invite>
 */

import { mkdirSync } from "node:fs";
import { chromium } from "playwright";

import { ceremony, gotoTab, newSignedOutContext, seed, settle } from "./v2nav.mjs";

const HERE = new URL(".", import.meta.url).pathname;
const OUT = `${HERE}shots/`;
const INVITE = process.argv[2];
if (!INVITE) {
  console.error("usage: bun harness/transfer-sheet-repro.mjs <invite-code>");
  process.exit(2);
}

/** Every button inside the open sheet's excluded grid. */
async function sheetOptions(page) {
  return page.evaluate(() => {
    const dialog = document.querySelector('[role="dialog"]');
    if (dialog === null) return null;
    const group = dialog.querySelector('[data-testid="excluded-group"]');
    return {
      title: dialog.querySelector("h2,h3")?.textContent?.trim() ?? "",
      excluded: group === null ? [] : [...group.querySelectorAll("button")].map((b) => b.textContent.trim()),
    };
  });
}

const browser = await chromium.launch();
const { context, page } = await newSignedOutContext(browser, { viewport: "phone" });
mkdirSync(OUT, { recursive: true });

await ceremony(page, INVITE);
await seed(page);
await gotoTab(page, "Review");
await settle(page, 800);

// 1. The rail, on an account that has never sorted a transfer.
await page.getByRole("button", { name: /^Transfer — sort this transaction/ }).click();
await settle(page, 600);
console.log("fresh account:", JSON.stringify(await sheetOptions(page)));
await page.screenshot({ path: `${OUT}transfer-sheet-fresh.png` });

// 2. Sort this card as a Transfer, which puts "Transfer" in the used names.
await page.getByRole("button", { name: "Transfer", exact: true }).click();
await settle(page, 1200);

// 3. Same rail, next card. This is where the sheet used to be empty.
await page.getByRole("button", { name: /^Transfer — sort this transaction/ }).click();
await settle(page, 600);
console.log("after one transfer sort:", JSON.stringify(await sheetOptions(page)));
await page.screenshot({ path: `${OUT}transfer-sheet-after-use.png` });

await context.close();
await browser.close();
