import "@/test/storybook";
import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { composeStories } from "@storybook/react-vite";

import * as stories from "./Banner.stories";

const { Plan, WithEyebrow, TitleOnly } = composeStories(stories);

describe("Banner stories", () => {
  it("shows the sentence and the action", () => {
    render(<Plan />);
    expect(screen.getByText(/Set what you mean to spend/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Open your plan/i })).toBeInTheDocument();
  });

  it("reports the action", async () => {
    const onAction = vi.fn();
    render(<Plan onAction={onAction} />);
    await userEvent.click(screen.getByRole("button", { name: /Open your plan/i }));
    expect(onAction).toHaveBeenCalledOnce();
  });

  /**
   * The dismiss is the only way off a persistent strip, and it is not
   * recoverable — so it is a named 44px control, never a bare glyph. This is the
   * same rule the toast's controls are held to.
   */
  it("always carries a dismiss with an accessible name", async () => {
    const onDismiss = vi.fn();
    render(<Plan onDismiss={onDismiss} />);
    const dismiss = screen.getByRole("button", { name: "Dismiss" });
    await userEvent.click(dismiss);
    expect(onDismiss).toHaveBeenCalledOnce();
  });

  it("renders the eyebrow only when one is given", () => {
    const { unmount } = render(<WithEyebrow />);
    expect(screen.getByText("Your plan")).toBeInTheDocument();
    unmount();
    render(<TitleOnly />);
    expect(screen.queryByText("Your plan")).toBeNull();
  });

  it("renders without a body", () => {
    render(<TitleOnly />);
    expect(screen.getByText("Two transactions need a category")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open review" })).toBeInTheDocument();
  });
});
