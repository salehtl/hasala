/**
 * The mailbox needs-review surface, in its four device states.
 *
 * The three states spec §2.2 names are honesty-critical: a non-holder is told
 * where to read the message and offered no form (nothing is fetched), a dead
 * token routes to reconnect rather than an error, and only the holder+live state
 * shows the re-fetched message and the prefill form. The fourth (unavailable) is
 * a retryable transient. The trust action is offered only when the loader found a
 * domain worth trusting, and the copy is clean of any "verified" claim (D6a).
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

import type { OpSpec } from "@ledger/client/outbox/outbox";
import { setPlatform } from "@ledger/client/platform.registry";
import { webPlatform } from "@ledger/client/platform.web";

import { MotionProvider } from "../../app/MotionProvider";
import type { Prefill } from "../../v2/sources/heldMessage";
import type { Writer } from "../../v2/writer";
import { MailboxReviewSheet, type MailboxReviewSheetProps } from "./MailboxReviewSheet";

const FILLED: Prefill = {
  body: "You spent AED 125.00 at CARREFOUR MALL.",
  subject: "Transaction alert",
  claimedFrom: "alerts@dib.ae",
  draft: { amount: "125.00", currency: "AED", direction: "debit", merchant: "CARREFOUR MALL", date: "2026-08-03", category: null },
  templateId: "dib.card.v1",
  reason: "Filled in from the message below. Check every field before you add it.",
};

interface Recorder extends Writer {
  queued: OpSpec[];
}
function recorder(): Recorder {
  const queued: OpSpec[] = [];
  return { queued, pending: [], enqueueMany: (specs) => void queued.push(...specs), flush: async () => undefined };
}

function mount(over: Partial<MailboxReviewSheetProps> = {}, writer: Writer = recorder()) {
  const props: MailboxReviewSheetProps = {
    content: { state: "ready", prefill: FILLED, trustDomain: null },
    homeCurrency: "AED",
    categories: ["groceries", "eating out"],
    currencies: ["AED"],
    writer,
    onClose: vi.fn(),
    onAdded: vi.fn(),
    onReconnect: vi.fn(),
    onRetry: vi.fn(),
    onTrust: vi.fn(),
    ...over,
  };
  return { props, ...render(<MotionProvider><MailboxReviewSheet {...props} /></MotionProvider>) };
}

beforeEach(() => {
  setPlatform(webPlatform);
  vi.stubGlobal(
    "fetch",
    vi.fn(() => {
      throw new Error("the review sheet must never reach the network");
    }),
  );
});

describe("the three device states", () => {
  it("non-holder: points at the connected device and offers no form", () => {
    mount({ content: { state: "non_holder" } });
    expect(screen.getByTestId("mailbox-review-nonholder")).toHaveTextContent(
      "Open this on the device connected to your mailbox.",
    );
    // No re-fetch story here: there is no form and no add action.
    expect(screen.queryByTestId("mailbox-review-add")).toBeNull();
  });

  it("dead token: routes to reconnect, and is not an error banner", () => {
    const onReconnect = vi.fn();
    mount({ content: { state: "reconnect_required" }, onReconnect });
    expect(screen.getByTestId("mailbox-review-reconnect")).toHaveTextContent("Reconnect to read this message.");
    // Honesty: this is guidance, not an alert.
    expect(screen.queryByRole("alert")).toBeNull();
    screen.getByTestId("mailbox-review-reconnect-action").click();
    expect(onReconnect).toHaveBeenCalledTimes(1);
  });

  it("holder + live token: shows the re-fetched message and the prefilled form", () => {
    mount();
    expect(screen.getByTestId("mailbox-review-body")).toHaveTextContent("CARREFOUR MALL");
    expect(screen.getByTestId("mailbox-review-add")).toBeInTheDocument();
    expect(screen.getByDisplayValue("125.00")).toBeInTheDocument();
  });
});

describe("unavailable is a retry, distinct from reconnect", () => {
  it("shows the reason and retries", () => {
    const onRetry = vi.fn();
    mount({ content: { state: "unavailable", reason: "Couldn't fetch this message right now. Try again in a moment." }, onRetry });
    expect(screen.getByTestId("mailbox-review-unavailable")).toHaveTextContent("Try again in a moment");
    screen.getByTestId("mailbox-review-retry").click();
    expect(onRetry).toHaveBeenCalledTimes(1);
  });
});

describe("the trust action", () => {
  it("is offered only when the loader found a domain, and posts that domain", () => {
    const onTrust = vi.fn();
    mount({ content: { state: "ready", prefill: FILLED, trustDomain: "dib.ae" }, onTrust });
    const btn = screen.getByTestId("mailbox-review-trust");
    expect(btn).toHaveTextContent("Trust dib.ae for automatic import");
    btn.click();
    expect(onTrust).toHaveBeenCalledWith("dib.ae");
  });

  it("is absent when there is no domain to trust", () => {
    mount({ content: { state: "ready", prefill: FILLED, trustDomain: null } });
    expect(screen.queryByTestId("mailbox-review-trust")).toBeNull();
  });

  it("names no provider and never claims the message is verified (D6a)", () => {
    mount({ content: { state: "ready", prefill: FILLED, trustDomain: "dib.ae" } });
    const text = document.body.textContent ?? "";
    expect(text.toLowerCase()).not.toMatch(/verified/);
    expect(text.toLowerCase()).not.toMatch(/gmail|google/);
    expect(text.toLowerCase()).not.toMatch(/only you can (access|see|read)/);
  });
});

describe("adding the transaction", () => {
  it("authors one txn op with the mailbox entry method and calls onAdded", async () => {
    const user = userEvent.setup();
    const writer = recorder();
    const onAdded = vi.fn();
    mount({ onAdded }, writer);
    await user.click(screen.getByTestId("mailbox-review-add"));
    expect((writer as Recorder).queued).toHaveLength(1);
    const spec = (writer as Recorder).queued[0]!;
    expect(spec.type).toBe("txn_ingested");
    expect((spec.payload as { entry_method?: string }).entry_method).toBe("mailbox");
    // No supersede is authored — resolution is the caller's disposition.
    expect((writer as Recorder).queued.some((s) => s.type === "txn_superseded")).toBe(false);
    expect(onAdded).toHaveBeenCalledTimes(1);
  });
});
