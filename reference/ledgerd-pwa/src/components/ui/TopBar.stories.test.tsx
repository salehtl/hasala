import "@/test/storybook";
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { composeStories } from "@storybook/react-vite";
import * as stories from "./TopBar.stories";

const { WithScope, PastMonth, Range, TitleOnly } = composeStories(stories);

describe("TopBar stories", () => {
  it("renders the sans screen title", () => {
    render(<WithScope />);
    expect(screen.getByRole("heading", { name: "Insights" })).toBeInTheDocument();
  });
  it("the current-month story cannot step forward and offers no Today", () => {
    render(<WithScope />);
    expect(screen.getByRole("button", { name: /next month/i })).toBeDisabled();
    expect(screen.queryByRole("button", { name: /^today$/i })).not.toBeInTheDocument();
  });
  it("the past-month story offers Today and can still step forward", () => {
    render(<PastMonth />);
    expect(screen.getByRole("button", { name: /^today$/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /next month/i })).toBeEnabled();
  });
  it("the range story shows no stepper but does offer Today", () => {
    render(<Range />);
    expect(screen.queryByRole("button", { name: /next month/i })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^today$/i })).toBeInTheDocument();
  });
  it("showScope=false hides the period stepper", () => {
    render(<TitleOnly />);
    expect(screen.getByRole("heading", { name: "Settings" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^today$/i })).not.toBeInTheDocument();
  });
});
