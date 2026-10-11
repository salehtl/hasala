import { useState } from "react";
import { ChevronLeft, ChevronRight, Settings as SettingsIcon } from "./PixelIcon";
import { type Scope, addMonth, canStepForward, clampScope, isCurrentMonth, scopeLabel } from "../../lib/scope";
import { currentPeriod } from "../../lib/insights";
import { IconButton } from "./IconButton";
import { Pressable } from "./Pressable";
import { PeriodSheet } from "./PeriodSheet";

/**
 * Why the next-month control is disabled rather than removed.
 *
 * A control that vanishes is a control the user thinks they broke — they were
 * aiming at it, it is gone, and nothing on the screen says why. Disabled keeps
 * the target where it was and hands the reason over on hover/long-press and to
 * a screen reader.
 */
export const NO_FUTURE_TITLE = "Next month hasn't happened yet";

export function TopBar({ title, scope, onScopeChange, showScope, onOpenSettings, today = currentPeriod() }: {
  title: string;
  scope: Scope;
  onScopeChange: (s: Scope) => void;
  showScope: boolean;
  /** Settings is not a tab: the gear here is its one persistent entry point. */
  onOpenSettings?: () => void;
  /**
   * The month "now" falls in, "YYYY-MM". A parameter so a test and a story can
   * pin it; production takes the default and reads the clock exactly once per
   * render, here, rather than inside the pure rules in `lib/scope`.
   */
  today?: string;
}) {
  const [open, setOpen] = useState(false);
  const isMonth = scope.kind === "month";
  const forward = canStepForward(scope, today);
  // Only when it would DO something. A Today button on the current month is a
  // button that does nothing, which is worse than no button at all.
  const showToday = !isCurrentMonth(scope, today);

  return (
    <header className="shrink-0 bg-bg pt-[env(safe-area-inset-top)]">
      <div className="min-h-[48px] px-4 flex items-center justify-between gap-3">
        {/*
          The title yields to the controls, and below 360px it yields entirely.

          Measured, not guessed. At 320px the control cluster is 274px wide of
          the 288px this row has, and adding the Today button took the heading
          from 56px ("Transa…") to 2px — a stray ellipsis in the corner, which
          looks like damage rather than like a truncation. So on the narrowest
          phones the heading goes `sr-only`: it stays in the accessibility tree
          and out of the layout, and the screen keeps a visible name because
          `BottomNav` already renders the active tab in bold under a tick. It is
          the one element in this row that is said twice.

          Only when there are controls to make room for. A bar with no period
          cluster has the width and keeps its heading at every size.

          `shrink-0` on the cluster, and `truncate` on the heading so its flex
          min-width resolves to 0: the other way round spends a 44px tap target
          on a long word.
        */}
        <h1
          className={`text-base font-semibold tracking-[-0.015em] truncate ${
            showScope ? "max-[359px]:sr-only" : ""
          }`}
        >
          {title}
        </h1>
        <div className="flex shrink-0 items-center gap-0.5">
          {showScope && (
            <>
              {showToday && (
                /*
                  The return-to-now escape hatch.

                  Typographically the period label's quiet sibling — same mono
                  micro-caps register, because it names a period too — but
                  unfilled and `text-muted`, so the loud element in the cluster
                  stays the thing that says where you ARE. It enters with a 6px
                  slide from the right, the direction the stepper walks, so it
                  reads as arriving from the months it skips over.

                  Transform only, never `opacity: 0` as a resting state:
                  `LazyMotion` loads its feature bundle in an effect and until
                  that promise settles `m.*` paints straight from `initial`, so
                  an opacity resting state means an invisible button until a
                  second chunk has been fetched. See the same note in Home.tsx.
                */
                <Pressable
                  onClick={() => onScopeChange({ kind: "month", period: today })}
                  initial={{ x: 6 }}
                  animate={{ x: 0 }}
                  className="min-h-11 px-2 rounded-[var(--radius)] font-mono text-[10px] font-medium uppercase tracking-[0.12em] text-muted hover:text-fg hover:bg-surface-2 transition-colors"
                >
                  Today
                </Pressable>
              )}
              {isMonth && (
                <IconButton
                  label="Previous month"
                  onClick={() => onScopeChange({ kind: "month", period: addMonth(scope.period, -1) })}
                >
                  <ChevronLeft size={18} />
                </IconButton>
              )}
              <Pressable
                onClick={() => setOpen(true)}
                aria-haspopup="dialog"
                aria-expanded={open}
                className="min-h-11 px-3 py-1.5 rounded-[var(--radius)] font-mono text-[10px] font-medium uppercase tracking-[0.12em] bg-surface-2 text-fg truncate"
              >
                {scopeLabel(scope)}
              </Pressable>
              {isMonth && (
                <IconButton
                  label="Next month"
                  disabled={!forward}
                  aria-disabled={!forward}
                  {...(forward ? {} : { title: NO_FUTURE_TITLE })}
                  onClick={() => onScopeChange({ kind: "month", period: addMonth(scope.period, 1) })}
                >
                  <ChevronRight size={18} />
                </IconButton>
              )}
            </>
          )}
          {onOpenSettings && (
            <IconButton label="Settings" onClick={onOpenSettings}>
              <SettingsIcon size={18} />
            </IconButton>
          )}
        </div>
      </div>
      {open && (
        <PeriodSheet
          scope={scope}
          today={today}
          // Clamped here as well as inside the sheet: this is the one place
          // every scope change from the bar passes through, so a preset added
          // to the sheet later cannot get a future period past it.
          onApply={(s) => { onScopeChange(clampScope(s, today)); setOpen(false); }}
          onClose={() => setOpen(false)}
        />
      )}
    </header>
  );
}
