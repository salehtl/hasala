import "@/test/storybook";
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { composeStories } from "@storybook/react-vite";

import * as stories from "./MailboxSettingsPanel.stories";

const { Active, ActiveWithForwarding, WithSetAside, ReconnectRequired, AnotherDevice, NeverConnected } =
  composeStories(stories);

describe("MailboxSettingsPanel stories", () => {
  it("active shows the connected address and controls", async () => {
    render(<Active />);
    expect(await screen.findByTestId("mailbox-settings-connected-label")).toBeInTheDocument();
    expect(screen.getByTestId("mailbox-settings-catchup")).toBeInTheDocument();
    expect(screen.getByTestId("mailbox-settings-disconnect")).toBeInTheDocument();
  });

  it("active-with-forwarding surfaces the D7 notice", async () => {
    render(<ActiveWithForwarding />);
    expect(await screen.findByTestId("mailbox-settings-route-overlap")).toBeInTheDocument();
  });

  it("with-set-aside lists the senders it did not import, and offers to import them", async () => {
    render(<WithSetAside />);
    expect(await screen.findByTestId("mailbox-set-aside")).toBeInTheDocument();
    expect(screen.getByTestId("mailbox-set-aside-group-news.example.test").textContent).toMatch(/2 messages/);
    expect(screen.getByTestId("mailbox-set-aside-trust-alerts.mybank.test")).toBeInTheDocument();
  });

  it("reconnect and another-device are different renders", async () => {
    const { unmount } = render(<ReconnectRequired />);
    expect(await screen.findByTestId("mailbox-settings-reconnect")).toBeInTheDocument();
    unmount();
    render(<AnotherDevice />);
    expect(await screen.findByTestId("mailbox-settings-another-device")).toBeInTheDocument();
  });

  it("never-connected offers a connect affordance", async () => {
    render(<NeverConnected />);
    expect(await screen.findByTestId("mailbox-settings-connect")).toBeInTheDocument();
  });
});
