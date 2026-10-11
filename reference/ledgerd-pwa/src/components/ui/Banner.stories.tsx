import type { Meta, StoryObj } from "@storybook/react-vite";

import { Banner } from "./Banner";
import { PLAN_BANNER_COPY } from "../../v2/onboarding";

const meta = {
  title: "UI/Banner",
  component: Banner,
  parameters: {
    docs: {
      description: {
        component:
          "The app shell's persistent notice strip, between the TopBar and the scrolling content: an optional " +
          "eyebrow, a sentence, one primary action and a required dismiss. Chrome, not content — quiet surface, " +
          "hairline separation, and the action is the only bright thing on it.",
      },
    },
  },
  args: {
    title: PLAN_BANNER_COPY.title,
    body: PLAN_BANNER_COPY.body,
    action: PLAN_BANNER_COPY.action,
    onAction: () => {},
    onDismiss: () => {},
  },
} satisfies Meta<typeof Banner>;
export default meta;
type Story = StoryObj<typeof meta>;

/** The real one: the plan nudge the app shell carries after the walk. */
export const Plan: Story = {};

/** With an eyebrow, for a banner that needs a category before its sentence. */
export const WithEyebrow: Story = { args: { eyebrow: "Your plan" } };

/** Title and action only — the shortest legal banner. */
export const TitleOnly: Story = {
  args: { body: undefined, title: "Two transactions need a category", action: "Open review" },
};

/**
 * The longest string the copy could plausibly grow to, on the narrowest phone.
 * A banner that wraps badly pushes the whole app down, so this is the case
 * worth having a story for.
 */
export const LongCopy: Story = {
  args: {
    eyebrow: "Your plan",
    title: "Set what you mean to spend each month and how you split it",
    body:
      "Give ledger a monthly total and how you divide it — needs, wants, and what you save or pay down. ledger " +
      "shows your spending against it; it never moves money and never blocks a purchase.",
    action: "Open your plan in Settings",
  },
};
