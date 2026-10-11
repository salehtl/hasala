import "@/test/storybook";
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { composeStories } from "@storybook/react-vite";
import * as stories from "./PeriodSheet.stories";

const { Month, Range, AllTime } = composeStories(stories);

describe("PeriodSheet stories", () => {
  it("renders the picker with its presets", () => {
    render(<Month />);
    expect(screen.getByText(/choose period/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /this month/i })).toBeInTheDocument();
  });
  it("puts every month after the current one out of reach", () => {
    render(<Month />);
    expect(screen.getByRole("button", { name: "Aug" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Sep" })).toBeDisabled();
    expect(screen.getByRole("button", { name: /next year/i })).toBeDisabled();
  });
  it("marks a closed range end to end", () => {
    render(<Range />);
    for (const m of ["Mar", "Apr", "May", "Jun"]) {
      expect(screen.getByRole("button", { name: m }), m).toHaveAttribute("aria-pressed", "true");
    }
    expect(screen.getByRole("button", { name: "Feb" })).toHaveAttribute("aria-pressed", "false");
  });
  it("selects nothing for all time and asks for a month", () => {
    render(<AllTime />);
    expect(screen.getByText("Pick a month")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^show$/i })).toBeDisabled();
  });
});
