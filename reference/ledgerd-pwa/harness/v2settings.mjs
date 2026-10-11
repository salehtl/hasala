/**
 * The v2 Settings hub, measured rather than eyeballed — and proved complete.
 *
 * # What this file is for, next to the other two that touch Settings
 *
 * Settings is the longest screen in the app and the one with the most ways in
 * and out, so three runners look at it and each answers a different question:
 *
 *   - `v2shoot.mjs` sweeps EVERY screen at two widths and both themes. Broad,
 *     and its Settings coverage is a fixed list of dialogs.
 *   - `v2subs.mjs` opens the seven drill-ins, because the prose this app is
 *     careful about lives on them.
 *   - **This file goes down.** One width, one theme, one account — and every
 *     destination the hub has, in one pass, with the hub itself scrolled end to
 *     end and audited at the bottom as well as the top.
 *
 * The assertion that is only here is {@link crawlHub}: the rows on the screen
 * are compared against the table below, and a row that is on one and not the
 * other **fails the run**. Both of the other runners walk a hardcoded list, so
 * a row added to Settings tomorrow is covered by neither and nothing says so.
 * That is this repo's most repeated defect — a check that cannot fail — aimed at
 * the screen most likely to grow a control.
 *
 * {@link rhythm} is the second, added for the same reason from the other
 * direction: the hub's group spacing and row height were both wrong on the
 * glass while the source carried comments stating the intended numbers, and no
 * runner looked. `audit.mjs` cannot see it — it asks whether a control is
 * reachable and correctly sized, never whether the screen has a rhythm.
 *
 *   harness/v2stack.sh up            # cluster + ledgerd + vite, prints an invite
 *   bun harness/v2settings.mjs <invite-code>
 *   harness/v2stack.sh down
 *
 * # It was dead for two days, and why (2026-08-12)
 *
 * This file carried its own copy of the ceremony, and three steps in that copy
 * stopped existing. It typed into the **type-back quiz** and pressed "Finish
 * setting up encryption" (both deleted by `0baf410`, "onboarding proposes, it
 * never blocks"), declared a bank on the onboarding **bank step** (removed
 * 2026-08-10) and posted corpus mail to clear a **verification gate** that no
 * longer gates anything. It also predated the 2026-08-10 restructure, so it
 * looked for `settings-inbound-address` and "Add a device" on the hub after both
 * had moved into drill-ins. It could not finish its walk at all.
 *
 * So it no longer owns a walk: {@link ceremony} in `v2nav.mjs` is the single
 * description of onboarding in this directory, and this file spends its length
 * on Settings instead. The corpus message stays, for a different reason than
 * before — nothing needs it to reach the product now, but without it Held mail
 * is an empty state, and an audit of an empty state is an audit of nothing.
 *
 * `localhost` and not `127.0.0.1`: WebAuthn needs a secure context.
 *
 * Chromium only, and the limits that come with it are real: `env(safe-area-inset-*)`
 * is 0, there is no software keyboard, and `dvh` never shrinks. It also runs
 * with motion left ALONE — no script in this directory sets `reducedMotion`,
 * unlike v1's `shoot.mjs` (`frontend/harness/`, in `salehtl/ledger`), which sets
 * `reducedMotion: "reduce"` for stable captures and would make `SettingsPage`
 * skip its slide entirely if the habit were copied here.
 */

import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { chromium } from "playwright";

import { audit, summarize } from "./audit.mjs";
import { ceremony, closeOverlay, newSignedOutContext, openSettings, seed, settle } from "./v2nav.mjs";

const HERE = new URL(".", import.meta.url).pathname;
const OUT = `${HERE}shots/`;
const SENDMAIL = `${HERE}sendmail.py`;
const CORPUS = `${HERE}../../internal/origin/testdata/gmail-forward-inner-dkim.eml`;
const INVITE = process.argv[2];
if (!INVITE) {
  console.error("usage: bun harness/v2settings.mjs <invite-code>");
  process.exit(2);
}

/**
 * Every destination the Settings hub has, in screen order.
 *
 * Read off the running app rather than off the JSX — `v2explore.mjs`'s method,
 * applied to Settings — because the last version of this file was written from
 * the source and named three controls the screen did not have.
 *
 * `kind` is how the destination comes back: a `page` is a full-screen drill-in
 * with a "Back from …" arrow, a `dialog` is a sheet that Escape closes. The
 * headings are what each one actually renders — a drill-in titles itself `h1`,
 * a sheet `h2` — so opening the wrong thing cannot pass as opening the right
 * one.
 *
 * The two `ToggleRow`s (Haptics, Sound) are switches and not destinations, and
 * `PushNotificationsPanel` renders its own row only where the browser supports
 * push, which headless Chromium does not. {@link crawlHub} accounts for both.
 */
const DESTINATIONS = [
  { id: "plan", row: /^Plan/, kind: "page", heading: "Your plan" },
  { id: "currency", row: /^Home currency/, kind: "page", heading: "Home currency" },
  { id: "categories", row: /^Your categories/, kind: "dialog", heading: "Your categories" },
  { id: "address", row: /^Your address/, kind: "page", heading: "Your address" },
  { id: "mail", row: /^Is mail arriving\?/, kind: "page", heading: "Is mail arriving?" },
  { id: "forwarding", row: /^Forwarding instructions/, kind: "dialog", heading: "Forwarding instructions" },
  // Not a Settings drill-in at all — `onOpenQuarantine` hands it to `AppShell`,
  // which stacks it OVER Settings. It closes like a drill-in, which is all this
  // run needs to know, but that is why the row is conditional in the JSX.
  { id: "held-mail", row: /^Held mail/, kind: "page", heading: "Held mail" },
  { id: "banks", row: /^Your banks/, kind: "page", heading: "Your banks" },
  // `optional`: the row exists only where a mailbox broker is deployed
  // (`--gmail-fixtures`), and spec §2.3 makes an unconfigured build render no
  // row at all. Without the flag this run failed on a broker stack with "1 row
  // this run does not open" and failed on a plain one with "1 table entry has
  // no row" — a completeness crawl that cannot be satisfied by any stack is a
  // check nobody keeps green.
  { id: "mailbox", row: /^Transaction mailbox/, kind: "page", heading: "Transaction mailbox", optional: true },
  { id: "text-size", row: /^Text size/, kind: "dialog", heading: "Text size" },
  { id: "passkeys", row: /^Passkeys/, kind: "page", heading: "Passkeys" },
  { id: "devices", row: /^Other devices/, kind: "page", heading: "Other devices" },
  { id: "import", row: /^Import a statement/, kind: "dialog", heading: "Import a statement" },
  { id: "export", row: /^Download my data/, kind: "dialog", heading: "Download my data" },
  // Opened and photographed, never confirmed. The row press is a sheet; the
  // button inside it is the one that ends the run, and nothing here touches it.
  { id: "sign-out", row: /^Sign out/, kind: "dialog", heading: "Sign out of ledger?" },
  { id: "delete-account", row: /^Delete account/, kind: "dialog", heading: "Delete account" },
];

/** Chrome, not destinations: the panel's own controls and the tips on it. */
const NOT_A_ROW = [/^Back from /, /^Sync now$/, /^About /];

const findings = [];
let failed = false;

function report(label, result) {
  const bad = result.issues.filter((i) => i.severity === "high" || i.severity === "medium");
  findings.push({ label, counts: result.counts, issues: summarize(result.issues) });
  if (bad.length === 0) {
    console.log(`  ok  ${label} — clean (${result.issues.length} low)`);
    return;
  }
  failed = true;
  console.log(`FAIL  ${label} — ${bad.length} finding(s)`);
  for (const s of summarize(bad)) {
    console.log(`        ${s.severity} ${s.kind} ×${s.count}`);
    for (const e of s.examples.slice(0, 4)) console.log(`          ${e.el} — ${e.detail}`);
  }
}

/**
 * The element that actually scrolls **on the layer the user is looking at**,
 * tagged in place so the scroll and the measurement cannot pick different
 * elements.
 *
 * # Two ways to measure the wrong thing, both of which happened here
 *
 * The first version took the FIRST scrollable element it found, which was an
 * inner 816px one; both "segments" then came out byte-identical and the
 * scrolled-to-the-end audit re-measured the top of the screen.
 *
 * The largest-overflow rule that replaced it was still wrong for a drill-in, and
 * the rebuild caught it: `SettingsPage` marks only its **header** inert when a
 * deeper panel opens, never its body — a nested panel renders inside that body,
 * so inerting it would disable the page on top. The hub's 1202px scroller is
 * therefore an ANCESTOR of the drill-in, is not inert, and beat every candidate
 * inside the panel actually on screen. Seven drill-ins reported the hub's height
 * and screenshotted the same unscrolled panel twice.
 *
 * So the search is scoped to the topmost layer first, by the same rule
 * `audit.mjs` uses to decide what it is auditing: an open dialog, else the last
 * full-screen fixed/absolute cover in DOM order, else the document. Keeping the
 * two rules identical is the point — a screen this file measures and that file
 * audits should not be able to be two different screens.
 */
async function scrollInfo(page) {
  return page.evaluate(() => {
    const vw = document.documentElement.clientWidth;
    const vh = document.documentElement.clientHeight;
    const visible = (el) => {
      const s = getComputedStyle(el);
      if (s.display === "none" || s.visibility === "hidden" || parseFloat(s.opacity) === 0) return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };
    const layerRoot = (() => {
      const dialog = [...document.querySelectorAll('[role="dialog"], dialog[open]')].filter(visible).pop();
      if (dialog) return dialog;
      const covers = [...document.querySelectorAll("body *")].filter((el) => {
        const s = getComputedStyle(el);
        if (!["fixed", "absolute"].includes(s.position)) return false;
        if (!visible(el)) return false;
        const r = el.getBoundingClientRect();
        return r.width >= vw * 0.9 && r.height >= vh * 0.85 && r.top <= 8;
      });
      return covers.length ? covers[covers.length - 1] : document.body;
    })();

    let best = null;
    for (const el of layerRoot.querySelectorAll("*")) {
      if (!["auto", "scroll"].includes(getComputedStyle(el).overflowY)) continue;
      if (el.closest("[inert]") !== null) continue;
      const over = el.scrollHeight - el.clientHeight;
      if (over > 8 && (!best || over > best.over)) {
        document.querySelector("[data-harness-scroller]")?.removeAttribute("data-harness-scroller");
        best = { over, height: el.clientHeight, total: el.scrollHeight };
        el.setAttribute("data-harness-scroller", "1");
      }
    }
    if (best) return { kind: "element", ...best };
    // Only the document is left, and only when nothing is covering it: a layer
    // that does not scroll is one segment, not the page behind it scrolled.
    if (layerRoot !== document.body) return { kind: "none", over: 0, height: 0, total: 0 };
    const doc = document.scrollingElement;
    const over = doc.scrollHeight - doc.clientHeight;
    if (over > 8) return { kind: "document", over, height: doc.clientHeight, total: doc.scrollHeight };
    return { kind: "none", over: 0, height: 0, total: 0 };
  });
}

/**
 * Scroll the element {@link scrollInfo} tagged, and say whether it was there.
 *
 * The tag can vanish between the measurement and the scroll — a re-render
 * replaces the node it was set on — and reaching through the null took
 * `v2shoot.mjs` down mid-sweep. Reporting cannot hide a broken scroll: every
 * segment would then be byte-identical, which {@link capture} fails on.
 */
async function scrollTo(page, kind, y) {
  if (kind === "none") return false;
  const scrolled = await page.evaluate(
    ([kind, y]) => {
      const el = kind === "document" ? document.scrollingElement : document.querySelector("[data-harness-scroller]");
      if (el === null) return false;
      el.scrollTop = y;
      return true;
    },
    [kind, y],
  );
  await page.waitForTimeout(300);
  return scrolled;
}

/** Capture the scrolling container in viewport-sized segments, auditing each. */
async function capture(page, name) {
  const info = await scrollInfo(page);
  const segments = info.kind === "none" ? 1 : Math.min(8, Math.ceil(info.total / info.height));
  const seen = new Set();
  for (let i = 0; i < segments; i++) {
    await scrollTo(page, info.kind, i * info.height);
    const shot = await page.screenshot({ path: `${OUT}${name}.${i}.png` });
    seen.add(shot.length);
  }
  // Two identical segments mean the scroll did nothing, which is how the first
  // version of this file reported a clean screen it had never looked at.
  if (segments > 1 && seen.size === 1) {
    failed = true;
    console.log(`FAIL  ${name} — ${segments} segments captured but every one is identical; the scroll did nothing`);
  }
  await scrollTo(page, info.kind, 0);
  return { ...info, segments };
}

/**
 * Every row the hub is showing, from the DOM — the completeness half.
 *
 * Scoped to the live layer: a drill-in leaves Settings mounted behind `inert`,
 * and an inert button is still laid out and still passes `isVisible()`, so an
 * unscoped crawl reads rows through whatever is covering them.
 */
async function hubRows(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("button")]
      .filter((el) => el.closest("[inert]") === null && el.closest("nav") === null && el.getBoundingClientRect().width > 0)
      .map((el) => (el.getAttribute("aria-label") ?? el.textContent ?? "").replace(/\s+/g, " ").trim()),
  );
}

/**
 * Compare the screen against {@link DESTINATIONS}, both ways.
 *
 * A row on the screen that the table does not know about is the case worth
 * having: it means Settings grew a control and no runner in this directory
 * opens it. The reverse — a table entry with no row — is the 2026-08-10
 * restructure repeating itself, and is exactly how this file died.
 */
async function crawlHub(page) {
  const onScreen = (await hubRows(page)).filter((name) => name !== "" && !NOT_A_ROW.some((re) => re.test(name)));
  const unknown = onScreen.filter((name) => !DESTINATIONS.some((d) => d.row.test(name)));
  const missing = DESTINATIONS.filter((d) => d.optional !== true && !onScreen.some((name) => d.row.test(name)));
  if (unknown.length > 0) {
    failed = true;
    console.log(`FAIL  the hub has ${unknown.length} row(s) this run does not open: ${unknown.map((u) => `"${u}"`).join(", ")}`);
  }
  if (missing.length > 0) {
    failed = true;
    console.log(`FAIL  ${missing.length} table entr(ies) have no row on the hub: ${missing.map((m) => m.id).join(", ")}`);
  }
  if (unknown.length === 0 && missing.length === 0) {
    console.log(`  ok  every one of the hub's ${onScreen.length} rows is a destination this run opens`);
  }
  return { onScreen, unknown: unknown.length, missing: missing.map((m) => m.id) };
}

/**
 * The hub's vertical rhythm, measured — because a comment claiming it is not a
 * check, and this screen has already proved that.
 *
 * Two numbers, both of which were wrong on the running app while the source
 * said otherwise:
 *
 *  - **The gap between groups.** Proximity is the only thing that groups these
 *    rows — no rule, no card around a group, and the eyebrows are deliberately
 *    small — so if that gap collapses, six subjects read as one long list. It
 *    WAS collapsed, to 0px, because `space-y-*` compiles to a direct-child
 *    combinator and the groups sat behind a `display: contents` wrapper that
 *    swallowed it. Two commits "tuned" that gap (24px, then 32px) and neither
 *    number ever reached the glass.
 *  - **One row height.** Every row on the hub is one line and they should all
 *    be one height, but each took its height from its own content: a chevron
 *    row came out 49px and a toggle row 73px, because `Switch` is 44px for its
 *    touch target. Two rows under one divider, 24px apart in height.
 *
 * Both are invisible to `audit.mjs`, which asks whether a control is reachable
 * and correctly sized, never whether the screen has a rhythm.
 */
async function rhythm(page) {
  const m = await page.evaluate(() => {
    const host = document.querySelector('[data-testid="settings-sync"]').parentElement;
    const kids = [...host.children].filter((el) => el.getBoundingClientRect().height > 0);
    const gaps = kids.slice(1).map((el, i) => {
      const r = el.getBoundingClientRect();
      return Math.round(r.top - kids[i].getBoundingClientRect().bottom);
    });
    // One-line rows only: the notifications panel is prose under its label and
    // is legitimately taller, so it is identified by its testid and excluded.
    const heights = [...document.querySelectorAll('[data-testid^="settings-group"] > div > div > *, [data-testid="settings-danger"] > div > div > *')]
      .filter((el) => el.getAttribute("data-testid") !== "push-notifications")
      .map((el) => Math.round(el.getBoundingClientRect().height));
    return { gaps, heights };
  });
  const tight = m.gaps.filter((g) => g < 20);
  const spread = m.heights.length === 0 ? 0 : Math.max(...m.heights) - Math.min(...m.heights);
  if (tight.length > 0) {
    failed = true;
    console.log(`FAIL  ${tight.length} of ${m.gaps.length} between-group gap(s) under 20px: ${m.gaps.join(", ")}px — the groups have stopped reading as groups`);
  } else {
    console.log(`  ok  groups separated by ${[...new Set(m.gaps)].join("/")}px, all clear of the 12px inside a group`);
  }
  // 2px of slack: a row carries a 1px divider and sub-pixel layout rounds.
  if (spread > 2) {
    failed = true;
    console.log(`FAIL  the hub's one-line rows are ${spread}px apart in height (${[...new Set(m.heights)].sort((a, b) => a - b).join(", ")}px) — the list stutters`);
  } else {
    console.log(`  ok  all ${m.heights.length} one-line rows share one height (${m.heights[0]}px)`);
  }
  return m;
}

/** Open one destination, measure it, and put the screen back. */
async function visit(page, { id, row, kind, heading, optional = false }) {
  await openSettings(page);
  const opener = page.getByRole("button", { name: row }).first();
  if ((await opener.count()) === 0) {
    if (optional) {
      // Close the hub this opened before bailing: a left-open Settings covers
      // the row the next destination reaches for.
      await closeOverlay(page);
      console.log(`  --  ${id} — not on this deployment, skipped`);
      return;
    }
    failed = true;
    console.log(`FAIL  ${id} — no row matching ${row} on the hub`);
    return;
  }
  await opener.scrollIntoViewIfNeeded();
  await opener.click();

  // Every exit from here unwinds what it opened. The `finally` is not decoration:
  // `v2shoot.mjs` had this same shape written with early `continue`s, a drill-in
  // stayed open on the skip path, and the run died on the next click against the
  // panel covering it.
  let opened = false;
  try {
    if (kind === "dialog") {
      try {
        await page.getByRole("dialog").waitFor({ timeout: 15_000 });
        opened = true;
      } catch {
        failed = true;
        console.log(`FAIL  ${id} — pressing the row opened no dialog`);
        return;
      }
    } else {
      try {
        await page.getByRole("button", { name: `Back from ${heading}` }).waitFor({ timeout: 15_000 });
        opened = true;
      } catch {
        failed = true;
        console.log(`FAIL  ${id} — pressing the row opened no drill-in titled "${heading}"`);
        return;
      }
    }
    await settle(page, 500);

    // The heading proves the row opened the screen it names, and at the level
    // that screen's shell renders: a drill-in owns the `h1`, a sheet an `h2`.
    const titles = await page.evaluate(
      (level) =>
        [...document.querySelectorAll(level)]
          .filter((h) => h.closest("[inert]") === null && h.getBoundingClientRect().width > 0)
          .map((h) => h.textContent.trim()),
      kind === "dialog" ? "h2" : "h1",
    );
    if (!titles.includes(heading)) {
      failed = true;
      console.log(`FAIL  ${id} — expected the heading "${heading}", found ${JSON.stringify(titles)}`);
    }

    const geometry = await capture(page, `settings-${id}`);
    report(`${kind}: ${id}`, await audit(page));
    if (geometry.segments > 1) console.log(`      ${id} — ${geometry.segments} segment(s), ${geometry.total}px in a ${geometry.height}px viewport`);
  } finally {
    if (opened) {
      if (kind === "dialog") {
        await page.keyboard.press("Escape");
        await settle(page, 400);
      } else {
        await closeOverlay(page);
      }
    }
    // Held mail stacks OVER Settings rather than inside it, and Escape reaches
    // more than one listener, so what is on screen now is not always the hub.
    // `openSettings` at the top of the next visit is idempotent and repairs it.
  }
}

const browser = await chromium.launch();
mkdirSync(OUT, { recursive: true });

try {
  const { page } = await newSignedOutContext(browser, {});
  page.on("pageerror", (e) => {
    failed = true;
    console.error("  page error:", e.message);
  });

  // ---- the ceremony, which is the only door into any v2 screen -------------
  const walked = await ceremony(page, INVITE, { skip: true });
  console.log(`  ok  account created; inbound ${walked.inbound}`);

  // Fixture data, so the rows carry real values — "Plan 50 / 30 / 20", a
  // category count, a bank summary — rather than the empty state's dashes.
  const seeded = await seed(page);
  console.log(`  ok  ${seeded.imported} transaction(s) imported`);

  /*
   * One corpus message, so Held mail has something to hold.
   *
   * It is a FORWARDED message: a direct one verifies its DKIM and is still held
   * with `attested = false`, because `origin/inner.go` only attests an inner
   * origin and a message nothing relayed has none. Its DKIM verifies offline
   * because `v2stack.sh` runs ledgerd with `--dns-fixtures`.
   */
  execFileSync("python3", [SENDMAIL, walked.inbound, CORPUS], { stdio: "inherit", cwd: HERE });

  // ---- the hub itself ------------------------------------------------------
  await openSettings(page);
  await settle(page, 800);

  const groups = await page.$$eval("h2", (hs) =>
    hs.filter((h) => h.closest("[inert]") === null && h.getBoundingClientRect().width > 0).map((h) => h.textContent.trim()),
  );
  console.log(`  ok  groups: ${groups.join(" · ")}`);

  const geometry = await capture(page, "v2-settings");
  console.log(`  ok  captured ${geometry.segments} segment(s), ${geometry.total}px of screen in a ${geometry.height}px viewport`);
  report("hub", await audit(page));

  // Every row is a control a thumb has to reach: measure the bottom of the
  // scroll too, where the sign-out and the deletion sit.
  const scroller = await scrollInfo(page);
  await scrollTo(page, scroller.kind, scroller.total);
  report("hub (scrolled to the end)", await audit(page));
  await scrollTo(page, scroller.kind, 0);

  const crawl = await crawlHub(page);
  const beat = await rhythm(page);

  // ---- and everywhere it leads --------------------------------------------
  for (const destination of DESTINATIONS) await visit(page, destination);

  await writeFile(`${OUT}v2-settings.report.json`, JSON.stringify({ groups, geometry, crawl, beat, findings }, null, 2));
  console.log(`\nreport: ${OUT}v2-settings.report.json`);
} finally {
  await browser.close();
}

process.exitCode = failed ? 1 : 0;
