/**
 * The delete-account screen.
 *
 * Two properties matter more than the rest, and both of them are the kind that
 * a screen can lose silently:
 *
 *  1. The destructive button cannot be reached by tapping. It needs a typed
 *     word, and until it is typed the ceremony must not run AT ALL — not "run
 *     and be refused".
 *  2. The unsent count is the REAL one, read from the outbox. A number this
 *     screen invented, or one that quietly said zero, would tell a person that
 *     nothing local is at stake on the screen where that is the one thing they
 *     cannot get back.
 */

import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

import { DeleteAccountPanel } from "./DeleteAccountPanel";
import { MotionProvider } from "../../app/MotionProvider";
import { PasskeyError } from "../../v2/session";

/** A handle whose outbox holds `pending` ops and whose device can author. */
function handleWith(pending: number, writerId: string | null = "device-1") {
  return {
    client: {
      pending: Array.from({ length: pending }, (_, i) => ({ op_id: `op-${String(i)}` })),
      get writerId(): string {
        if (writerId === null) throw new Error("this device is not set up to make changes yet");
        return writerId;
      },
    },
  } as never;
}

function show(node: React.ReactElement) {
  return render(<MotionProvider>{node}</MotionProvider>);
}

const button = () => screen.getByRole("button", { name: /delete my account/i });
const field = () => screen.getByLabelText(/type delete to confirm/i);

describe("DeleteAccountPanel", () => {
  it("says what is destroyed and that nobody can undo it, before anything is typed", () => {
    show(<DeleteAccountPanel handle={handleWith(0)} destroy={vi.fn()} wipe={vi.fn()} />);

    // On the screen, not behind a disclosure — a `getByText` that only passes
    // after a tap would be exactly the failure this asserts against.
    expect(screen.getByText(/cannot be undone/i)).toBeInTheDocument();
    expect(screen.getByText(/nobody can bring it back/i)).toBeInTheDocument();
    // And the operator is never offered as a way back.
    expect(screen.queryByText(/contact (support|the operator)/i)).toBeNull();
    // Mail in flight.
    expect(screen.getByText(/mail sent to it after that is refused/i)).toBeInTheDocument();
  });

  it("will not run the ceremony until the word is typed", async () => {
    const destroy = vi.fn();
    const wipe = vi.fn();
    show(<DeleteAccountPanel handle={handleWith(0)} destroy={destroy} wipe={wipe} />);

    expect(button()).toBeDisabled();
    await userEvent.click(button());
    expect(destroy).not.toHaveBeenCalled();

    // A near miss is still a miss.
    await userEvent.type(field(), "delet");
    expect(button()).toBeDisabled();
    await userEvent.click(button());
    expect(destroy).not.toHaveBeenCalled();

    await userEvent.type(field(), "e");
    expect(button()).toBeEnabled();
    await userEvent.click(button());
    await waitFor(() => {
      expect(destroy).toHaveBeenCalledTimes(1);
    });
    await waitFor(() => {
      expect(wipe).toHaveBeenCalledTimes(1);
    });
  });

  it("shows the real number of unsent changes", () => {
    show(<DeleteAccountPanel handle={handleWith(3)} destroy={vi.fn()} wipe={vi.fn()} />);

    const notice = screen.getByTestId("delete-account-unsent");
    expect(notice).toHaveTextContent("3 changes have not been sent yet");
    expect(notice).toHaveTextContent(/on this device only/i);
    expect(screen.queryByTestId("delete-account-synced")).toBeNull();
  });

  it("reads one unsent change as one, not as a plural", () => {
    show(<DeleteAccountPanel handle={handleWith(1)} destroy={vi.fn()} wipe={vi.fn()} />);
    expect(screen.getByTestId("delete-account-unsent")).toHaveTextContent("1 change has not been sent yet");
  });

  it("says so plainly when everything has already synced", () => {
    show(<DeleteAccountPanel handle={handleWith(0)} destroy={vi.fn()} wipe={vi.fn()} />);
    expect(screen.getByTestId("delete-account-synced")).toHaveTextContent(/reached the server/i);
    expect(screen.queryByTestId("delete-account-unsent")).toBeNull();
  });

  it("refuses to try at all from a device with no writer key", async () => {
    const destroy = vi.fn();
    show(<DeleteAccountPanel handle={handleWith(0, null)} destroy={destroy} wipe={vi.fn()} />);

    expect(screen.getByTestId("delete-account-no-key")).toBeInTheDocument();
    await userEvent.type(field(), "DELETE");
    expect(button()).toBeDisabled();
    await userEvent.click(button());
    expect(destroy).not.toHaveBeenCalled();
  });

  it("has no mailbox prompt when no grant is connected", async () => {
    const mailboxConnected = vi.fn(async () => false);
    show(
      <DeleteAccountPanel
        handle={handleWith(0)}
        destroy={vi.fn()}
        wipe={vi.fn()}
        mailboxConnected={mailboxConnected}
      />,
    );
    // Let the probe resolve, then the notice must still be absent.
    await waitFor(() => expect(mailboxConnected).toHaveBeenCalled());
    expect(screen.queryByTestId("delete-account-mailbox")).toBeNull();
  });

  it("prompts to disconnect the mailbox from Google first, and reuses the shared disconnect", async () => {
    const disconnectMailbox = vi.fn(async () => undefined);
    show(
      <DeleteAccountPanel
        handle={handleWith(0)}
        destroy={vi.fn()}
        wipe={vi.fn()}
        mailboxConnected={async () => true}
        disconnectMailbox={disconnectMailbox}
      />,
    );

    const notice = await screen.findByTestId("delete-account-mailbox");
    expect(notice).toHaveTextContent(/switch off google’s access/i);
    // The Google-account-page fallback is named up front, so a skipper has seen it.
    expect(notice).toHaveTextContent(/myaccount\.google\.com\/permissions/i);

    await userEvent.click(screen.getByTestId("delete-account-mailbox-disconnect"));
    await waitFor(() => expect(disconnectMailbox).toHaveBeenCalledTimes(1));
    // On success the notice gives way to the calm confirmation.
    expect(await screen.findByTestId("delete-account-mailbox-done")).toBeInTheDocument();
    expect(screen.queryByTestId("delete-account-mailbox")).toBeNull();
  });

  it("still deletes when the revoke fails, and shows the Google fallback copy", async () => {
    const destroy = vi.fn(async () => undefined);
    const wipe = vi.fn(async () => undefined);
    const disconnectMailbox = vi.fn(async () => {
      throw new Error("offline");
    });
    show(
      <DeleteAccountPanel
        handle={handleWith(0)}
        destroy={destroy}
        wipe={wipe}
        mailboxConnected={async () => true}
        disconnectMailbox={disconnectMailbox}
      />,
    );

    await userEvent.click(await screen.findByTestId("delete-account-mailbox-disconnect"));
    // The revoke failed: honest fallback, and it names Google's account page.
    const failed = await screen.findByTestId("delete-account-mailbox-failed");
    expect(failed).toHaveTextContent(/still delete your account/i);
    expect(screen.getByTestId("delete-account-mailbox")).toHaveTextContent(/google account/i);

    // The delete is never gated on the revoke — it goes through.
    await userEvent.type(field(), "DELETE");
    await userEvent.click(button());
    await waitFor(() => expect(destroy).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(wipe).toHaveBeenCalledTimes(1));
  });

  it("says the account is intact when the server refuses, and wipes nothing", async () => {
    const destroy = vi.fn(() => Promise.reject(new PasskeyError("rejected", "no")));
    const wipe = vi.fn();
    show(<DeleteAccountPanel handle={handleWith(0)} destroy={destroy} wipe={wipe} />);

    await userEvent.type(field(), "DELETE");
    await userEvent.click(button());

    const error = await screen.findByTestId("delete-account-error");
    expect(error).toHaveTextContent(/your account has not been deleted/i);
    expect(wipe).not.toHaveBeenCalled();
    // And the button comes back, because trying again is the right thing to do.
    await waitFor(() => {
      expect(button()).toBeEnabled();
    });
  });
});
