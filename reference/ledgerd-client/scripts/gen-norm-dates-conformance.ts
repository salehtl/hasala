/**
 * Writes `conformance/norm-dates/` — the date and time canonicalisation the
 * Swift port must reproduce exactly:
 *
 *   - `forward_dates`: the normalizer's stage-10 forwarded-`Date` parser
 *     (`norm/unwrap.ts` `parseForwardDate`), four closed layouts read as naive
 *     UTC, rendered the way the normalizer renders `emailDate`.
 *   - `email_dates`: stage 10's choice between that date and the arrival time
 *     (`norm/norm.ts` `emailDateOf`).
 *   - `instants`: the wire timestamp grammar the fold applies to `posted_at` and
 *     `authored_at` (`wire/op.ts` `parseInstantMs`, `canonicalTime`), and the
 *     UTC day the duplicate fingerprint keys on (`replay/state.ts` `utcDay`).
 *
 * Expectations are computed by the oracle. `parseForwardDate` is the Go
 * normalizer's twin, and every `forward_dates` input was also checked against
 * Go's `time.Parse` when this suite was written (the two disagreed on runs of
 * spaces and on years below 100 until the TypeScript side was fixed).
 *
 *     cd reference/ledgerd-client && bun run gen-norm-dates-conformance
 *     bun run gen-norm-dates-conformance --check
 */

import "../src/platform";

import { emailDateOf, formatRFC3339UTC } from "../src/norm/norm";
import { parseForwardDate } from "../src/norm/unwrap";
import { utcDay } from "../src/replay/state";
import { canonicalTime, parseInstantMs } from "../src/wire/op";
import { asciiJSON, assertFresh, writeOrCheck, type FixtureFile } from "./conformance-io";

export const SUITE = "norm-dates";
const REGENERATE = "bun run gen-norm-dates-conformance";

export interface ForwardDateVector {
  name: string;
  input: string;
  expect: string | null;
}

export interface EmailDateVector {
  name: string;
  forward_date: string;
  received_at: string;
  expect: { email_date: string; date_source: string };
}

export interface InstantVector {
  name: string;
  input: string;
  expect: { ok: false } | { ok: true; epoch_ms: string; canonical: string; utc_day: string };
}

export interface DatesDoc {
  forward_dates: ForwardDateVector[];
  email_dates: EmailDateVector[];
  instants: InstantVector[];
}

/** `[name, input]`: every one goes through parseForwardDate. */
const FORWARD_INPUTS: readonly (readonly [string, string])[] = [
  // The four layouts.
  ["layout-1", "Feb 8, 2026 at 12:52 PM"],
  ["layout-2-weekday", "Sun, Feb 8, 2026 at 12:52 PM"],
  ["layout-3-seconds", "8 February 2026 at 15:36:02"],
  ["layout-4", "8 February 2026 at 15:36"],
  // Twelve-hour clock edges.
  ["midnight-12-am", "Feb 8, 2026 at 12:05 AM"],
  ["noon-12-pm", "Feb 8, 2026 at 12:05 PM"],
  ["zero-hour-am", "Feb 8, 2026 at 0:05 AM"],
  ["zero-hour-pm", "Feb 8, 2026 at 0:05 PM"],
  ["hour-13-pm-refused", "Feb 8, 2026 at 13:05 PM"],
  ["lowercase-pm-refused", "Feb 8, 2026 at 12:52 pm"],
  ["mixed-case-pm-refused", "Feb 8, 2026 at 12:52 Pm"],
  ["leading-zero-hour-and-day", "Feb 08, 2026 at 01:05 PM"],
  // Names: ASCII case-insensitive, closed tables.
  ["upper-case-month", "FEB 8, 2026 at 1:05 PM"],
  ["lower-case-long-month", "8 february 2026 at 15:36"],
  ["long-month-in-short-layout-refused", "February 8, 2026 at 1:05 PM"],
  ["short-month-in-long-layout-refused", "8 Feb 2026 at 15:36"],
  ["sept-refused", "8 Sept 2026 at 9:00"],
  ["unknown-month-refused", "Xyz 8, 2026 at 12:52 PM"],
  ["weekday-not-checked-against-date", "Thu, Feb 8, 2026 at 12:52 PM"],
  ["unknown-weekday-refused", "Xyz, Feb 8, 2026 at 12:52 PM"],
  ["long-weekday-refused", "Sunday, Feb 8, 2026 at 12:52 PM"],
  ["weekday-without-space-refused", "Sun,Feb 8, 2026 at 1:05 PM"],
  // Field ranges.
  ["feb-29-leap-year", "29 February 2028 at 10:00"],
  ["feb-29-common-year-refused", "29 February 2026 at 10:00"],
  ["feb-29-century-refused", "29 February 2100 at 10:00"],
  ["feb-29-400-year", "29 February 2000 at 10:00"],
  ["feb-30-refused", "Feb 30, 2026 at 1:00 PM"],
  ["day-31-in-30-day-month-refused", "31 April 2026 at 10:00"],
  ["day-zero-refused", "0 April 2026 at 10:00"],
  ["hour-23", "8 February 2026 at 23:59:59"],
  ["hour-24-refused", "8 February 2026 at 24:00"],
  ["minute-60-refused", "8 February 2026 at 15:60"],
  ["second-60-refused", "8 February 2026 at 15:36:60"],
  ["one-digit-minute-refused", "8 february 2026 at 7:5"],
  ["one-digit-second-refused", "8 February 2026 at 07:05:5"],
  ["three-digit-hour-refused", "8 February 2026 at 123:00"],
  ["five-digit-year-refused", "8 February 20260 at 12:00"],
  ["three-digit-year-refused", "8 February 202 at 12:00"],
  ["year-below-100", "8 February 0050 at 15:36"],
  ["year-zero-leap-day", "29 February 0000 at 15:36"],
  ["year-9999", "31 December 9999 at 23:59:59"],
  // Spacing: a layout space matches a run of spaces, nothing else.
  ["double-space-after-month", "Feb  8, 2026 at 12:52 PM"],
  ["double-space-after-comma", "Feb 8,  2026 at 12:52 PM"],
  ["double-space-around-at", "8 February 2026  at   15:36"],
  ["double-space-before-pm", "Feb 8, 2026 at 12:52  PM"],
  ["space-before-comma-refused", "Feb 8 , 2026 at 12:52 PM"],
  ["tab-between-fields-refused", "8\tFebruary 2026 at 9:00"],
  ["no-at-refused", "Mar 3, 2026 2:07 PM"],
  // Trimming and the no-break spaces.
  ["leading-and-trailing-spaces", "  Feb 8, 2026 at 12:52 PM  "],
  ["trailing-tab", "8 February 2026 at 9:00\t"],
  ["surrounding-crlf", "\r\n8 February 2026 at 9:00\r\n"],
  ["surrounding-nbsp-and-bom", "\u00a0\ufeff8 February 2026 at 9:00\ufeff\u00a0"],
  ["narrow-nbsp-before-pm", "Feb 8, 2026 at 12:52\u202fPM"],
  ["nbsp-before-pm", "Feb 8, 2026 at 12:52\u00a0PM"],
  ["nbsp-everywhere", "Feb\u00a08,\u00a02026\u00a0at\u00a012:52\u202fPM"],
  ["em-space-is-not-a-space", "Feb 8, 2026 at 12:52\u2003PM"],
  ["fullwidth-digit-refused", "Feb \uff18, 2026 at 12:52 PM"],
  ["arabic-indic-digit-refused", "\u0668 February 2026 at 9:00"],
  // The retry with the last token removed (zone names).
  ["trailing-zone-gst", "8 February 2026 at 15:36:02 GST"],
  ["trailing-zone-gmt-offset", "Feb 8, 2026 at 12:52 PM GMT+4"],
  ["trailing-zone-after-narrow-nbsp", "Feb 8, 2026 at 12:52\u202fPM\u202fGST"],
  ["two-trailing-tokens-refused", "Feb 8, 2026 at 12:52 PM GMT +4"],
  ["trailing-junk-glued-refused", "Feb 8, 2026 at 12:52 PMX"],
  ["iso-instant-refused", "2026-03-03T14:07:00Z"],
  ["date-only-refused", "March 3, 2026"],
  ["ios-12-hour-with-seconds-refused", "14 February 2026 at 6:12:38 PM GST"],
  ["rfc-5322-date-refused", "Sun, 8 Feb 2026 12:52:00 +0400"],
  ["empty", ""],
  ["only-spaces", "   "],
];

/** `[name, forward_date, received_at]` for emailDateOf. */
const EMAIL_INPUTS: readonly (readonly [string, string, string])[] = [
  ["no-forward-date", "", "2026-08-01T12:00:00Z"],
  ["forward-date-wins", "Feb 8, 2026 at 12:52 PM", "2026-08-01T12:00:00Z"],
  ["forward-date-unreadable-falls-back", "14 February 2026 at 6:12:38 PM GST", "2026-08-01T12:00:00Z"],
  ["received-offset-converted-to-utc", "", "2026-08-01T16:00:00+04:00"],
  ["received-offset-crosses-the-year", "", "2027-01-01T02:00:00+04:00"],
  ["received-negative-offset", "", "2026-12-31T22:30:00-02:00"],
  ["received-fraction-truncated", "", "2026-08-01T12:00:00.999Z"],
  ["forward-date-is-naive-not-shifted", "8 February 2026 at 23:30", "2026-02-09T03:00:00+04:00"],
  ["forward-date-may-postdate-arrival", "31 December 2026 at 23:59:59", "2026-08-01T12:00:00Z"],
];

/** Inputs to the wire timestamp grammar. */
const INSTANT_INPUTS: readonly (readonly [string, string])[] = [
  ["utc-seconds", "2026-06-05T09:00:00Z"],
  ["utc-millis", "2026-06-05T09:00:00.123Z"],
  ["fraction-one-digit", "2026-06-05T09:00:00.5Z"],
  ["fraction-truncated-not-rounded", "2026-06-05T09:00:00.9999999Z"],
  ["fraction-sub-millisecond", "2026-06-05T09:00:00.0015Z"],
  ["positive-offset", "2026-06-05T13:00:00+04:00"],
  ["negative-offset", "2026-06-05T04:30:00-04:30"],
  ["offset-crosses-the-day", "2026-06-06T02:00:00+04:00"],
  ["offset-crosses-back-a-day", "2026-06-05T22:00:00-04:00"],
  ["max-offset", "2026-06-05T09:00:00+23:59"],
  ["leap-day", "2028-02-29T12:00:00Z"],
  ["epoch", "1970-01-01T00:00:00Z"],
  ["before-epoch", "1969-12-31T23:59:59.999Z"],
  ["year-below-100", "0050-02-08T15:36:00Z"],
  ["year-one", "0001-01-01T00:00:00.001Z"],
  ["year-9999", "9999-12-31T23:59:59.999Z"],
  ["go-zero-time-refused", "0001-01-01T00:00:00Z"],
  ["canonical-year-10000-refused", "9999-12-31T23:59:59-23:59"],
  ["canonical-year-minus-1-refused", "0000-01-01T00:00:00+00:01"],
  ["lowercase-t-refused", "2026-06-05t09:00:00Z"],
  ["lowercase-z-refused", "2026-06-05T09:00:00z"],
  ["hour-24-refused", "2026-06-05T24:00:00Z"],
  ["second-60-refused", "2026-06-05T23:59:60Z"],
  ["feb-30-refused", "2026-02-30T10:00:00Z"],
  ["feb-29-common-year-refused", "2026-02-29T10:00:00Z"],
  ["offset-hour-24-refused", "2026-06-05T10:00:00+24:00"],
  ["offset-minute-60-refused", "2026-06-05T10:00:00+04:60"],
  ["no-zone-refused", "2026-06-05T09:00:00"],
  ["space-separator-refused", "2026-06-05 09:00:00Z"],
  ["empty-fraction-refused", "2026-06-05T09:00:00.Z"],
  ["compact-offset-refused", "2026-06-05T09:00:00+0400"],
  ["date-only-refused", "2026-06-05"],
  ["trailing-space-refused", "2026-06-05T09:00:00Z "],
  ["expanded-year-refused", "+002026-06-05T09:00:00Z"],
];

function instantOf(input: string): InstantVector["expect"] {
  let ms: number;
  let canonical: string;
  try {
    ms = parseInstantMs(input);
    canonical = canonicalTime(input);
  } catch {
    return { ok: false };
  }
  return { ok: true, epoch_ms: `${ms}`, canonical, utc_day: utcDay(ms) };
}

export function buildDoc(): DatesDoc {
  return {
    forward_dates: FORWARD_INPUTS.map(([name, input]) => {
      const d = parseForwardDate(input);
      return { name, input, expect: d === null ? null : formatRFC3339UTC(d) };
    }),
    email_dates: EMAIL_INPUTS.map(([name, forward_date, received_at]) => {
      const r = emailDateOf(forward_date, received_at);
      return { name, forward_date, received_at, expect: { email_date: r.emailDate, date_source: r.dateSource } };
    }),
    instants: INSTANT_INPUTS.map(([name, input]) => ({ name, input, expect: instantOf(input) })),
  };
}

const NOTE =
  "Written by reference/ledgerd-client/scripts/gen-norm-dates-conformance.ts from the TypeScript oracle; do not hand-edit. " +
  "forward_dates: parseForwardDate(input) rendered as RFC 3339 UTC without a fraction, or null. " +
  "email_dates: the normalizer's emailDate and dateSource for a recovered inner Date (\"\" when none) and an arrival time. " +
  "instants: the wire timestamp grammar (posted_at, authored_at): epoch milliseconds as a decimal string, the canonical form, and the UTC day, or ok:false. See README.md.";

export function build(): FixtureFile[] {
  const doc = buildDoc();
  for (const section of [doc.forward_dates, doc.email_dates, doc.instants] as { name: string }[][]) {
    const names = new Set<string>();
    for (const v of section) {
      if (names.has(v.name)) throw new Error(`duplicate vector name ${v.name}`);
      names.add(v.name);
    }
  }
  return [{ file: "dates.json", text: asciiJSON({ note: NOTE, schema_version: 1, ...doc }) }];
}

export async function assertNormDatesFresh(): Promise<void> {
  await assertFresh(SUITE, build(), REGENERATE);
}

if (import.meta.main) {
  await writeOrCheck(SUITE, build(), REGENERATE);
}
