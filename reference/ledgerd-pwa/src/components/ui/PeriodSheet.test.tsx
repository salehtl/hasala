import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { PeriodSheet } from "./PeriodSheet";
import { currentPeriod } from "../../lib/insights";
import type { Scope } from "../../lib/scope";

/** Pinned, so the future bound is tested at its boundary and not at the clock's. */
const TODAY = "2026-08";

function open(onApply: (s: Scope) => void, scope: Scope = { kind: "month", period: "2026-06" }) {
  render(<PeriodSheet scope={scope} today={TODAY} onApply={onApply} onClose={() => {}} />);
}

describe("PeriodSheet", () => {
  it("offers quick presets", () => {
    open(() => {});
    expect(screen.getByRole("button", { name: /this month/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /last 3 months/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /year to date/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /all time/i })).toBeInTheDocument();
  });

  it("applies This month as a single-month scope", () => {
    const onApply = vi.fn();
    render(
      <PeriodSheet
        scope={{ kind: "month", period: "2026-06" }}
        onApply={onApply}
        onClose={() => {}}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /this month/i }));
    expect(onApply).toHaveBeenCalledWith({ kind: "month", period: currentPeriod() });
  });

  it("applies All time", () => {
    const onApply = vi.fn();
    open(onApply);
    fireEvent.click(screen.getByRole("button", { name: /all time/i }));
    expect(onApply).toHaveBeenCalledWith({ kind: "all" });
  });

  it("picks a single month from the grid", () => {
    const onApply = vi.fn();
    open(onApply); // seeded to year 2026
    fireEvent.click(screen.getByRole("button", { name: "Mar" }));
    fireEvent.click(screen.getByRole("button", { name: /^show$/i }));
    expect(onApply).toHaveBeenCalledWith({ kind: "month", period: "2026-03" });
  });

  it("forms a range from two grid taps", () => {
    const onApply = vi.fn();
    open(onApply);
    fireEvent.click(screen.getByRole("button", { name: "Mar" }));
    fireEvent.click(screen.getByRole("button", { name: "Jun" }));
    fireEvent.click(screen.getByRole("button", { name: /^show$/i }));
    expect(onApply).toHaveBeenCalledWith({ kind: "range", from: "2026-03", to: "2026-06" });
  });

  // -------------------------------------------------------------------------
  // The future bound
  // -------------------------------------------------------------------------

  it("disables every month after the current one, and says why", () => {
    open(() => {}); // year 2026, today 2026-08
    expect(screen.getByRole("button", { name: "Aug" })).toBeEnabled();
    for (const m of ["Sep", "Oct", "Nov", "Dec"]) {
      const btn = screen.getByRole("button", { name: m });
      expect(btn, m).toBeDisabled();
      expect(btn.getAttribute("title"), m).toMatch(/hasn't happened yet/i);
    }
  });

  it("does not step the year past the one the current month is in", () => {
    open(() => {});
    const next = screen.getByRole("button", { name: /next year/i });
    fireEvent.click(next); // 2026 is already the current year
    expect(screen.getByText("2026")).toBeInTheDocument();
    expect(next).toBeDisabled();
  });

  it("steps back and forward within the past", () => {
    open(() => {});
    fireEvent.click(screen.getByRole("button", { name: /previous year/i }));
    expect(screen.getByText("2025")).toBeInTheDocument();
    // Every month of a past year is reachable.
    expect(screen.getByRole("button", { name: "Dec" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: /next year/i }));
    expect(screen.getByText("2026")).toBeInTheDocument();
  });

  it("clamps a scope that arrives already pointing at the future", () => {
    const onApply = vi.fn();
    open(onApply, { kind: "range", from: "2026-05", to: "2026-12" });
    fireEvent.click(screen.getByRole("button", { name: /^show$/i }));
    expect(onApply).toHaveBeenCalledWith({ kind: "range", from: "2026-05", to: TODAY });
  });
});
