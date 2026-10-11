import { useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { TopBar } from "./TopBar";
import { type Scope } from "../../lib/scope";

/** Pinned in every story: a stepper bound to the clock renders differently every month. */
const TODAY = "2026-08";

function TopBarDemo({ title, showScope, start = { kind: "month", period: TODAY } as Scope }: {
  title: string;
  showScope: boolean;
  start?: Scope;
}) {
  const [scope, setScope] = useState<Scope>(start);
  return <TopBar title={title} scope={scope} onScopeChange={setScope} showScope={showScope} today={TODAY} />;
}

const meta = {
  title: "Chrome/TopBar",
  component: TopBar,
  parameters: {
    docs: {
      description: {
        component:
          "Owns the page title (sans) and the period-scope stepper (mono micro-caps — it's data, " +
          "not prose). The scope is app-wide: every tab reads it, and only the Settings overlay — " +
          "which does not render this bar — is outside it. The stepper cannot leave the present: " +
          "on the current month the next chevron is disabled rather than removed, and a Today " +
          "button appears only when the scope is somewhere else. Screens never render their own " +
          "h1 outside this.",
      },
    },
  },
} satisfies Meta<typeof TopBar>;
export default meta;

/** The current month: no Today button (it would do nothing), next chevron disabled. */
export const WithScope: StoryObj = { render: () => <TopBarDemo title="Insights" showScope /> };
/** A month in the past: Today is offered, and the stepper can still walk forward. */
export const PastMonth: StoryObj = {
  render: () => <TopBarDemo title="Transactions" showScope start={{ kind: "month", period: "2026-02" }} />,
};
/** A range has no stepper, and is never "the current month" — so Today is offered. */
export const Range: StoryObj = {
  render: () => <TopBarDemo title="Home" showScope start={{ kind: "range", from: "2026-01", to: "2026-04" }} />,
};
export const TitleOnly: StoryObj = { render: () => <TopBarDemo title="Settings" showScope={false} /> };
