/**
 * The mail stage's opening screen (spec §3, D11): **connect a Gmail transaction
 * mailbox, or set up forwarding instead.**
 *
 * # It is one primary action and a way past it, not two cards
 *
 * This screen used to be a pair of matching rows in one bordered list, which
 * said the two routes were equally good. They are not, and the operator's
 * instruction is that the Gmail lane is the primary path: one consent flow and
 * then nothing, against four steps in somebody else's settings and a
 * confirmation code to chase. See {@link MAIL_ROUTE_COPY}'s header.
 *
 * So the hierarchy is spent in one place. The mailbox lane is a raised panel
 * with an eyebrow, the honest liveness sentence, and the screen's one `primary`
 * Button; the forwarding lane is a question and a `ghost` Button below the rule.
 * Nothing else on the screen competes — no second bordered list, no chevrons, no
 * icon — because a "low emphasis" control next to a decorated one is not low
 * emphasis, it is a second card wearing smaller type.
 *
 * # The forwarding lane is never a downgrade, and on an unconfigured build it is
 * the only lane
 *
 * `mailStageScreen` fails closed: with no broker configured this screen is never
 * rendered at all and `Address`'s own address phase stands in its place,
 * unchanged and with no mention of Gmail. That is the honest arrangement — a
 * route that cannot work must not be advertised — and it is asserted in
 * `MailRoute.test.tsx` rather than left to the reader of two files.
 *
 * # Motion
 *
 * None. Onboarding steps are static tree-swaps with focus moved to the heading
 * by {@link Step}; the only motion on this screen is `Pressable`'s own
 * `whileTap`, which `Button` carries for free.
 */

import { Button } from "../../components/ui/Button";
import { SectionLabel } from "../../components/ui/SectionLabel";
import { MAIL_ROUTE_COPY, type MailRoute as MailRouteChoice } from "../../v2/onboarding";
import { SkipStep, Step } from "./Shell";

export interface MailRouteProps {
  /** Records the device-local route answer (`mail_route_chosen`). */
  onChoose: (route: MailRouteChoice) => void;
  /** "Set this up later" — skips the whole mail stage, exactly as the address skip does. */
  onSkip: () => void;
  embedded?: boolean;
}

export function MailRoute({ onChoose, onSkip, embedded = false }: MailRouteProps) {
  return (
    <Step
      testId="mail-route"
      embedded={embedded}
      title={MAIL_ROUTE_COPY.title}
      intro={MAIL_ROUTE_COPY.intro}
    >
      {/*
        The recommended lane. A single panel, and the only place on this screen
        that spends any weight: eyebrow, title, what it does, what it does NOT do
        (the liveness sentence — this lane has no background fetch, and saying so
        before the tap is the difference between a feature and a complaint), then
        the screen's one primary action.
      */}
      <div
        data-testid="mail-route-mailbox-panel"
        className="flex flex-col gap-3 p-4 rounded-[var(--radius)] border border-border bg-surface"
      >
        <SectionLabel>{MAIL_ROUTE_COPY.mailbox.eyebrow}</SectionLabel>
        <div className="flex flex-col gap-2">
          <h2 className="text-base font-semibold tracking-[-0.015em] text-fg">{MAIL_ROUTE_COPY.mailbox.title}</h2>
          <p className="text-sm leading-relaxed text-muted">{MAIL_ROUTE_COPY.mailbox.detail}</p>
          <p className="text-xs leading-relaxed text-muted">{MAIL_ROUTE_COPY.mailbox.liveness}</p>
        </div>
        <Button variant="primary" data-testid="mail-route-mailbox" onClick={() => onChoose("mailbox")}>
          {MAIL_ROUTE_COPY.mailbox.action}
        </Button>
      </div>

      {/*
        The other lane. Deliberately unboxed: a border here would rebuild the
        two-card layout this screen exists to replace. The hairline above it is
        the same divider `SkipStep` uses, so the page reads as one recommendation
        followed by two ways past it rather than as a list of three options.
      */}
      <div className="flex flex-col gap-2 pt-4 border-t border-border">
        <p className="text-sm font-medium text-fg">{MAIL_ROUTE_COPY.forward.offer}</p>
        <p className="text-xs leading-relaxed text-muted">{MAIL_ROUTE_COPY.forward.detail}</p>
        {/*
          `self-start` and no horizontal padding, so this reads as a text action
          rather than as a button. Full-width it matched `SkipStep`'s control
          exactly — same variant, same width, same centring — and the screen
          came out as a recommendation followed by two identical-looking
          alternatives, which is the flattening this rework exists to undo. The
          44px height stays; only the ink around it goes.
        */}
        <Button
          variant="ghost"
          className="self-start px-0 underline underline-offset-4 decoration-border"
          data-testid="mail-route-forward"
          onClick={() => onChoose("forward")}
        >
          {MAIL_ROUTE_COPY.forward.action}
        </Button>
      </div>

      {/* The mail stage's step is address_issued; skipping it skips forwarding
          too, the same policy the forwarding route already carries. */}
      <SkipStep step="address_issued" onSkip={onSkip} testId="mail-route-skip" />
    </Step>
  );
}
