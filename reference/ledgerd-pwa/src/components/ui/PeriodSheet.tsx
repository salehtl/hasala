import { useState } from "react";
import { ChevronLeft, ChevronRight } from "./PixelIcon";
import { Dialog } from "./Dialog";
import { Button } from "./Button";
import { IconButton } from "./IconButton";
import { type Scope, addMonth, clampScope, normalizeRange } from "../../lib/scope";
import { currentPeriod, monthLabel } from "../../lib/insights";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** The one sentence a month that has not happened yet gets to say for itself. */
const NOT_YET_TITLE = "This month hasn't happened yet";

export function PeriodSheet({ scope, onApply, onClose, today = currentPeriod() }: {
  scope: Scope;
  onApply: (s: Scope) => void;
  onClose: () => void;
  /**
   * The month "now" falls in, "YYYY-MM". A parameter for the reason
   * {@link TopBar}'s is: the clock is read at the edge, once, so the rules in
   * `lib/scope` stay pure and the boundary is testable.
   */
  today?: string;
}) {
  const seed = scope.kind === "month" ? scope.period : scope.kind === "range" ? scope.to : today;
  const thisYear = Number(today.slice(0, 4));
  const [year, setYear] = useState(Number(seed.slice(0, 4)));
  const [from, setFrom] = useState<string | null>(
    scope.kind === "month" ? scope.period : scope.kind === "range" ? scope.from : null,
  );
  const [to, setTo] = useState<string | null>(
    scope.kind === "month" ? scope.period : scope.kind === "range" ? scope.to : null,
  );

  // First tap starts a single selection; the next tap closes a range; a tap
  // after a complete range starts over.
  const pick = (period: string) => {
    if (from === null || to !== null) {
      setFrom(period);
      setTo(null);
    } else {
      const r = normalizeRange(from, period);
      setFrom(r.from);
      setTo(r.to);
    }
  };

  const inSel = (period: string) => (from && to ? period >= from && period <= to : period === from);

  /**
   * Everything leaves through here, and everything is clamped on the way out.
   *
   * The grid cannot select a future month and the presets cannot reach one, so
   * this is belt and braces for one case that is real: a scope handed in from
   * storage or a link that already points past today. Applying it unchanged
   * would frame an empty screen under a confident heading.
   */
  const apply = (s: Scope) => onApply(clampScope(s, today));

  const show = () => {
    if (from && to) apply(from === to ? { kind: "month", period: from } : { kind: "range", from, to });
    else if (from) apply({ kind: "month", period: from });
  };

  const hint =
    from && to && from !== to
      ? `${monthLabel(from)}–${monthLabel(to)} selected`
      : from
        ? "Tap a second month for a range"
        : "Pick a month";

  return (
    <Dialog title="Choose period" onClose={onClose}>
      <div className="flex flex-wrap gap-2 mb-4">
        <Button variant="secondary" onClick={() => apply({ kind: "month", period: today })}>This month</Button>
        <Button variant="secondary" onClick={() => apply({ kind: "range", from: addMonth(today, -2), to: today })}>Last 3 months</Button>
        <Button variant="secondary" onClick={() => apply({ kind: "range", from: `${today.slice(0, 4)}-01`, to: today })}>Year to date</Button>
        <Button variant="secondary" onClick={() => apply({ kind: "all" })}>All time</Button>
      </div>

      <div className="flex items-center justify-between mb-3">
        <IconButton label="Previous year" onClick={() => setYear((y) => y - 1)}><ChevronLeft size={18} /></IconButton>
        <span className="text-sm font-semibold tnum">{year}</span>
        {/* Disabled, not hidden, and for the same reason the top bar's next
            chevron is: the year after this one holds no months anyone can pick. */}
        <IconButton
          label="Next year"
          disabled={year >= thisYear}
          aria-disabled={year >= thisYear}
          {...(year >= thisYear ? { title: "There's nothing after this year yet" } : {})}
          onClick={() => setYear((y) => Math.min(y + 1, thisYear))}
        >
          <ChevronRight size={18} />
        </IconButton>
      </div>

      <div className="grid grid-cols-3 gap-2 mb-4">
        {MONTHS.map((m, i) => {
          const period = `${year}-${String(i + 1).padStart(2, "0")}`;
          const selected = inSel(period);
          const isCurrent = period === today;
          // A month that has not happened yet keeps its place in the grid and
          // loses its fill: the twelve cells stay where the hand expects them,
          // and the year visibly divides into what exists and what does not.
          const future = period > today;
          return (
            <button
              key={m}
              onClick={() => pick(period)}
              disabled={future}
              aria-pressed={selected}
              {...(future ? { title: NOT_YET_TITLE } : {})}
              className={`min-h-11 rounded-[var(--radius)] text-sm font-medium transition-colors ${
                future
                  ? "bg-transparent text-muted opacity-40 cursor-not-allowed"
                  : selected
                    ? "bg-accent text-accent-fg"
                    : isCurrent
                      ? "bg-surface-2 text-fg ring-1 ring-accent/40"
                      : "bg-surface-2 text-fg hover:bg-border/60"
              }`}
            >
              {m}
            </button>
          );
        })}
      </div>

      <div className="flex items-center justify-between gap-3">
        <p className="text-xs text-muted">{hint}</p>
        <Button variant="primary" disabled={!from} onClick={show}>Show</Button>
      </div>
    </Dialog>
  );
}
