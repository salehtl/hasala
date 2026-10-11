import type { Meta, StoryObj } from "@storybook/react-vite";

import type { MailboxState } from "../../v2/mailbox/state";
import { MailboxSettingsPanel } from "./MailboxSettingsPanel";

const connectedState: MailboxState = {
  historyId: "h1",
  backfillDays: 30,
  lastCycleAt: "2026-08-12T10:00:00.000Z",
  unreadable: { count: 0, recent: [] },
  connectedEmail: "ledger.beta.7f3a@example.com",
};

const meta = {
  title: "Settings/MailboxSettingsPanel",
  component: MailboxSettingsPanel,
  parameters: {
    docs: {
      description: {
        component:
          "The 'Transaction mailbox' drill-in body. Four states, each a distinct honest render: active (holder), " +
          "connected-on-another-device, reconnect-required (D10), and never-connected. All loaders and actions are " +
          "injected — no crypto, no network.",
      },
    },
  },
  args: {
    forwardingConfigured: false,
    loadState: async () => connectedState,
    catchUpNow: async () => ({ fetched: 3, ops: 2, review: 1, unreadable: 0, setAside: 0 }),
    importSetAside: async () => ({ fetched: 2, ops: 2, review: 2, unreadable: 0, setAside: 0 }),
    saveBackfill: async () => undefined,
    onConnect: () => {},
    disconnect: async () => undefined,
    now: () => Date.parse("2026-08-12T10:05:00.000Z"),
  },
} satisfies Meta<typeof MailboxSettingsPanel>;
export default meta;
type Story = StoryObj<typeof meta>;

/** A live grant, this device is the holder: catch-up, backfill, disconnect. */
export const Active: Story = {
  args: { loadGrantStatus: async () => "active", hasSealedToken: async () => true },
};

/** A live grant AND forwarding also set up — the D7 "pick one route per bank" notice. */
export const ActiveWithForwarding: Story = {
  args: { loadGrantStatus: async () => "active", hasSealedToken: async () => true, forwardingConfigured: true },
};

/** Messages the lane could not read, held visible across sessions (the health surface). */
export const WithUnreadable: Story = {
  args: {
    loadGrantStatus: async () => "active",
    hasSealedToken: async () => true,
    loadState: async () => ({ ...connectedState, unreadable: { count: 4, recent: [] } }),
  },
};

/**
 * Mail the lane did NOT import, because it came from no bank it recognises.
 * Grouped by sender, with the "This is my bank" action that imports it — the
 * surface that keeps filtering from being a silent drop.
 */
export const WithSetAside: Story = {
  args: {
    loadGrantStatus: async () => "active",
    hasSealedToken: async () => true,
    loadState: async () => ({
      ...connectedState,
      setAside: {
        count: 3,
        dropped: 0,
        recent: [
          { message_id: "a", domain: "news.example.test", subject: "Your weekly digest", receivedAt: "2026-08-01T00:00:00.000Z" },
          { message_id: "b", domain: "news.example.test", subject: "Another digest", receivedAt: "2026-08-02T00:00:00.000Z" },
          { message_id: "c", domain: "alerts.mybank.test", subject: "Card transaction on your account ending 1234", receivedAt: "2026-08-03T00:00:00.000Z" },
        ],
      },
    }),
  },
};

/** Google stopped honouring the grant (the beta's weekly expiry, D10). */
export const ReconnectRequired: Story = {
  args: { loadGrantStatus: async () => "reconnect_required", hasSealedToken: async () => false },
};

/** A grant exists but this device holds no token — read on the device that connected it. */
export const AnotherDevice: Story = {
  args: { loadGrantStatus: async () => "active", hasSealedToken: async () => false },
};

/** No grant at all — a connect affordance. */
export const NeverConnected: Story = {
  args: { loadGrantStatus: async () => null, hasSealedToken: async () => false },
};
