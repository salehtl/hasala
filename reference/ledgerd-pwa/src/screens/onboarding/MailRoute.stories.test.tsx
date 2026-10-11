import "@/test/storybook";
import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { composeStories } from "@storybook/react-vite";

import * as stories from "./MailRoute.stories";

const { Default } = composeStories(stories);

describe("MailRoute stories", () => {
  it("offers both routes and an always-present skip", () => {
    render(<Default />);
    expect(screen.getByTestId("mail-route-mailbox")).toBeInTheDocument();
    expect(screen.getByTestId("mail-route-forward")).toBeInTheDocument();
    expect(screen.getByTestId("mail-route-skip")).toBeInTheDocument();
  });

  it("names the provider on the mailbox card — an instruction surface may", () => {
    render(<Default />);
    expect(screen.getByTestId("mail-route-mailbox").textContent?.toLowerCase()).toContain("gmail");
  });

  it("reports the chosen route", async () => {
    const onChoose = vi.fn();
    render(<Default onChoose={onChoose} />);
    await userEvent.click(screen.getByTestId("mail-route-mailbox"));
    expect(onChoose).toHaveBeenCalledWith("mailbox");
    await userEvent.click(screen.getByTestId("mail-route-forward"));
    expect(onChoose).toHaveBeenCalledWith("forward");
  });
});
