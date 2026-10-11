/**
 * playseed.mjs — months of PLAUSIBLE transactions for the play instance.
 *
 * # Why this is not `v2nav.mjs`'s seed
 *
 * `v2nav.mjs` holds HOSTILE_ROWS: a 73-character merchant, -9999999.99, a
 * category long enough to wrap a chip. Those exist to break layouts, and they
 * are perfect for the scripted runners. They are useless for the question the
 * play instance answers — "does this app feel right in my hand?" — because a
 * screen full of deliberate worst cases tells you nothing about rhythm,
 * hierarchy or density. So this file is the other half: ordinary UAE spending,
 * an ordinary salary, ordinary bills.
 *
 * # Why it is deterministic
 *
 * `Math.random()` would make the test unable to assert anything but shape, and
 * would make two runs of `play.sh reset` produce different ledgers — so a screen
 * that looked wrong could not be reproduced. A fixed seed and an explicit
 * `endDate` make the file a pure function of its options.
 *
 * # Why a CSV and not a database insert
 *
 * The client is the only writer of ops (`CLAUDE.md`, core principles), so there
 * is no server-side seam to insert through. Import is the one bulk-write path a
 * user has, so it is the one this uses. See the spec's "Where the data comes
 * from" for why the mail lane cannot fill a ledger: there are seven captured
 * .eml fixtures and no private DKIM key, so new signed bank mail cannot exist.
 *
 *   bun harness/playseed.mjs /var/lib/ledger-play/seed
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const CSV_HEADER = "Date,Description,Amount,Category";

/** mulberry32 — small, fast, and seedable, which `Math.random` is not. */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Bills and income that land on the same day every month. */
const MONTHLY = [
  { day: 1, desc: "DUBAI PROPERTIES RENT INSTALMENT", min: 7500, max: 7500, cat: "Housing" },
  { day: 3, desc: "DEWA UTILITY BILL", min: 380, max: 520, cat: "Bills" },
  { day: 5, desc: "ETISALAT POSTPAID", min: 315, max: 315, cat: "Bills" },
  { day: 8, desc: "SALIK RECHARGE", min: 100, max: 100, cat: "Transport" },
  { day: 12, desc: "NETFLIX.COM", min: 56, max: 56, cat: "Subscriptions" },
  { day: 14, desc: "APPLE.COM/BILL", min: 9.99, max: 29.99, cat: "Subscriptions" },
  { day: 18, desc: "SPOTIFY AB", min: 19.99, max: 19.99, cat: "Subscriptions" },
];

/** One grocery run a week. */
const GROCERIES = [
  { desc: "CARREFOUR MALL OF THE EMIRATES", min: 180, max: 480 },
  { desc: "SPINNEYS MOTOR CITY", min: 120, max: 340 },
  { desc: "UNION COOP AL BARSHA", min: 90, max: 260 },
];

/** The everyday spend that fills a list. */
const EVERYDAY = [
  { desc: "TALABAT", min: 28, max: 95, cat: "Eating out" },
  { desc: "STARBUCKS DIFC", min: 18, max: 42, cat: "Eating out" },
  { desc: "COSTA COFFEE JLT", min: 14, max: 38, cat: "Eating out" },
  { desc: "DELIVEROO AE", min: 32, max: 110, cat: "Eating out" },
  { desc: "ADNOC SERVICE STATION 1042", min: 90, max: 220, cat: "Transport" },
  { desc: "CAREEM RIDE", min: 12, max: 68, cat: "Transport" },
  { desc: "DUBAI TAXI CORPORATION", min: 15, max: 72, cat: "Transport" },
  { desc: "PARKING RTA", min: 2, max: 20, cat: "Transport" },
  // The comma is deliberate: it proves the writer quotes fields, and the
  // importer still sees four columns.
  { desc: "NOON.COM, DUBAI", min: 35, max: 420, cat: "Shopping" },
  { desc: "AMAZON.AE", min: 25, max: 380, cat: "Shopping" },
  { desc: "LIFE PHARMACY", min: 20, max: 160, cat: "Health" },
  { desc: "VOX CINEMAS", min: 45, max: 130, cat: "Entertainment" },
];

/** Occasional larger purchases, so the list is not uniform. */
const OCCASIONAL = [
  { desc: "IKEA DUBAI FESTIVAL CITY", min: 320, max: 1900, cat: "Home" },
  { desc: "SHARAF DG ELECTRONICS", min: 250, max: 3200, cat: "Shopping" },
  { desc: "EMIRATES AIRLINE BOOKING", min: 900, max: 4800, cat: "Travel" },
  { desc: "DUBAI MALL FASHION AVENUE", min: 300, max: 2100, cat: "Shopping" },
];

const money = (r, min, max) => (min + r() * (max - min)).toFixed(2);
const pick = (r, list) => list[Math.floor(r() * list.length)];
const iso = (d) => d.toISOString().slice(0, 10);

/**
 * Build the rows and the CSV text.
 *
 * @param {{endDate?: string, months?: number, seed?: number}} [opts]
 * @returns {{rows: string[][], csv: string}}
 */
export function generate(opts = {}) {
  const { endDate = "2026-08-16", months = 6, seed = 20260816 } = opts;
  const r = rng(seed);
  const end = new Date(`${endDate}T00:00:00Z`);
  const start = new Date(end);
  start.setUTCMonth(start.getUTCMonth() - months);

  const rows = [];
  for (let d = new Date(start); d <= end; d.setUTCDate(d.getUTCDate() + 1)) {
    const date = iso(d);
    const dom = d.getUTCDate();

    // Salary on the 25th. Guarded on `months` so the count is exactly one per
    // month of the window, which the test asserts.
    if (dom === 25) rows.push([date, "SALARY — EXAMPLE EMPLOYER LLC", money(r, 28500, 28500), "Income"]);

    for (const m of MONTHLY) {
      if (dom === m.day) rows.push([date, m.desc, `-${money(r, m.min, m.max)}`, m.cat]);
    }

    // Saturday is the grocery run.
    if (d.getUTCDay() === 6) {
      const g = pick(r, GROCERIES);
      rows.push([date, g.desc, `-${money(r, g.min, g.max)}`, "Groceries"]);
    }

    const n = [0, 1, 1, 2, 2, 3][Math.floor(r() * 6)];
    for (let i = 0; i < n; i += 1) {
      const e = pick(r, EVERYDAY);
      rows.push([date, e.desc, `-${money(r, e.min, e.max)}`, e.cat]);
    }

    if (r() < 0.05) {
      const o = pick(r, OCCASIONAL);
      rows.push([date, o.desc, `-${money(r, o.min, o.max)}`, o.cat]);
    }
  }

  // Blank a minority of categories so the review deck has something to review.
  // Income keeps its category: an uncategorised salary is a hostile case, and
  // this file is the plausible one.
  for (const row of rows) {
    if (row[3] !== "Income" && r() < 0.12) row[3] = "";
  }

  const esc = (v) => (/[",]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
  const csv = `${[CSV_HEADER, ...rows.map((row) => row.map(esc).join(","))].join("\n")}\n`;
  return { rows, csv };
}

// CLI: write the file where `play.sh` serves it.
if (import.meta.url === `file://${process.argv[1]}`) {
  const outDir = process.argv[2];
  if (!outDir) {
    console.error("usage: bun harness/playseed.mjs <outdir>");
    process.exit(2);
  }
  mkdirSync(outDir, { recursive: true });
  const { rows, csv } = generate();
  const path = join(outDir, "ledger-play.csv");
  writeFileSync(path, csv);
  console.log(`wrote ${rows.length} rows to ${path}`);
}
