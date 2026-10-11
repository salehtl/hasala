import { describe, expect, it, vi } from "vitest";
import { renderHook } from "@testing-library/react";
import type { PanInfo } from "motion/react";

import { EDGE_STRIP_TESTID, useEdgeBack } from "./useEdgeBack";

/**
 * The hook is the ONE implementation of edge-swipe-back in the app: the
 * Settings drill-in shell and the boot gate's enrolment wall both mount it, so
 * the gesture cannot drift between a surface you can leave and one you cannot.
 *
 * The pure decision (how far / how fast commits) is `lib/edgeBack.ts`'s and is
 * tested there. What is tested here is the wiring the two call sites share:
 * that a release is put through that decision at all, against the measured
 * width, and that the strip stays a marker rather than a thing in the way.
 */
function info(offsetX: number, velocityX = 0): PanInfo {
  return { point: { x: 0, y: 0 }, delta: { x: 0, y: 0 }, offset: { x: offsetX, y: 0 }, velocity: { x: velocityX, y: 0 } };
}

describe("useEdgeBack", () => {
  it("does not go back on a drag that never reached the commit distance", () => {
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeBack(onBack));
    // No element is mounted, so the width falls back to the window's (1024 in
    // jsdom); a third of that is ~341.
    result.current.dragProps.onDragEnd(null, info(120));
    expect(onBack).not.toHaveBeenCalled();
  });

  it("goes back once the drag passes a third of the width", () => {
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeBack(onBack));
    result.current.dragProps.onDragEnd(null, info(400));
    expect(onBack).toHaveBeenCalledTimes(1);
  });

  it("goes back on a rightward flick that travelled far enough to be one", () => {
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeBack(onBack));
    result.current.dragProps.onDragEnd(null, info(60, 900));
    expect(onBack).toHaveBeenCalledTimes(1);
  });

  it("never goes back on a leftward drag", () => {
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeBack(onBack));
    result.current.dragProps.onDragEnd(null, info(-400, -900));
    expect(onBack).not.toHaveBeenCalled();
  });

  it("calls the CURRENT handler, not the one captured on first render", () => {
    const first = vi.fn();
    const second = vi.fn();
    let handler = first;
    const { result, rerender } = renderHook(() => useEdgeBack(handler));
    handler = second;
    rerender();
    result.current.dragProps.onDragEnd(null, info(400));
    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledTimes(1);
  });

  /**
   * The strip is a marker for the harness to grab, never a surface. It was a
   * real 24px `touch-none` column once, and it cost a dead left edge on every
   * back arrow and a left side of the screen that would not scroll — both
   * measured by `harness/v2edge.mjs`.
   */
  it("keeps the strip inert to pointers and to touch-action", () => {
    const { result } = renderHook(() => useEdgeBack(vi.fn()));
    const strip = result.current.stripProps;
    expect(strip["data-testid"]).toBe(EDGE_STRIP_TESTID);
    expect(strip["aria-hidden"]).toBe(true);
    expect(strip.className).toContain("pointer-events-none");
    expect(strip.className).not.toContain("touch-none");
  });

  /** Rightward only: there is nothing to the left of a full-screen page. */
  it("clamps the leftward pull instead of tracking it", () => {
    const { result } = renderHook(() => useEdgeBack(vi.fn()));
    expect(result.current.dragProps.dragElastic).toEqual({ left: 0, right: 0.9 });
    expect(result.current.dragProps.dragListener).toBe(false);
  });
});
