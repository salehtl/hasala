import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MotionProvider } from "../../app/MotionProvider";
import { TopBar } from "./TopBar";
import { currentPeriod } from "../../lib/insights";

const wrap = (ui: React.ReactNode) => render(<MotionProvider>{ui}</MotionProvider>);

/** Pinned, so the future bound is tested at its boundary and not at the clock's. */
const TODAY = "2026-08";

describe("TopBar", () => {
  it("renders the page title", () => {
    wrap(<TopBar title="Transactions" scope={{ kind: "month", period: "2026-06" }} onScopeChange={() => {}} showScope />);
    expect(screen.getByRole("heading", { name: "Transactions" })).toBeInTheDocument();
  });

  it("shows the period label and steps months with the chevrons", () => {
    const onScopeChange = vi.fn();
    wrap(
      <TopBar
        title="Home"
        scope={{ kind: "month", period: "2026-06" }}
        onScopeChange={onScopeChange}
        showScope
        today={TODAY}
      />,
    );
    expect(screen.getByRole("button", { name: /jun 2026/i })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /previous month/i }));
    expect(onScopeChange).toHaveBeenCalledWith({ kind: "month", period: "2026-05" });
    fireEvent.click(screen.getByRole("button", { name: /next month/i }));
    expect(onScopeChange).toHaveBeenCalledWith({ kind: "month", period: "2026-07" });
  });

  it("hides the period control when showScope is false", () => {
    wrap(<TopBar title="Settings" scope={{ kind: "all" }} onScopeChange={() => {}} showScope={false} />);
    expect(screen.queryByRole("button", { name: /all time/i })).not.toBeInTheDocument();
  });

  it("opens the period sheet when the label is tapped", () => {
    wrap(<TopBar title="Home" scope={{ kind: "month", period: "2026-06" }} onScopeChange={() => {}} showScope />);
    fireEvent.click(screen.getByRole("button", { name: /jun 2026/i }));
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(screen.getByText(/choose period/i)).toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // The future bound
  // -------------------------------------------------------------------------

  it("disables — never hides — the next-month control on the current month, and says why", () => {
    const onScopeChange = vi.fn();
    wrap(
      <TopBar
        title="Home"
        scope={{ kind: "month", period: TODAY }}
        onScopeChange={onScopeChange}
        showScope
        today={TODAY}
      />,
    );
    const next = screen.getByRole("button", { name: /next month/i });
    // Present, so a control the user reached for has not vanished under them.
    expect(next).toBeInTheDocument();
    expect(next).toBeDisabled();
    expect(next).toHaveAttribute("aria-disabled", "true");
    expect(next.getAttribute("title")).toMatch(/hasn't happened yet/i);
    fireEvent.click(next);
    expect(onScopeChange).not.toHaveBeenCalled();
  });

  it("keeps the next-month control live on a past month", () => {
    wrap(
      <TopBar
        title="Home"
        scope={{ kind: "month", period: "2026-07" }}
        onScopeChange={() => {}}
        showScope
        today={TODAY}
      />,
    );
    expect(screen.getByRole("button", { name: /next month/i })).toBeEnabled();
  });

  // -------------------------------------------------------------------------
  // Today
  // -------------------------------------------------------------------------

  it("offers no Today button when the scope is already the current month", () => {
    wrap(
      <TopBar title="Home" scope={{ kind: "month", period: TODAY }} onScopeChange={() => {}} showScope today={TODAY} />,
    );
    expect(screen.queryByRole("button", { name: /^today$/i })).not.toBeInTheDocument();
  });

  it("offers Today on an earlier month and jumps back to the current one", () => {
    const onScopeChange = vi.fn();
    wrap(
      <TopBar
        title="Home"
        scope={{ kind: "month", period: "2026-02" }}
        onScopeChange={onScopeChange}
        showScope
        today={TODAY}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /^today$/i }));
    expect(onScopeChange).toHaveBeenCalledWith({ kind: "month", period: TODAY });
  });

  it("offers Today on a range and on all-time, which are never the current month", () => {
    wrap(
      <TopBar
        title="Home"
        scope={{ kind: "range", from: "2026-01", to: "2026-04" }}
        onScopeChange={() => {}}
        showScope
        today={TODAY}
      />,
    );
    expect(screen.getByRole("button", { name: /^today$/i })).toBeInTheDocument();
  });

  it("offers no Today button when the scope control is hidden entirely", () => {
    wrap(
      <TopBar
        title="Settings"
        scope={{ kind: "range", from: "2026-01", to: "2026-04" }}
        onScopeChange={() => {}}
        showScope={false}
        today={TODAY}
      />,
    );
    expect(screen.queryByRole("button", { name: /^today$/i })).not.toBeInTheDocument();
  });

  it("defaults `today` to the real current month", () => {
    wrap(
      <TopBar title="Home" scope={{ kind: "month", period: currentPeriod() }} onScopeChange={() => {}} showScope />,
    );
    expect(screen.getByRole("button", { name: /next month/i })).toBeDisabled();
    expect(screen.queryByRole("button", { name: /^today$/i })).not.toBeInTheDocument();
  });
});
