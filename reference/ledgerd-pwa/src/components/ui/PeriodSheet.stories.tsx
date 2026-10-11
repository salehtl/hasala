import type { Meta, StoryObj } from "@storybook/react-vite";
import { PeriodSheet } from "./PeriodSheet";

/** Pinned: a picker bound to the clock renders a different grid every month. */
const TODAY = "2026-08";

const meta = {
  title: "Chrome/PeriodSheet",
  component: PeriodSheet,
  parameters: {
    docs: {
      description: {
        component:
          "The app's one period picker, built on Dialog and opened from the TopBar label. Four " +
          "presets, a year stepper and a twelve-month grid; a first tap picks a month and a " +
          "second closes a range. It cannot select the future: months after the current one keep " +
          "their place in the grid and lose their fill, the year step stops at this year, and " +
          "everything applied is run through clampScope on the way out.",
      },
    },
  },
} satisfies Meta<typeof PeriodSheet>;
export default meta;
type Story = StoryObj<typeof meta>;

/** The current month, mid-year: September through December are out of reach. */
export const Month: Story = {
  args: { scope: { kind: "month", period: TODAY }, today: TODAY, onApply: () => {}, onClose: () => {} },
};
/** A closed range: both endpoints and everything between them read as selected. */
export const Range: Story = {
  args: {
    scope: { kind: "range", from: "2026-03", to: "2026-06" },
    today: TODAY,
    onApply: () => {},
    onClose: () => {},
  },
};
/** All time: nothing is selected, and the hint asks for a month. */
export const AllTime: Story = {
  args: { scope: { kind: "all" }, today: TODAY, onApply: () => {}, onClose: () => {} },
};
