import "@/test/storybook";
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { composeStories } from "@storybook/react-vite";

import * as stories from "./MailboxSetup.stories";

const { Guidance } = composeStories(stories);

describe("MailboxSetup stories", () => {
  it("opens on the burner guidance, in house voice", () => {
    render(<Guidance />);
    expect(screen.getByTestId("mailbox-guidance")).toBeInTheDocument();
    // The load-bearing sentence: the grant covers the whole mailbox.
    expect(screen.getByTestId("mailbox-why").textContent?.toLowerCase()).toMatch(/covers everything in that mailbox/);
    // D6 no-heuristic honesty is on the screen, not just in a constants file.
    expect(screen.getByTestId("mailbox-unsupported").textContent?.toLowerCase()).toMatch(/review item you fill in yourself/);
  });
});
