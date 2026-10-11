import { describe, it, expect } from "vitest";
import {
  addMonth,
  canStepForward,
  clampScope,
  insightsFocus,
  isCurrentMonth,
  normalizeRange,
  scopeAnchor,
  scopeBounds,
  scopeLabel,
} from "./scope";
import { currentPeriod } from "./insights";

describe("addMonth", () => {
  it("steps within and across year boundaries", () => {
    expect(addMonth("2026-06", 1)).toBe("2026-07");
    expect(addMonth("2026-06", -1)).toBe("2026-05");
    expect(addMonth("2026-12", 1)).toBe("2027-01");
    expect(addMonth("2026-01", -1)).toBe("2025-12");
  });
});

describe("normalizeRange", () => {
  it("orders the two endpoints ascending", () => {
    expect(normalizeRange("2026-06", "2026-03")).toEqual({ from: "2026-03", to: "2026-06" });
    expect(normalizeRange("2026-03", "2026-06")).toEqual({ from: "2026-03", to: "2026-06" });
  });
});

describe("scopeBounds", () => {
  it("brackets a single month", () => {
    expect(scopeBounds({ kind: "month", period: "2026-06" })).toEqual({ from: "2026-06-01", to: "2026-06-32" });
  });
  it("brackets a range from first day to last-plus-one day", () => {
    expect(scopeBounds({ kind: "range", from: "2026-03", to: "2026-06" })).toEqual({ from: "2026-03-01", to: "2026-06-32" });
  });
  it("returns no bounds for all time", () => {
    expect(scopeBounds({ kind: "all" })).toEqual({});
  });
});

describe("scopeAnchor", () => {
  it("is the month itself, the range end, or the current month for all", () => {
    expect(scopeAnchor({ kind: "month", period: "2026-04" })).toBe("2026-04");
    expect(scopeAnchor({ kind: "range", from: "2026-03", to: "2026-06" })).toBe("2026-06");
    expect(scopeAnchor({ kind: "all" })).toBe(currentPeriod());
  });
});

describe("scopeLabel", () => {
  it("labels a single month", () => {
    expect(scopeLabel({ kind: "month", period: "2026-06" })).toBe("Jun 2026");
  });
  it("labels a same-year range compactly", () => {
    expect(scopeLabel({ kind: "range", from: "2026-03", to: "2026-06" })).toBe("Mar–Jun 2026");
  });
  it("labels a cross-year range with both years", () => {
    expect(scopeLabel({ kind: "range", from: "2025-12", to: "2026-02" })).toBe("Dec 2025 – Feb 2026");
  });
  it("labels all time", () => {
    expect(scopeLabel({ kind: "all" })).toBe("All time");
  });
});

describe("insightsFocus", () => {
  it("returns the month with no note for a month scope", () => {
    expect(insightsFocus({ kind: "month", period: "2026-03" })).toEqual({ period: "2026-03", note: "" });
  });
  it("returns the latest month of a range with a note", () => {
    expect(insightsFocus({ kind: "range", from: "2026-01", to: "2026-04" })).toEqual({ period: "2026-04", note: "latest in range" });
  });
  it("returns the current month with a note for all-time", () => {
    expect(insightsFocus({ kind: "all" })).toEqual({ period: currentPeriod(), note: "current month" });
  });
});

// ---------------------------------------------------------------------------
// The future bound. `today` is a parameter in every one of these, so a test can
// pin it; nothing below reads the clock.
// ---------------------------------------------------------------------------

const TODAY = "2026-08";

describe("clampScope", () => {
  it("leaves a past month alone", () => {
    expect(clampScope({ kind: "month", period: "2026-03" }, TODAY)).toEqual({ kind: "month", period: "2026-03" });
  });
  it("leaves the current month alone", () => {
    expect(clampScope({ kind: "month", period: TODAY }, TODAY)).toEqual({ kind: "month", period: TODAY });
  });
  it("pulls a future month back to the current one", () => {
    expect(clampScope({ kind: "month", period: "2026-09" }, TODAY)).toEqual({ kind: "month", period: TODAY });
    expect(clampScope({ kind: "month", period: "2031-01" }, TODAY)).toEqual({ kind: "month", period: TODAY });
  });
  it("trims a range that runs past the current month", () => {
    expect(clampScope({ kind: "range", from: "2026-05", to: "2026-12" }, TODAY)).toEqual({
      kind: "range",
      from: "2026-05",
      to: TODAY,
    });
  });
  it("leaves a range that ends in the past alone", () => {
    expect(clampScope({ kind: "range", from: "2026-01", to: "2026-04" }, TODAY)).toEqual({
      kind: "range",
      from: "2026-01",
      to: "2026-04",
    });
  });
  it("collapses a range that is entirely in the future to the current month", () => {
    expect(clampScope({ kind: "range", from: "2026-10", to: "2026-12" }, TODAY)).toEqual({
      kind: "month",
      period: TODAY,
    });
  });
  it("collapses a range trimmed down to one month", () => {
    expect(clampScope({ kind: "range", from: TODAY, to: "2026-11" }, TODAY)).toEqual({ kind: "month", period: TODAY });
  });
  it("leaves all-time alone — it already ends at what exists", () => {
    expect(clampScope({ kind: "all" }, TODAY)).toEqual({ kind: "all" });
  });
});

describe("canStepForward", () => {
  it("is true for a month before the current one", () => {
    expect(canStepForward({ kind: "month", period: "2026-07" }, TODAY)).toBe(true);
  });
  it("is false on the current month", () => {
    expect(canStepForward({ kind: "month", period: TODAY }, TODAY)).toBe(false);
  });
  it("is false for a month already past the current one", () => {
    expect(canStepForward({ kind: "month", period: "2026-09" }, TODAY)).toBe(false);
  });
  it("is false for range and all-time, which have no stepper", () => {
    expect(canStepForward({ kind: "range", from: "2026-01", to: "2026-02" }, TODAY)).toBe(false);
    expect(canStepForward({ kind: "all" }, TODAY)).toBe(false);
  });
});

describe("isCurrentMonth", () => {
  it("is true only for the month scope naming the current month", () => {
    expect(isCurrentMonth({ kind: "month", period: TODAY }, TODAY)).toBe(true);
    expect(isCurrentMonth({ kind: "month", period: "2026-07" }, TODAY)).toBe(false);
    expect(isCurrentMonth({ kind: "range", from: TODAY, to: TODAY }, TODAY)).toBe(false);
    expect(isCurrentMonth({ kind: "all" }, TODAY)).toBe(false);
  });
});
