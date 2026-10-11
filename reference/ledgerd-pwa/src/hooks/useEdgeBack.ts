/**
 * The app's ONE edge-swipe-back wiring, shared by every full-screen surface
 * that can be left: the Settings drill-in shell (`SettingsPage`) and the boot
 * gate's enrolment wall (`v2/UnenrolledWall`).
 *
 * It exists as a hook rather than as a shell component because the two surfaces
 * are not the same shape — a drill-in slides in from the right and owns its own
 * exit through `AnimatePresence`, while a wall is the page and has no layer
 * behind it to slide off. What they must share is the *gesture*: where a back
 * drag may start, how far it must travel, and what a release decides. Two
 * copies of that would drift, and the one that drifted would be the surface a
 * user is stuck on.
 *
 * The pure decision lives in `lib/edgeBack.ts` (`inEdgeZone`, `shouldGoBack`)
 * and is unit-tested there; this is the Framer wiring around it, tested in
 * `useEdgeBack.test.ts`. Framer's drag cannot be driven meaningfully in jsdom,
 * so the real gesture is verified by `harness/v2edge.mjs`.
 */

import { useCallback, useMemo, useRef, type PointerEvent as ReactPointerEvent, type RefObject } from "react";
import { useDragControls, type PanInfo } from "motion/react";

import { inEdgeZone, shouldGoBack } from "../lib/edgeBack";

/** The marker the harness grabs. One literal, so both surfaces answer to it. */
export const EDGE_STRIP_TESTID = "edge-back-strip";

/**
 * The strip is `pointer-events-none` and carries no `touch-none`, and both
 * halves of that are load-bearing.
 *
 * It used to be a real 24px `touch-none` column down the whole left side, and
 * `harness/v2edge.mjs` measured two costs: nothing scrolled from that column
 * (the strip is a sibling of the scroller, so `touch-none` left the gesture
 * with no scrollable ancestor to pan), and it covered the left half of the back
 * arrow, which starts at x=8 because of its `-ml-2` — a press there began a
 * drag that never moved and the click landed on an `aria-hidden` div. The
 * arming moved to the panel's own `onPointerDown`, and the strip became a
 * marker and nothing else.
 */
const EDGE_STRIP_CLASS = "pointer-events-none absolute left-0 inset-y-0 w-6 z-10";

export interface EdgeBackStripProps {
  "aria-hidden": true;
  "data-testid": string;
  className: string;
}

export interface EdgeBackDragProps {
  ref: RefObject<HTMLDivElement | null>;
  drag: "x";
  dragControls: ReturnType<typeof useDragControls>;
  dragListener: false;
  dragConstraints: { left: number; right: number };
  dragElastic: { left: number; right: number };
  dragMomentum: false;
  onDragEnd: (event: unknown, info: PanInfo) => void;
  onPointerDown: (event: ReactPointerEvent<HTMLElement>) => void;
}

export interface EdgeBack {
  /** Spread onto the `m.div` that IS the full-screen surface. */
  dragProps: EdgeBackDragProps;
  /** Spread onto a bare `<div>` inside it, under a `relative` ancestor. */
  stripProps: EdgeBackStripProps;
}

/**
 * @param onBack What a committed back gesture asks for. It is read through a
 * ref at release time, so a surface may change its mind about what "back" means
 * (a drill-in plays its exit; the wall opens a confirm) without re-arming the
 * gesture on every render.
 */
export function useEdgeBack(onBack: () => void): EdgeBack {
  const panelRef = useRef<HTMLDivElement>(null);
  const onBackRef = useRef(onBack);
  onBackRef.current = onBack;
  const dragControls = useDragControls();

  const onDragEnd = useCallback((_event: unknown, info: PanInfo) => {
    // jsdom reports offsetWidth 0; the window is the only other measure there.
    const width = panelRef.current?.offsetWidth || window.innerWidth;
    if (shouldGoBack(info.offset.x, info.velocity.x, width)) onBackRef.current();
  }, []);

  const onPointerDown = useCallback(
    (event: ReactPointerEvent<HTMLElement>) => {
      // `pointerdown` bubbles, so a press anywhere on the surface reaches this;
      // `dragListener={false}` means only this call can start a drag.
      if (inEdgeZone(event.clientX)) dragControls.start(event);
    },
    [dragControls],
  );

  return useMemo(
    () => ({
      dragProps: {
        ref: panelRef,
        drag: "x",
        dragControls,
        dragListener: false,
        dragConstraints: { left: 0, right: 0 },
        // Rightward only: there is nothing to the left to reveal, so a leftward
        // pull is clamped rather than tracked.
        dragElastic: { left: 0, right: 0.9 },
        dragMomentum: false,
        onDragEnd,
        onPointerDown,
      },
      stripProps: { "aria-hidden": true, "data-testid": EDGE_STRIP_TESTID, className: EDGE_STRIP_CLASS },
    }),
    [dragControls, onDragEnd, onPointerDown],
  );
}
