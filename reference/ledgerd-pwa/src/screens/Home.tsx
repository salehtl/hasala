import { m } from "motion/react";
import { Card } from "../components/ui/Card";
import { ProgressBar } from "../components/ui/ProgressBar";
import { Skeleton } from "../components/Skeleton";
import { EmptyState } from "../components/EmptyState";
import { RollingNumber } from "../components/RollingNumber";
import { AlertTriangle, ListOrdered } from "../components/ui/PixelIcon";
import { useFirstReveal } from "../hooks/useFirstReveal";
import { DUR, EASE_OUT } from "../lib/motion";
import { formatMinor } from "../lib/minorMoney";
import { bucketColor } from "../lib/insights";
import type { BudgetBucket, BudgetSource } from "../v2/sources/budget";
import { EMPTY_FILTERS, txnAmountLabel, txnCategoryLabel, type TxnSource } from "../v2/sources/transactions";
import { scopeBounds, scopeLabel, type Scope } from "../lib/scope";
import { useBudgetSnapshot, useBudgetSource, useTxnList, useTxnSource } from "../v2/queries";

/**
 * Home, on the local projection.
 *
 * # What this screen lost when it came off v1's HTTP API, and why
 *
 * Every widget below reads `web/src/v2/sources/*`, which read the SQLite
 * projection the sync engine writes. Four of v1's widgets had no projection
 * data behind them and were REMOVED rather than stubbed — a placeholder that
 * says "coming soon" is a promise this codebase cannot keep from here:
 *
 *   - **the pace/verdict hero and the per-bucket target bars.** They read
 *     `target`, `projection` and `month_progress` from `/api/summary`. There is
 *     no target in the v2 vocabulary: `client/src/replay/state.ts` holds
 *     `txns`, `rules`, `homeCurrency`, `rates`, `forks` and `anomalies`, and no
 *     op can author an envelope, a monthly plan or a run rate. 50/30/20 is
 *     printed as what it is — the rule — beside what actually happened.
 *   - **the pocket strip** (ready-to-assign, next bill, net worth), which read
 *     v1's plan, recurring and accounts endpoints. Same reason: no ops.
 *   - **the projects glance**, from `/api/projects`.
 *   - **the 6-month trend**, from `/api/insights/trend`.
 *
 * # The scope selector DOES reach this screen, and what it does not reach
 *
 * The top bar's period is app-wide, so every money figure here is bounded by
 * it: the hero, the income line beside it, the three bucket totals, the
 * uncategorised remainder, the "not counted yet" footnote and the recent list.
 * `sqlBudgetSource` takes a window for exactly that.
 *
 * Two things are deliberately NOT scoped, and the copy beside each says which
 * question it answers:
 *
 *   - **The plan (`50 / 30 / 20`).** It is a set of percentages, not an amount,
 *     and the projection still carries no per-period plan to vary it. It reads
 *     the same in every period because it IS the same in every period.
 *   - **"Your budget is warming up".** That sentence is about how much ledger
 *     exists, not about the month on the glass. Scoping it would make a
 *     five-year-old account claim to be warming up every time the user stepped
 *     back to a quiet month. See `BudgetSource.read`'s doc.
 *
 * The hero's label names its period, always — "Spent in Jul 2026", "Spent in
 * Jul–Aug 2026", "Spent, all time". A whole-log number under a month heading is
 * the failure this repo keeps producing (a UI sentence the code does not
 * honour), and the label is what makes it unwritable here.
 */
export interface HomeProps {
  /**
   * The app-wide period. Defaults to the whole log, which is what a caller with
   * no shell around it (a test, a story) means by omitting it — and is the one
   * value whose label makes no claim about a month.
   */
  scope?: Scope;
  onOpenProject?: (id: number) => void;
  onOpenProjects?: () => void;
  onOpenPlan?: () => void;
  onOpenRecurring?: () => void;
  onOpenReports?: () => void;
  /** Test seam: a source over a projection this test built. */
  budgetSource?: BudgetSource;
  /** Test seam: see {@link budgetSource}. */
  txnSource?: TxnSource;
}

const BUCKET_LABEL: Record<BudgetBucket, string> = { need: "Needs", want: "Wants", saving: "Savings & debt" };
const BUCKETS: BudgetBucket[] = ["need", "want", "saving"];
const RECENT_LIMIT = 5;

const ALL_TIME: Scope = { kind: "all" };

/**
 * What the hero's own label says it is counting.
 *
 * "in" reads wrong over an unbounded total, so all-time gets its own sentence
 * rather than "Spent in All time".
 */
export function spentLabel(scope: Scope): string {
  return scope.kind === "all" ? "Spent, all time" : `Spent in ${scopeLabel(scope)}`;
}

/** What an empty period is called, so "nothing here" names the period it means. */
function emptyTitle(scope: Scope): string {
  return scope.kind === "all" ? "No recent activity" : `Nothing in ${scopeLabel(scope)}`;
}

export function Home({ budgetSource, txnSource, scope = ALL_TIME }: HomeProps) {
  const budget = useBudgetSource(budgetSource);
  const txns = useTxnSource(txnSource);
  const bounds = scopeBounds(scope);
  const snapshot = useBudgetSnapshot(budget, bounds);
  // The same bounds the totals above were summed from, so the list under a
  // heading can never be a different period than the number in it.
  const recent = useTxnList(
    txns,
    { ...EMPTY_FILTERS, from: bounds.from ?? "", to: bounds.to ?? "" },
    RECENT_LIMIT,
  );
  const rows = recent.data?.rows ?? [];
  const firstReveal = useFirstReveal(rows.length > 0);

  // No v2 runtime and no injected source. This is NOT a v1 fallback: there is
  // no correct one — the projection is the data, and reaching for `/api/*`
  // here would read a different database over a protocol `ledgerd` does not
  // serve, while looking entirely fine.
  if (budget === null || txns === null) {
    return (
      <EmptyState
        icon={AlertTriangle}
        title="Your local ledger isn't open"
        hint="This screen reads the copy of your ledger on this device. Reopen the app to reconnect."
      />
    );
  }
  if (snapshot.isPending) return <Skeleton rows={8} />;
  if (snapshot.isError) {
    return <EmptyState icon={AlertTriangle} title="Couldn't read your ledger" hint="Reopen the app to try again." />;
  }

  const s = snapshot.data;
  const currency = s.homeCurrency ?? "";
  const spent = s.buckets.need + s.buckets.want + s.buckets.saving + s.unassigned;
  // Shares, not budget usage: there is no budget to be a fraction of. The bar
  // is a magnitude next to its siblings and its accessible name says so.
  //
  // The `Number` here is a RATIO, never an amount: the division happens in
  // `bigint` at four decimal places and only the bounded result (0..10000)
  // crosses into a float, so no money value is ever held in a double.
  const share = (v: bigint): number => (spent === 0n ? 0 : Number((v * 10_000n) / spent) / 10_000);

  return (
    <div className="space-y-4">
      {!s.usable ? (
        // The hero is INSIDE the usable branch, and this is the reason: when
        // `usable` is false every money field on the snapshot is a safe zero
        // placeholder ("never a real (and therefore misleading) partial
        // total", `sources/budget.ts`), and printing a placeholder in the
        // largest type on the screen tells a user they have spent nothing.
        // A rebuilding projection has no headline number to show, so it shows
        // none.
        <Card>
          <p className="text-sm">
            Your budget is rebuilding after an update. Nothing was lost — it will be back once the local sync finishes.
          </p>
        </Card>
      ) : (
        <>
          {/* hero: what has actually gone out, in the home currency — the one
              bold, branded surface; everything below stays quiet on neutral
              cards. */}
          <div className="rounded-[var(--radius)] bg-hero text-hero-fg p-5">
            <p className="text-sm opacity-80">{spentLabel(scope)}{currency ? ` · ${currency}` : ""}</p>
            <p className="mt-1 text-[2.75rem] leading-none font-semibold tracking-[-0.02em] tnum">
              <RollingNumber value={formatMinor(spent)} />
            </p>
            <p className="text-sm opacity-80 mt-2">
              against <span className="tnum">{formatMinor(s.income)}</span> in
            </p>
          </div>

          {s.warming && (
            <Card>
              <p className="text-sm">
                Your budget is warming up. After 14 days or 10 confirmed transactions this settles into a steadier view.
              </p>
            </Card>
          )}

          {/* The plan beside the money, with each bucket's share of what was
              spent. Still not a target — nothing in the log holds one — but the
              three percentages are now the user's if they chose them, and
              50/30/20 if they did not (`sources/budget.ts`). */}
          <Card>
            <p className="text-sm font-medium mb-3">{`${s.split.need} / ${s.split.want} / ${s.split.saving}`}</p>
            <div className="space-y-4">
              {BUCKETS.map((bucket) => (
                <div key={bucket}>
                  <div className="flex items-center justify-between text-sm mb-1.5">
                    <span className="flex items-center gap-2 font-medium">
                      <span
                        className="inline-block w-2.5 h-2.5 rounded-[var(--radius)]"
                        style={{ background: bucketColor(bucket) }}
                      />
                      {BUCKET_LABEL[bucket]}
                    </span>
                    <span className="tnum text-muted">{formatMinor(s.buckets[bucket])}</span>
                  </div>
                  {/*
                    `status="under"` — the neutral ink — because this bar is a
                    SHARE and not a budget. `pct` here is one bucket's share of
                    spending, so a
                    month where everything went into Needs is `pct === 1.0` —
                    and with no status `derivePaceStatus` reads that
                    geometrically, returns "overbudget", and paints the bar in
                    the over-budget red. Nothing was over anything: this account
                    has no budget for the bar to exceed, and the plan percentage
                    is stated underneath it as its own line. Red here is the app
                    telling a user they overspent a limit they never set.
                  */}
                  <ProgressBar
                    pct={share(s.buckets[bucket])}
                    status="under"
                    label={`${BUCKET_LABEL[bucket]} share of spending`}
                  />
                  <div className="flex items-center justify-between mt-1.5 text-xs">
                    <span className="text-muted">{s.split[bucket]}% of the plan</span>
                    <span className="tnum text-muted">{Math.round(share(s.buckets[bucket]) * 100)}% of spending</span>
                  </div>
                </div>
              ))}
            </div>
            {s.unassigned !== 0n && (
              <p className="text-xs text-warn mt-3 pt-3 border-t border-border">
                <span className="tnum">{formatMinor(s.unassigned)}</span> is uncategorized and sits outside the three
                buckets. Categorize it before treating these as complete.
              </p>
            )}
          </Card>

          {/* What the numbers deliberately leave out. §3.7's null rate is a
              waiting state, not a zero, so it is named rather than absorbed. */}
          {(s.excluded.missingHomeRate > 0 || s.excluded.unresolvedDuplicates > 0 || s.excluded.unparsed > 0) && (
            <Card>
              <p className="text-sm font-medium mb-2">Not counted yet</p>
              <ul className="space-y-1 text-xs text-muted">
                {s.excluded.missingHomeRate > 0 && (
                  <li className="text-warn">
                    {s.excluded.missingHomeRate} transaction{s.excluded.missingHomeRate === 1 ? " is" : "s are"} missing
                    a home-currency rate.
                  </li>
                )}
                {s.excluded.unresolvedDuplicates > 0 && (
                  <li className="text-warn">
                    {s.excluded.unresolvedDuplicates} possible duplicate
                    {s.excluded.unresolvedDuplicates === 1 ? " needs" : "s need"} review.
                  </li>
                )}
                {s.excluded.unparsed > 0 && (
                  <li>
                    {s.excluded.unparsed} message{s.excluded.unparsed === 1 ? " couldn't" : "s couldn't"} be read.
                  </li>
                )}
              </ul>
            </Card>
          )}
        </>
      )}

      {/* recent stream */}
      <Card>
        <p className="text-sm font-medium mb-2">Recent</p>
        {rows.length === 0 ? (
          <EmptyState
            icon={ListOrdered}
            title={emptyTitle(scope)}
            hint={
              scope.kind === "all"
                ? "New transactions will appear here."
                : "Nothing was posted in this period. Change the period in the bar above to look elsewhere."
            }
          />
        ) : (
          <ul className="divide-y divide-border">
            {rows.map((t, i) => {
              const amount = txnAmountLabel(t);
              return (
                <m.li
                  key={t.id}
                  // `initial={false}` — not a hidden state — is what keeps the
                  // cascade one-shot. On a refetch Framer adopts `animate` as
                  // the starting value and plays nothing, so the list cannot
                  // re-deal itself every time the query revalidates.
                  //
                  // TRANSFORM ONLY — no `opacity: 0` here, deliberately, and do
                  // not add one. `LazyMotion` loads its feature bundle in an
                  // effect, and until that promise settles `m.*` renders
                  // straight from `initial` with no animation running. An
                  // `opacity: 0` resting state therefore means these rows paint
                  // *invisible* until a separate chunk has been fetched and
                  // executed. A `y` offset degrades to "8px low for a moment"
                  // instead of "gone".
                  initial={firstReveal ? { y: 8 } : false}
                  animate={{ y: 0 }}
                  // The cap reproduces the retired `:nth-child(n+7)` rule.
                  transition={{ duration: DUR.sheet, ease: EASE_OUT, delay: Math.min(i * 0.04, 0.24) }}
                  className="py-2 flex items-center justify-between gap-3"
                >
                  <div className="min-w-0">
                    <p className="truncate font-medium">{t.merchant_raw || "—"}</p>
                    <p className="text-xs text-muted">
                      {t.posted_at.slice(0, 10)} · {txnCategoryLabel(t)}
                      {t.currency !== "" && t.currency !== currency ? ` · ${t.currency}` : ""}
                      {!t.unparsed && t.amount_home_minor === null ? ` · no ${currency || "home"} rate` : ""}
                    </p>
                  </div>
                  <span
                    className={`tnum ${amount.unreadable ? "text-muted" : ""}`}
                    style={amount.flow === "in" ? { color: "var(--color-good)" } : undefined}
                    title={amount.flow === "in" ? "Money in" : amount.flow === "out" ? "Money out" : "Nothing could be read"}
                  >
                    {amount.text}
                  </span>
                </m.li>
              );
            })}
          </ul>
        )}
      </Card>
    </div>
  );
}
