import "@/test/storybook";
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { composeStories } from "@storybook/react-vite";
import * as stories from "./MailboxReviewSheet.stories";

const { ReadyPrefilled, ReadyForwarder, AlreadyTrusted, NonHolder, Reconnect, Unavailable, Loading } =
  composeStories(stories);

describe("MailboxReviewSheet stories", () => {
  it("ready+prefilled shows the form and the trust action", () => {
    render(<ReadyPrefilled />);
    expect(screen.getByTestId("mailbox-review-add")).toBeInTheDocument();
    expect(screen.getByTestId("mailbox-review-trust")).toHaveTextContent("Trust dib.ae for automatic import");
  });

  it("a forwarder is never offered for trust, and the card says why", () => {
    render(<ReadyForwarder />);
    expect(screen.queryByTestId("mailbox-review-trust")).toBeNull();
    expect(screen.getByTestId("mailbox-review-forwarder")).toHaveTextContent("gmail.com");
    // The form is still there: this refuses the trust, never the entry.
    expect(screen.getByTestId("mailbox-review-add")).toBeInTheDocument();
  });

  it("already-trusted names the domain and hides the trust button", () => {
    render(<AlreadyTrusted />);
    expect(screen.getByTestId("mailbox-review-trusted")).toHaveTextContent("dib.ae");
    expect(screen.queryByTestId("mailbox-review-trust")).toBeNull();
  });

  it("non-holder points at the connected device", () => {
    render(<NonHolder />);
    expect(screen.getByTestId("mailbox-review-nonholder")).toHaveTextContent(
      "Open this on the device connected to your mailbox.",
    );
  });

  it("reconnect offers the reconnect action", () => {
    render(<Reconnect />);
    expect(screen.getByTestId("mailbox-review-reconnect-action")).toBeInTheDocument();
  });

  it("unavailable offers a retry", () => {
    render(<Unavailable />);
    expect(screen.getByTestId("mailbox-review-retry")).toBeInTheDocument();
  });

  it("loading says it is reading", () => {
    render(<Loading />);
    expect(screen.getByRole("status")).toHaveTextContent("Reading this message…");
  });
});
