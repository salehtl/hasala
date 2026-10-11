import { useCallback, useRef, useState, type ReactNode } from "react";
import { AnimatePresence, m } from "motion/react";
import { ArrowLeft } from "../../components/ui/PixelIcon";
import { IconButton } from "../../components/ui/IconButton";
import { SHEET_ENTER, SHEET_EXIT } from "../../lib/motion";
import { useEdgeBack } from "../../hooks/useEdgeBack";

/**
 * Shared full-screen drill-in shell for a Settings subpage: a back-arrow
 * header over a scrolling body, the same shape v1's Settings drill-ins used
 * before that cluster was retired (2026-08-10; git history has it).
 * `headerRight` hosts the page's autosave feedback.
 *
 * The shell slides in from the right and supports iOS-style edge-swipe-back:
 * a drag starting in the 24px left-edge strip tracks the finger and reveals
 * the screen underneath; the back arrow and a committed drag both play the
 * slide-out before onClose unmounts the page. Reduced motion is the global
 * MotionConfig's business: it drops the slide and leaves the rest alone.
 */
export function SettingsPage({
  title,
  onClose,
  headerRight,
  covered = false,
  children,
}: {
  title: string;
  onClose: () => void;
  headerRight?: ReactNode;
  /** A deeper panel is open over this one: take its header out of the tab order. */
  covered?: boolean;
  children: ReactNode;
}) {
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  // Same lifecycle as Dialog: the page owns its exit and the parent is only
  // told to unmount once AnimatePresence says the slide-out has finished.
  // Closing twice is `setOpen(false)` twice, so no double-close guard is
  // needed — onExitComplete fires exactly once per exit.
  const [open, setOpen] = useState(true);
  const requestClose = useCallback(() => setOpen(false), []);
  // The gesture is the app's one implementation, shared with the boot gate's
  // enrolment wall. See `hooks/useEdgeBack.ts`.
  const { dragProps, stripProps } = useEdgeBack(requestClose);

  return (
    <AnimatePresence onExitComplete={() => onCloseRef.current()}>
      {open && (
        <m.div
          {...dragProps}
          // `initial` is committed as the first render's inline style, so the
          // offscreen start state is there before the first paint and needs no
          // flush. That is what the hand-rolled version used `void offsetHeight`
          // for and still got wrong in WebKit, which left the panel parked
          // off-screen and then snapped it in (see Dialog).
          initial={{ x: "100%" }}
          animate={{ x: 0 }}
          // Exit transition on the exit target: Framer has no `transition.exit`
          // key, so the shorter slide-out has to be declared here (see Dialog).
          exit={{ x: "100%", transition: SHEET_EXIT }}
          transition={SHEET_ENTER}
          className="fixed inset-0 z-40 bg-bg flex flex-col"
        >
          {/*
            The edge-back gesture is armed from the PANEL, and the strip is a
            marker the harness can grab rather than a thing in the way.

            It used to be a real 24px column with `touch-none` on it, sitting
            over the whole left side. Two measured costs, both from
            `harness/v2edge.mjs`:

             - **Nothing scrolled from that column.** `touch-none` tells the
               browser not to pan, and the strip is a SIBLING of the scrolling
               body rather than inside it, so even `pan-y` would have had no
               scrollable ancestor to pan. A thumb landing near the left edge
               and dragging up moved nothing: scrollTop 0 -> 0 with 3247px of
               room.
             - **It covered the left half of the back arrow**, which starts at
               x=8 because of its `-ml-2`. A press there began a drag that never
               moved and the click that followed landed on an `aria-hidden` div
               with no handler.

            So the strip is `pointer-events-none` and the arming moved to the
            panel's own `onPointerDown`, gated by the same `inEdgeZone`.
            `pointerdown` bubbles, so a press anywhere still reaches it, and
            `dragListener={false}` means only this call can start a drag.
            Framer puts `touch-action: pan-y` on the draggable panel itself,
            which is exactly the contract we want everywhere rather than in one
            column: vertical belongs to the browser, horizontal to the gesture.

            Both the arming and this marker now come from `useEdgeBack`, so the
            enrolment wall cannot end up with a different gesture from this one.
          */}
          <div {...stripProps} />
          {/* `covered` marks only the header inert, never the body: a nested panel
              renders inside the body, so making that inert would disable the very
              page sitting on top. Its own content handles its own inertness. */}
          {/* This panel is `fixed inset-0`, so it covers TopBar and BottomNav and
              inherits none of their safe-area padding. Without these insets the
              back arrow sits under the notch and the last row under the home
              indicator on every drill-in screen. */}
          {/* `relative z-20` puts the header ABOVE the activation strip.
              Without it the strip's 24px column covered the left half of the
              back arrow — which starts at x=8 because of its `-ml-2` — so a
              press there began a drag that never moved and the click that
              followed landed on an `aria-hidden` div with no handler. The
              most-tapped control on every drill-in had a dead left edge, and
              `audit.mjs` could not see it: `control-obscured` tests a control's
              CENTRE point, and the centre was always clear. */}
          <header
            className="relative z-20 flex items-center gap-3 px-4 pt-[max(1rem,env(safe-area-inset-top))] pb-3 border-b border-border"
            inert={covered}
          >
            <IconButton label={`Back from ${title}`} className="-ml-2" onClick={requestClose}>
              <ArrowLeft size={20} />
            </IconButton>
            <h1 className="flex-1 text-lg font-semibold text-fg">{title}</h1>
            {headerRight}
          </header>
          <div className="flex-1 overflow-y-auto px-4 pt-4 pb-[max(1rem,env(safe-area-inset-bottom))] space-y-6 max-w-screen-sm w-full mx-auto">
            {children}
          </div>
        </m.div>
      )}
    </AnimatePresence>
  );
}
