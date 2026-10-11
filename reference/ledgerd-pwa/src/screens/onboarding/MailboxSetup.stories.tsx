import type { Meta, StoryObj } from "@storybook/react-vite";

import type { StoredKeys, KeyVault } from "../../v2/keys";
import type { V2Handle } from "../../v2/session";
import { MailboxSetup } from "./MailboxSetup";

/** A handle stub — the injected `connect` means the real one is never read. */
const handle = {} as unknown as V2Handle;

/** A vault whose DEK is never actually used (the injected `connect` ignores it). */
const vault: KeyVault = {
  read: async (): Promise<StoredKeys> => ({
    accountId: "u_demo",
    ingestPub: new Uint8Array(32),
    ingestPrivSealed: new Uint8Array(64),
    ingestPrivIv: new Uint8Array(12),
    dek: {} as CryptoKey,
  }),
  write: async () => undefined,
  clear: async () => undefined,
};

const meta = {
  title: "Onboarding/MailboxSetup",
  component: MailboxSetup,
  parameters: {
    docs: {
      description: {
        component:
          "The Gmail transaction-mailbox route: burner guidance → consent → backfill window → catching-up. The " +
          "machine advances only from the final Continue, so the backfill and catching-up screens are not " +
          "unmounted the instant the grant appears. The deeper phases are driven in the colocated component test.",
      },
    },
  },
  args: {
    handle,
    vault,
    onConnected: () => {},
    onForward: () => {},
    onSkip: () => {},
    saveBackfill: async () => undefined,
    connect: async () => ({ email: "ledger.beta.7f3a@example.com" }),
  },
} satisfies Meta<typeof MailboxSetup>;
export default meta;
type Story = StoryObj<typeof meta>;

/** The burner guidance — the first screen of the route. */
export const Guidance: Story = {};

/** Rendered inside a Settings dialog rather than as a whole page. */
export const Embedded: Story = { args: { embedded: true } };
