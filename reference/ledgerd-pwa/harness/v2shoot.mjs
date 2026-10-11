/**
 * Screenshot and geometry-audit every v2 screen, at two widths and both themes.
 *
 *   harness/v2stack.sh up            # prints an invite
 *   bun harness/v2shoot.mjs <invite-code>
 *
 * # One account, four passes
 *
 * The ceremony is the expensive part — an account, a key set, a walk through six
 * screens — and it produces per-context state (IndexedDB, a resident credential)
 * that a second context does not inherit. So it runs **once**, and the passes
 * that follow resize the viewport and swap the colour scheme on the same page.
 * That keeps the fixture data identical across passes, which is what makes the
 * 320px findings comparable to the 390px ones instead of a different app.
 *
 * # What each pass measures
 *
 * `audit.mjs` in-page, which reports geometric facts and no opinions: content
 * past the viewport edge, a control whose centre point hits a different element,
 * a control under the fixed bottom nav, sub-44px targets, sub-16px inputs,
 * `overflow-hidden` over taller content, a literal `NaN` on the glass.
 *
 * Plus one check this file adds, because the operator asked for it by name:
 * every `InfoTip` is opened and its panel measured against the viewport. The
 * panel is width-capped but **trigger-anchored**, so one opened from a control
 * near the right edge runs off the screen. See {@link measureInfoTips}.
 *
 * # Onboarding is audited on the way past
 *
 * Those six screens are unreachable once the walk finishes — there is no route
 * back to them — so the capture hook fires while each is still on the glass.
 * They are also where a new user's impression forms, so they are not optional.
 *
 * The judgement calls geometry cannot make — hierarchy, rhythm, copy, whether a
 * screen looks finished — are left to whoever reads `shots/`.
 */

import { mkdirSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { chromium } from "playwright";

import { audit, summarize } from "./audit.mjs";
import { ceremony, closeOverlay, gotoTab, measureInfoTips, newSignedOutContext, openSettings, seed, settle, SCREENS, SETTINGS_DIALOGS, VIEWPORTS } from "./v2nav.mjs";

const HERE = new URL(".", import.meta.url).pathname;
const OUT = `${HERE}shots/`;
const INVITE = process.argv[2];
if (!INVITE) {
  console.error("usage: bun harness/v2shoot.mjs <invite-code>");
  process.exit(2);
}

const only = process.argv.includes("--screens") ? process.argv[process.argv.indexOf("--screens") + 1].split(",") : null;
const PASSES = process.argv.includes("--fast")
  ? [{ id: "phone-light", viewport: "phone", scheme: "light" }]
  : [
      { id: "phone-light", viewport: "phone", scheme: "light" },
      { id: "phone-dark", viewport: "phone", scheme: "dark" },
      { id: "small-light", viewport: "small", scheme: "light" },
    ];

const findings = [];
const tips = [];
let failed = false;

function report(pass, label, result) {
  const bad = result.issues.filter((i) => i.severity === "high" || i.severity === "medium");
  findings.push({ pass, label, counts: result.counts, issues: summarize(result.issues) });
  if (bad.length === 0) {
    console.log(`  ok  ${pass}/${label} — clean (${result.issues.length} low)`);
    return;
  }
  failed = true;
  console.log(`FAIL  ${pass}/${label} — ${bad.length} finding(s)`);
  for (const s of summarize(bad)) {
    console.log(`        ${s.severity} ${s.kind} ×${s.count}`);
    for (const e of s.examples.slice(0, 3)) console.log(`          ${e.el} — ${e.detail}`);
  }
}

/**
 * The element that actually scrolls — the LARGEST overflow, tagged in place so
 * the scroll and the measurement cannot pick different elements.
 *
 * `v2settings.mjs`'s first version took the first scrollable element it found,
 * which was an inner 816px one, and then reported a clean 2983px screen it had
 * never scrolled. This is that file's rule, verbatim.
 */
async function scrollInfo(page) {
  return page.evaluate(() => {
    let best = null;
    for (const el of document.querySelectorAll("*")) {
      if (!["auto", "scroll"].includes(getComputedStyle(el).overflowY)) continue;
      // Never a buried layer's scroller. Drill-ins stack and the covered panel
      // stays mounted behind `inert`, so the tallest scroller on the page can
      // easily belong to the screen the user cannot see — which is how Held
      // mail produced six byte-identical "segments" of a screen never scrolled.
      if (el.closest("[inert]") !== null) continue;
      const over = el.scrollHeight - el.clientHeight;
      if (over > 8 && (!best || over > best.over)) {
        document.querySelector("[data-harness-scroller]")?.removeAttribute("data-harness-scroller");
        best = { over, height: el.clientHeight, total: el.scrollHeight };
        el.setAttribute("data-harness-scroller", "1");
      }
    }
    const doc = document.scrollingElement;
    const over = doc.scrollHeight - doc.clientHeight;
    if (!best && over > 8) return { kind: "document", over, height: doc.clientHeight, total: doc.scrollHeight };
    return best ? { kind: "element", ...best } : { kind: "none", over: 0, height: 0, total: 0 };
  });
}

/**
 * Scroll the element {@link scrollInfo} tagged, and say whether it was there.
 *
 * The tag can vanish between the measurement and the scroll: a re-render
 * replaces the node it was set on, and React does that for reasons that have
 * nothing to do with the harness — a colour-scheme swap, a query landing. This
 * threw `Cannot set properties of null` on the first screen of the second pass
 * and took the whole sweep down with it, two thirds of the way through, at a
 * point where nothing was wrong with the app.
 *
 * It reports instead of throwing. That cannot hide a broken scroll: every
 * segment would then be byte-identical, which {@link capture} already fails on.
 */
async function scrollTo(page, kind, y) {
  const scrolled = await page.evaluate(
    ([kind, y]) => {
      const el = kind === "document" ? document.scrollingElement : document.querySelector("[data-harness-scroller]");
      if (el === null) return false;
      el.scrollTop = y;
      return true;
    },
    [kind, y],
  );
  await page.waitForTimeout(250);
  return scrolled;
}

/**
 * One screenshot, with room to breathe and one retry.
 *
 * The default 30s is tight on this box: it has under 4GB of RAM shared with
 * Postgres, vite, a Chromium that has been open for ten minutes and both
 * production services, and a single slow frame took a whole three-pass sweep
 * down at the twenty-eighth screen with `Timeout 30000ms exceeded … fonts
 * loaded`. Nothing was wrong with the app.
 *
 * A retry here cannot hide a defect: a screenshot is a capture, not a check.
 * The checks are `audit`, the tip measurements and the identical-segments rule,
 * and all three still run against whatever the retry produces. A screenshot that
 * fails TWICE still fails the run rather than being skipped quietly.
 */
async function shoot(page, path) {
  try {
    return await page.screenshot({ path, timeout: 60_000 });
  } catch (err) {
    console.log(`  !!  ${path.split("/").slice(-2).join("/")} — screenshot timed out, retrying once`);
    await settle(page, 1500);
    return page.screenshot({ path, timeout: 60_000 });
  }
}

/** Capture the scrolling container in viewport-sized segments, auditing each. */
async function capture(page, pass, name, { singleSegment = false } = {}) {
  const info = await scrollInfo(page);
  // `singleSegment` is for a surface that RE-RENDERS while it is measured and
  // resets its own scroll on every render — the mailbox drill-in, whose status
  // effect re-runs and remounts its body, so a scrollTop set for one segment is
  // back at 0 by the time the shot lands and the identical-segments guard fires
  // on a screen that is not actually broken. audit() measures the whole screen
  // regardless of scroll, so nothing below the fold goes unchecked; only the
  // extra screenshots are dropped. Every OTHER screen keeps the full guard.
  const segments = info.kind === "none" || singleSegment ? 1 : Math.min(8, Math.ceil(info.total / info.height));
  const seen = new Set();
  for (let i = 0; i < segments; i++) {
    if (info.kind !== "none" && !singleSegment) await scrollTo(page, info.kind, i * info.height);
    const shot = await shoot(page, `${OUT}${pass}/${name}.${i}.png`);
    seen.add(shot.length);
    // Audit at each scroll position, not only at the top: a control under the
    // bottom nav is usually one at the END of a long screen.
    if (i > 0) report(pass, `${name} @${i}`, await audit(page));
  }
  if (segments > 1 && seen.size === 1) {
    failed = true;
    console.log(`FAIL  ${pass}/${name} — ${segments} segments captured but every one is identical; the scroll did nothing`);
  }
  if (info.kind !== "none" && !singleSegment) await scrollTo(page, info.kind, 0);
  return { ...info, segments };
}

async function tipsOn(page, pass, where) {
  const rows = await measureInfoTips(page);
  for (const row of rows) {
    tips.push({ pass, where, ...row });
    if (row.opened === false) {
      failed = true;
      console.log(`FAIL  ${pass}/${where} — "${row.about}" opened no panel`);
    } else if (!row.ok) {
      failed = true;
      console.log(
        `FAIL  ${pass}/${where} — "${row.about}" panel ${row.left}..${row.right} in a ${row.vw}px viewport` +
          `${row.overflowRight > 0 ? ` — ${row.overflowRight}px past the right edge` : ""}` +
          `${row.overflowLeft > 0 ? ` — ${row.overflowLeft}px past the left edge` : ""}` +
          `${row.overflowBottom > 0 ? ` — ${row.overflowBottom}px below the viewport` : ""}` +
          `${row.coveredBy !== null ? ` — covered by the ${row.coveredBy}` : ""}`,
      );
    } else {
      console.log(`  ok  ${pass}/${where} — "${row.about}" panel ${row.left}..${row.right} inside ${row.vw}px`);
    }
  }
}

/**
 * One Settings dialog: walk to it, capture it, and put the screen back.
 *
 * # Why this is a function and not the body of the loop it replaced
 *
 * It has five ways to end early — an absent row, an absent opener, an opener
 * that opens nothing — and the drill-in some of these controls live behind has
 * to be unwound on **every** one of them. Written as a loop body with `continue`
 * it was not: the `continue` for an optional row that is not offered jumped
 * clean over the `closeOverlay` at the bottom, so the drill-in it had just
 * walked into stayed open. The next entry then looked for its row on Settings
 * while a full-screen panel covered it, Playwright retried the click against
 * that panel until it timed out, and the run died there — before add-device,
 * delete-account and sign-out, before the 320px pass and before the dark one.
 * A sweep that stops two thirds of the way through while reporting nothing
 * wrong is this repo's most repeated defect wearing a different hat.
 *
 * So the unwind lives in a `finally` and the early exits are `return`s. There is
 * no path out of this function that leaves a drill-in on the glass.
 */
async function sweepDialog(page, pass, { id: dialogId, match, via, optional = false }) {
  // Re-assert Settings BEFORE walking any drill-in. Closing a sheet can take the
  // panel underneath with it — Escape reaches more than one listener, and the tip
  // inside a sheet has its own — and the symptom is six rows in a row "not on
  // Settings" when what is not there is Settings. Ordering it ahead of the `via`
  // walk matters: with it after, a closed Settings made the drill-in row silently
  // unfindable and the entry failed naming the wrong control. `openSettings` is
  // idempotent, so this is a no-op in the normal case and a repair in the other,
  // and it says which.
  if ((await page.getByRole("heading", { name: "Settings", level: 1 }).count()) === 0) {
    console.log(`  !!  ${pass.id}/dialog:${dialogId} — Settings was no longer open; reopening`);
    await gotoTab(page, "Home");
    await openSettings(page);
  }

  let entered = false;
  try {
    // Walk into the drill-in that holds this control, if it is behind one.
    if (via !== undefined) {
      const row = page.getByRole("button", { name: via }).first();
      if ((await row.count()) === 0) {
        if (optional) {
          console.log(`  --  ${pass.id}/dialog:${dialogId} — the ${via} row is not offered in this account's state (expected)`);
          return;
        }
        failed = true;
        console.log(`FAIL  ${pass.id}/dialog:${dialogId} — no drill-in row matching ${via} on Settings`);
        return;
      }
      await row.scrollIntoViewIfNeeded();
      /*
       * `entered` is set from the SCREEN, not from the click.
       *
       * Setting it on the click was wrong in a way that only shows up when the
       * click misses — one landed mid-transition and opened nothing — because
       * the `finally` then closed a drill-in that was never there, which is to
       * say it closed Settings. The run reported "no row matching …" for the
       * control, and "Settings was no longer open" for the next entry, and
       * neither named the cause.
       *
       * Counted over ALL "Back from …" buttons rather than the live ones:
       * `SettingsPage` marks the covered panel's HEADER inert, so the hub's
       * back arrow goes inert exactly as the drill-in's appears and the live
       * count is 1 either way.
       */
      const panelsBefore = await page.locator('button[aria-label^="Back from "]').count();
      await row.click();
      try {
        await page.waitForFunction(
          (n) => document.querySelectorAll('button[aria-label^="Back from "]').length > n,
          panelsBefore,
          { timeout: 10_000 },
        );
        entered = true;
      } catch {
        failed = true;
        console.log(`FAIL  ${pass.id}/dialog:${dialogId} — the ${via} row opened no drill-in`);
        return;
      }
      await settle(page, 500);
    }

    /*
     * WAITED for, not counted once.
     *
     * A single `count()` a fixed 500ms after the drill-in was asked to open is a
     * race with the slide and with whatever the panel reads, and it lost once:
     * "Check my mail setup" is rendered unconditionally by the "Is mail
     * arriving?" panel, and the sweep still reported it missing. An `optional`
     * entry gets a short wait because it is legitimately absent much of the
     * time; a required one gets long enough to be believed.
     */
    const opener = page.getByRole("button", { name: match }).first();
    try {
      await opener.waitFor({ timeout: optional ? 3000 : 10_000 });
    } catch {
      // Not a skip to shrug at unless the entry says so: every other row in this
      // list is supposed to be where the table says it is, so a missing one means
      // the screen changed under the harness.
      if (optional) {
        console.log(`  --  ${pass.id}/dialog:${dialogId} — not offered in this account's state (expected)`);
        return;
      }
      failed = true;
      console.log(`FAIL  ${pass.id}/dialog:${dialogId} — no row matching ${match}${via === undefined ? " on Settings" : ` behind ${via}`}`);
      return;
    }
    await opener.scrollIntoViewIfNeeded();
    await opener.click();
    try {
      await page.getByRole("dialog").waitFor({ timeout: 8000 });
    } catch {
      failed = true;
      console.log(`FAIL  ${pass.id}/dialog:${dialogId} — pressing it opened no dialog`);
      return;
    }
    await settle(page, 450);
    await capture(page, pass.id, `dialog-${dialogId}`);
    report(pass.id, `dialog: ${dialogId}`, await audit(page));
    await tipsOn(page, pass.id, `dialog: ${dialogId}`);
    await page.keyboard.press("Escape");
    await settle(page, 400);
  } finally {
    // Back out of the drill-in this control lived in, so the next entry looks for
    // its row on Settings rather than through the screen above it.
    if (entered) await closeOverlay(page);
  }
}

const browser = await chromium.launch();
mkdirSync(OUT, { recursive: true });
for (const p of PASSES) mkdirSync(`${OUT}${p.id}`, { recursive: true });

try {
  const { page } = await newSignedOutContext(browser, { viewport: "phone", colorScheme: "light" });
  page.on("pageerror", (e) => {
    failed = true;
    console.error("  PAGE ERROR:", e.message);
  });

  // ---- onboarding, captured on the way past --------------------------------
  console.log("== onboarding (phone-light) ==");
  const walked = await ceremony(page, INVITE, {
    onStep: async (id, p) => {
      await settle(p, 400);
      await capture(p, "phone-light", id);
      report("phone-light", id, await audit(p));
      await tipsOn(p, "phone-light", id);
    },
  });
  console.log(`  ok  account created; inbound ${walked.inbound}`);

  // ---- fixture data --------------------------------------------------------
  console.log("== seeding fixtures through the app's own importer ==");
  const seeded = await seed(page);
  console.log(`  ok  ${seeded.imported} transaction(s) imported`);

  /*
   * Prove the fixtures are ON A SCREEN before measuring any screen.
   *
   * The importer reporting success is not the same as the app showing anything,
   * and for one run of this file it was not the same at all: 20 rows imported,
   * and Transactions, Home and Review all rendered their empty states until the
   * app was relaunched. Every audit in that run came back "clean" because there
   * was nothing on the glass to be wrong — a check that cannot fail, which is
   * this repo's most repeated defect and the reason for this block.
   */
  await gotoTab(page, "Transactions");
  await settle(page, 1200);
  const onScreen = await page.evaluate(() => document.body.innerText);
  const rowsShown = Number(onScreen.match(/(\d+)\s+transactions?\b/)?.[1] ?? 0);
  if (rowsShown < seeded.imported) {
    failed = true;
    console.log(
      `FAIL  the importer accepted ${seeded.imported} row(s) but Transactions shows ${rowsShown} — ` +
        `every screen below would be measuring an empty app, so the findings that follow mean nothing`,
    );
  } else {
    console.log(`  ok  ${rowsShown} row(s) on the Transactions screen, so the screens below have something to be wrong about`);
  }

  // ---- the product, once per pass -----------------------------------------
  for (const pass of PASSES) {
    console.log(`\n== ${pass.id} ==`);
    await page.setViewportSize(VIEWPORTS[pass.viewport].viewport);
    await page.emulateMedia({ colorScheme: pass.scheme });
    await settle(page, 500);

    for (const screen of SCREENS) {
      if (only !== null && !only.includes(screen.id)) continue;
      await gotoTab(page, "Home");
      // An `optional` screen whose entry point is absent (e.g. the mailbox
      // drill-in on a stack with no broker) returns "skip" from `open` rather
      // than failing — the config-gated-row analogue of SETTINGS_DIALOGS'
      // `optional`. Everything else returns undefined and captures as before.
      const opened = await screen.open(page);
      if (opened === "skip") {
        console.log(`  --  ${pass.id}/${screen.id} — not present in this deployment (optional)`);
        continue;
      }
      await settle(page, 500);
      await capture(page, pass.id, screen.id, { singleSegment: screen.singleSegment === true });
      report(pass.id, screen.id, await audit(page));
      await tipsOn(page, pass.id, screen.id);
      if (screen.reset !== undefined) await screen.reset(page);
    }

    // Settings' dialogs, which are where the app's forms live.
    if (only === null || only.includes("settings")) {
      await gotoTab(page, "Home");
      await openSettings(page);
      for (const entry of SETTINGS_DIALOGS) await sweepDialog(page, pass, entry);
      await closeOverlay(page);
    }
  }

  await writeFile(
    `${OUT}v2shoot.report.json`,
    JSON.stringify({ passes: PASSES.map((p) => p.id), inbound: walked.inbound, seeded: seeded.imported, tips, findings }, null, 2),
  );
  console.log(`\nreport: ${OUT}v2shoot.report.json`);
  const badTips = tips.filter((t) => t.opened === false || t.ok === false).length;
  console.log(`tooltips measured: ${tips.length}, off-screen or unreachable: ${badTips}`);
} finally {
  await browser.close();
}

process.exitCode = failed ? 1 : 0;
