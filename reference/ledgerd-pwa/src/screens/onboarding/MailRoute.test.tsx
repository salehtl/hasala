/**
 * The mail stage's opening screen, and the one question worth asking of it:
 * **is Gmail actually the primary path, or does it merely appear first?**
 *
 * The screen this replaced was two matching rows in one bordered list. Both had
 * the same weight, the same chevron and the same second line, so "first" was the
 * only difference between them — which is not a recommendation, it is an
 * ordering. The operator's instruction is that the Gmail lane IS the
 * recommendation and forwarding is the way past it.
 *
 * So these tests assert the hierarchy structurally rather than by reading the
 * copy: exactly one `primary` control on the screen, and it is the Gmail one.
 * A future edit that "balances" the two by promoting the forwarding button
 * fails here, which is the point — the copy could stay word for word the same
 * and the screen would still have stopped saying what it means.
 */

import { describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

import { MotionProvider } from "../../app/MotionProvider";
import { MAIL_ROUTE_COPY, mailStageScreen, emptyFacts } from "../../v2/onboarding";
import { MailRoute } from "./MailRoute";

function mount(over: { onChoose?: (r: "mailbox" | "forward") => void; onSkip?: () => void } = {}) {
  const onChoose = over.onChoose ?? vi.fn();
  const onSkip = over.onSkip ?? vi.fn();
  render(
    <MotionProvider>
      <MailRoute onChoose={onChoose} onSkip={onSkip} />
    </MotionProvider>,
  );
  return { onChoose, onSkip };
}

/** The app's primary control is the one carrying the spot ink as a fill. */
function isPrimary(el: HTMLElement): boolean {
  return el.className.includes("bg-accent");
}

describe("the mail route screen", () => {
  it("gives the screen exactly one primary action, and it is the Gmail one", () => {
    mount();
    const primary = screen.getAllByRole("button").filter(isPrimary);
    expect(primary).toHaveLength(1);
    expect(primary[0]).toBe(screen.getByTestId("mail-route-mailbox"));
  });

  it("makes forwarding a low-emphasis control, not a second card", () => {
    mount();
    const forward = screen.getByTestId("mail-route-forward");
    expect(isPrimary(forward)).toBe(false);
    // Not boxed: a bordered panel around it would rebuild the two-card layout
    // this screen exists to replace.
    expect(forward.closest("[data-testid='mail-route-mailbox-panel']")).toBeNull();
  });

  it("says which route is recommended rather than leaving it to position", () => {
    mount();
    const panel = screen.getByTestId("mail-route-mailbox-panel");
    expect(within(panel).getByText(MAIL_ROUTE_COPY.mailbox.eyebrow)).toBeInTheDocument();
    expect(within(panel).getByTestId("mail-route-mailbox")).toBeInTheDocument();
  });

  /**
   * The Gmail lane has no background fetch (spec D8). Said BEFORE the tap, on
   * the screen that recommends it, rather than discovered later as a
   * disappointment — the same sentence `CATCHING_UP_COPY.liveness` carries.
   */
  it("states the lane's honest liveness before the choice is made", () => {
    mount();
    const panel = screen.getByTestId("mail-route-mailbox-panel");
    expect(panel.textContent).toMatch(/catches up when you open it/i);
    expect(panel.textContent).toMatch(/does not fetch in the background/i);
    expect(panel.textContent).not.toMatch(/within a minute|real[- ]time|instantly/i);
  });

  /**
   * The button opens the burner guidance, not Google. Naming the consent flow
   * here would promise a screen this press does not reach — and the guidance is
   * the screen that tells the user the permission covers the whole mailbox,
   * which is the one thing they must know before consenting.
   */
  it("does not promise the Google window on a button that opens the guidance", () => {
    mount();
    expect(screen.getByTestId("mail-route-mailbox").textContent).not.toMatch(/connect with google/i);
    expect(screen.getByTestId("mail-route-mailbox").textContent).toMatch(/gmail/i);
  });

  it("reports each route, and keeps the skip always pressable", async () => {
    const user = userEvent.setup();
    const { onChoose, onSkip } = mount();
    await user.click(screen.getByTestId("mail-route-mailbox"));
    expect(onChoose).toHaveBeenCalledWith("mailbox");
    await user.click(screen.getByTestId("mail-route-forward"));
    expect(onChoose).toHaveBeenCalledWith("forward");
    const skip = screen.getByTestId("mail-route-skip");
    const button = within(skip).getByRole("button", { name: /set this up later/i });
    expect(button).toBeEnabled();
    await user.click(button);
    expect(onSkip).toHaveBeenCalledOnce();
  });

  /**
   * The fail-closed rule, asserted where a reader can see it rather than left
   * across two files.
   *
   * A deployment with no mailbox broker cannot connect anything, so this screen
   * is never rendered at all — `mailStageScreen` answers `"address"` and the
   * forwarding route stands alone, with no mention of Gmail anywhere. That is
   * what keeps the forwarding lane from reading as a downgrade on a build where
   * it is the only lane there is.
   */
  it("is never rendered at all when no broker is configured, whatever the device chose", () => {
    for (const mailRoute of [null, "mailbox", "forward"] as const) {
      expect(mailStageScreen({ ...emptyFacts(), mailRoute }, { mailboxConfigured: false })).toBe("address");
    }
    // And with one configured, an unanswered device gets this screen.
    expect(mailStageScreen({ ...emptyFacts(), mailRoute: null }, { mailboxConfigured: true })).toBe("route_choice");
  });
});
