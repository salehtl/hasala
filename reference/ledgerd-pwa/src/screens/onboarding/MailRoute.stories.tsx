import type { Meta, StoryObj } from "@storybook/react-vite";

import { MailRoute } from "./MailRoute";

const meta = {
  title: "Onboarding/MailRoute",
  component: MailRoute,
  parameters: {
    docs: {
      description: {
        component:
          "The mail-stage opening screen (spec D11). Gmail is the recommended path and carries the screen's one " +
          "primary action; forwarding is a low-emphasis control below it. Shown only when a mailbox broker is " +
          "configured — an unconfigured build renders the forwarding address phase instead, with no mention of " +
          "Gmail. Both routes stay skippable.",
      },
    },
  },
  args: {
    onChoose: () => {},
    onSkip: () => {},
  },
} satisfies Meta<typeof MailRoute>;
export default meta;
type Story = StoryObj<typeof meta>;

/** The recommendation, the way past it, and the always-present skip. */
export const Default: Story = {};

/** Rendered inside a Settings dialog rather than as a whole page. */
export const Embedded: Story = { args: { embedded: true } };
