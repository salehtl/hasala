import type { Meta, StoryObj } from "@storybook/react-vite";

import type { Prefill } from "../../v2/sources/heldMessage";
import type { Writer } from "../../v2/writer";
import { MailboxReviewSheet } from "./MailboxReviewSheet";

const noopWriter: Writer = { pending: [], enqueueMany: () => undefined, flush: async () => undefined };

const FILLED: Prefill = {
  body: "You spent AED 125.00 at CARREFOUR MALL on 03 Aug. Available balance AED 4,210.55.",
  subject: "Card transaction alert",
  claimedFrom: "alerts@dib.ae",
  draft: { amount: "125.00", currency: "AED", direction: "debit", merchant: "CARREFOUR MALL", date: "2026-08-03", category: null },
  templateId: "dib.card.v1",
  reason: "Filled in from the message below. Check every field before you add it.",
};

const UNREAD: Prefill = {
  body: "Dear customer, a transaction occurred on your account. Please review your statement for details.",
  subject: "Account notification",
  claimedFrom: "noreply@unknown.test",
  draft: null,
  templateId: null,
  reason: "ledger has no reader for this sender, so nothing was filled in. The message is below — copy the details across.",
};

const meta = {
  title: "Mailbox/MailboxReviewSheet",
  component: MailboxReviewSheet,
  parameters: {
    docs: {
      description: {
        component:
          "The needs-review surface for a mailbox message. A mailbox needs-review op is empty, so the card " +
          "re-fetches the message by its provenance id — which only the holder device with a live token can do. " +
          "Hence four states: ready (form + optional trust), non-holder, reconnect, and a transient retry.",
      },
    },
  },
  args: {
    homeCurrency: "AED",
    categories: ["groceries", "eating out", "transport"],
    currencies: ["AED", "USD"],
    writer: noopWriter,
    onClose: () => {},
    onAdded: () => {},
    onReconnect: () => {},
    onRetry: () => {},
    onTrust: () => {},
  },
} satisfies Meta<typeof MailboxReviewSheet>;
export default meta;
type Story = StoryObj<typeof meta>;

/** Holder + live token: a template filled the form, and the sender can be trusted. */
export const ReadyPrefilled: Story = {
  args: { content: { state: "ready", prefill: FILLED, trustDomain: "dib.ae" } },
};

/** Holder + live token, but no template read it out — plain manual entry, no trust offer. */
export const ReadyUnread: Story = {
  args: { content: { state: "ready", prefill: UNREAD, trustDomain: null } },
};

/** The sender has already been trusted for automatic import. */
export const AlreadyTrusted: Story = {
  args: { content: { state: "ready", prefill: FILLED, trustDomain: "dib.ae" }, trusted: true },
};

/**
 * A hand-forwarded message: what Gmail verified is the forwarder, not the bank.
 * No trust action is offered, and the card says why rather than going quiet.
 */
export const ReadyForwarder: Story = {
  args: { content: { state: "ready", prefill: FILLED, trustDomain: "gmail.com" } },
};

/** This device holds no mailbox connection — it says where the message can be read. */
export const NonHolder: Story = {
  args: { content: { state: "non_holder" } },
};

/** The connection is dead — routes to reconnect, never an error banner. */
export const Reconnect: Story = {
  args: { content: { state: "reconnect_required" } },
};

/** A transient fetch failure, offered a retry. */
export const Unavailable: Story = {
  args: { content: { state: "unavailable", reason: "Couldn't fetch this message right now. Try again in a moment." } },
};

/** Still fetching. */
export const Loading: Story = {
  args: { content: null },
};
