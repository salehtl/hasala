import { currentPeriod, monthLabel } from "./insights";
import { monthRange } from "./transactions";

/** The app-wide time scope. Periods are "YYYY-MM". */
export type Scope =
  | { kind: "month"; period: string }
  | { kind: "range"; from: string; to: string } // both "YYYY-MM", from <= to
  | { kind: "all" };

export const DEFAULT_SCOPE: Scope = { kind: "month", period: currentPeriod() };

/** Add `delta` months to a "YYYY-MM" period (UTC-safe, wraps years). */
export function addMonth(period: string, delta: number): string {
  const [y, m] = period.split("-").map(Number);
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

// ---------------------------------------------------------------------------
// The future bound
//
// A ledger is a record of what happened, so a scope pointing past the current
// month can only ever frame an empty screen under a confident heading. The rule
// lives HERE, as three pure functions, because the top bar's stepper and the
// period sheet's grid both need it and a second copy would drift the moment one
// of them changed.
//
// **`today` is a parameter, never `currentPeriod()` read inside.** A helper with
// a clock in it is a helper whose tests cannot pin it, and the only thing worth
// testing about a bound is what it does at the boundary. Callers pass
// `currentPeriod()`.
// ---------------------------------------------------------------------------

/** Whether `scope` is exactly the month `today` names. Governs the Today button. */
export function isCurrentMonth(scope: Scope, today: string): boolean {
  return scope.kind === "month" && scope.period === today;
}

/**
 * Whether the next-month control has anywhere to go.
 *
 * False for `range` and `all` because neither shows a stepper: they are not a
 * position on a line, and answering "true" would describe a control that is not
 * on the screen.
 */
export function canStepForward(scope: Scope, today: string): boolean {
  return scope.kind === "month" && scope.period < today;
}

/**
 * `scope` with nothing in it later than `today`.
 *
 * A range trimmed down to a single month is returned AS a month scope, not as a
 * one-month range: the two render differently (a stepper appears, the label
 * loses its dash) and a range whose ends are equal is a month wearing the wrong
 * type. A range wholly in the future has no non-empty answer but the current
 * month, so that is what it collapses to.
 *
 * `all` is already bounded by what exists and is returned unchanged.
 */
export function clampScope(scope: Scope, today: string): Scope {
  if (scope.kind === "all") return scope;
  if (scope.kind === "month") return scope.period <= today ? scope : { kind: "month", period: today };
  const from = scope.from <= today ? scope.from : today;
  const to = scope.to <= today ? scope.to : today;
  return from === to ? { kind: "month", period: from } : { kind: "range", from, to };
}

/** Order two periods ascending. */
export function normalizeRange(a: string, b: string): { from: string; to: string } {
  return a <= b ? { from: a, to: b } : { from: b, to: a };
}

/**
 * A period as two inclusive `YYYY-MM-DD` day bounds, either of which may be
 * absent for "unbounded on that side". `{}` is the whole log.
 *
 * This is the shape the scope crosses into the data layer as — the budget
 * source, the review lanes and the transaction list all take one — so it lives
 * beside the scope that produces it rather than in whichever source needed it
 * first.
 */
export interface DateWindow {
  from?: string;
  to?: string;
}

/**
 * Inclusive query bounds for the transactions list. month/range reuse the
 * day-"32" upper bound (see monthRange) so timestamped posted_at on the last
 * day still matches; "all" returns no bounds.
 */
export function scopeBounds(scope: Scope): DateWindow {
  if (scope.kind === "all") return {};
  if (scope.kind === "month") return monthRange(scope.period);
  return { from: `${scope.from}-01`, to: `${scope.to}-32` };
}

/** The single month the monthly views (Home, Insights) should show. */
export function scopeAnchor(scope: Scope): string {
  if (scope.kind === "month") return scope.period;
  if (scope.kind === "range") return scope.to;
  return currentPeriod();
}

export interface InsightsFocus { period: string; note: string; }

/** The single month Insights evaluates, plus a qualifier when the scope spans more than one month. */
export function insightsFocus(scope: Scope): InsightsFocus {
  if (scope.kind === "month") return { period: scope.period, note: "" };
  if (scope.kind === "range") return { period: scope.to, note: "latest in range" };
  return { period: currentPeriod(), note: "current month" };
}

/** Human label: "Jun 2026" · "Mar–Jun 2026" · "Dec 2025 – Feb 2026" · "All time". */
export function scopeLabel(scope: Scope): string {
  if (scope.kind === "all") return "All time";
  if (scope.kind === "month") return `${monthLabel(scope.period)} ${scope.period.slice(0, 4)}`;
  const fy = scope.from.slice(0, 4), ty = scope.to.slice(0, 4);
  return fy === ty
    ? `${monthLabel(scope.from)}–${monthLabel(scope.to)} ${ty}`
    : `${monthLabel(scope.from)} ${fy} – ${monthLabel(scope.to)} ${ty}`;
}
