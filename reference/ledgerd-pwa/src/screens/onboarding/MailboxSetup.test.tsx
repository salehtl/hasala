/**
 * The mailbox route's whole sub-flow, driven through the real component with
 * everything network- and crypto-shaped injected (spec §3, D11).
 *
 * What this guards, in risk order:
 *   - The machine advances (`onConnected`) ONLY from the final Continue, never
 *     the instant the grant appears — the flash `MailboxSetup`'s header names.
 *   - Each connect failure kind gets its own honest copy, and the two reconnect
 *     kinds are not the same screen.
 *   - Both routes stay skippable, and the "forward instead" escape is on every
 *     screen a person can get stuck on.
 */

import { MotionProvider } from "../../app/MotionProvider";
import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

import type { StoredKeys, KeyVault } from "../../v2/keys";
import { MailboxError } from "../../v2/mailboxConnect";
import type { CycleReport } from "../../v2/mailbox/fetch";
import type { V2Handle } from "../../v2/session";
import { MailboxSetup, type MailboxSetupProps } from "./MailboxSetup";

const handle = {} as unknown as V2Handle;

const vault: KeyVault = {
  read: async (): Promise<StoredKeys> => ({
    accountId: "u_1",
    ingestPub: new Uint8Array(32),
    ingestPrivSealed: new Uint8Array(64),
    ingestPrivIv: new Uint8Array(12),
    dek: {} as CryptoKey,
  }),
  write: async () => undefined,
  clear: async () => undefined,
};

function setup(over: Partial<MailboxSetupProps> = {}) {
  const props: MailboxSetupProps = {
    handle,
    vault,
    onConnected: vi.fn(),
    onForward: vi.fn(),
    onSkip: vi.fn(),
    saveBackfill: vi.fn(async () => undefined),
    connect: vi.fn(async () => ({ email: "ledger.beta@example.com" })),
    ...over,
  };
  render(
    <MotionProvider>
      <MailboxSetup {...props} />
    </MotionProvider>,
  );
  return props;
}

describe("MailboxSetup", () => {
  it("walks guidance → connect → backfill → catching up, advancing only at the end", async () => {
    const runCatchUp = vi.fn(async (): Promise<CycleReport> => ({ fetched: 5, ops: 5, review: 1, unreadable: 0 }));
    const props = setup({ runCatchUp });

    // Guidance.
    expect(screen.getByTestId("mailbox-guidance")).toBeInTheDocument();
    await userEvent.click(screen.getByText("Connect with Google"));

    // Backfill, with the connected address shown and the grant NOT yet advancing.
    await screen.findByTestId("mailbox-backfill");
    expect(screen.getByTestId("mailbox-connected-label").textContent).toContain("ledger.beta@example.com");
    expect(props.onConnected).not.toHaveBeenCalled();

    // Choose 90 days and start catching up.
    await userEvent.click(screen.getByRole("button", { name: "90 days" }));
    await userEvent.click(screen.getByText("Start catching up"));

    await screen.findByTestId("mailbox-catching-up");
    expect(props.saveBackfill).toHaveBeenCalledWith(90);
    // The runner is handed the window AND the credentials this screen read on
    // mount — the walk assembles the rest of the fetch runtime and cannot read
    // the vault a second time without breaking the gesture rule above.
    await waitFor(() =>
      expect(runCatchUp).toHaveBeenCalledWith(90, { dek: expect.anything() as CryptoKey, accountId: "u_1" }),
    );
    // The honest liveness sentence is on the screen, not just a constant.
    expect(screen.getByTestId("mailbox-catching-up").textContent?.toLowerCase()).toMatch(/catches up when you open it/);

    // Only the final Continue advances the machine.
    expect(props.onConnected).not.toHaveBeenCalled();
    await userEvent.click(screen.getByText("Continue"));
    expect(props.onConnected).toHaveBeenCalledTimes(1);
  });

  /**
   * A first backfill is the run most likely to meet senders that are not the
   * account's banks. Leaving that count off the summary is a screen whose numbers
   * do not add up — 7 read, 5 filed, and nothing said about the other 3.
   */
  it("counts the mail it set aside, and says nothing left the mailbox", async () => {
    const runCatchUp = vi.fn(
      async (): Promise<CycleReport> => ({ fetched: 7, ops: 5, review: 1, unreadable: 0, setAside: 3 }),
    );
    setup({ runCatchUp });
    await userEvent.click(screen.getByText("Connect with Google"));
    await screen.findByTestId("mailbox-backfill");
    await userEvent.click(screen.getByText("Start catching up"));

    const line = await screen.findByTestId("mailbox-catchup-setaside");
    expect(line.textContent).toMatch(/^3 not from a bank ledger recognises/);
    expect(line.textContent).toMatch(/still in your mailbox/);
    // Never a claim that something was dropped, filtered or deleted.
    expect(line.textContent?.toLowerCase()).not.toMatch(/discard|delete|ignored|filtered/);
  });

  it("says nothing about set-aside mail when there was none", async () => {
    const runCatchUp = vi.fn(
      async (): Promise<CycleReport> => ({ fetched: 2, ops: 2, review: 0, unreadable: 0, setAside: 0 }),
    );
    setup({ runCatchUp });
    await userEvent.click(screen.getByText("Connect with Google"));
    await screen.findByTestId("mailbox-backfill");
    await userEvent.click(screen.getByText("Start catching up"));
    await screen.findByTestId("mailbox-catchup-summary");
    expect(screen.queryByTestId("mailbox-catchup-setaside")).toBeNull();
  });

  it("renders the connected label without a blank when the id_token had no email", async () => {
    setup({ connect: vi.fn(async () => ({ email: "" })) });
    await userEvent.click(screen.getByText("Connect with Google"));
    await screen.findByTestId("mailbox-backfill");
    expect(screen.getByTestId("mailbox-connected-label").textContent).toBe("Mailbox connected");
  });

  it("shows honest, DISTINCT copy for the two reconnect kinds", async () => {
    setup({ connect: vi.fn(async () => { throw new MailboxError("reconnect_required", "dead"); }) });
    await userEvent.click(screen.getByText("Connect with Google"));
    const required = (await screen.findByTestId("mailbox-error")).textContent ?? "";
    expect(required.toLowerCase()).toMatch(/no longer honours/);
    expect(required.toLowerCase()).not.toMatch(/already connected/);
    // No "one tap"/"one popup" shrinking, least of all here.
    expect(required.toLowerCase()).not.toMatch(/one tap|one popup/);
  });

  it("reconnect_incomplete says a mailbox was already connected, not that it is broken", async () => {
    setup({ connect: vi.fn(async () => { throw new MailboxError("reconnect_incomplete", "x"); }) });
    await userEvent.click(screen.getByText("Connect with Google"));
    const t = (await screen.findByTestId("mailbox-error")).textContent ?? "";
    expect(t.toLowerCase()).toMatch(/already connected/);
    expect(t.toLowerCase()).not.toMatch(/no longer honours/);
  });

  it("blames this device, never Google, when the key vault cannot be read", async () => {
    // The vault fault is entirely local: nothing has been sent. This used to
    // render `unavailable`, whose body says "Something went wrong on the way to
    // Google" — sending a user whose keys failed to go and check Google. The
    // connect path is reached during or just after onboarding, so the person
    // most exposed was a new user on their first connect.
    const connect = vi.fn(async () => ({ email: "never@called.test" }));
    setup({ vault: { read: async () => null, write: vault.write, clear: vault.clear }, connect });
    await userEvent.click(screen.getByText("Connect with Google"));
    const t = ((await screen.findByTestId("mailbox-error")).textContent ?? "").toLowerCase();
    expect(t).toMatch(/this device|keys/);
    expect(t).not.toMatch(/google|mailbox service|network|offline/);
    // Nothing was sent, so the ceremony must not have run.
    expect(connect).not.toHaveBeenCalled();
  });

  it("retries from an error back into the ceremony", async () => {
    const connect = vi
      .fn()
      .mockRejectedValueOnce(new MailboxError("cancelled", "closed"))
      .mockResolvedValueOnce({ email: "ledger.beta@example.com" });
    setup({ connect });
    await userEvent.click(screen.getByText("Connect with Google"));
    await screen.findByTestId("mailbox-error");
    await userEvent.click(screen.getByText("Try again"));
    await screen.findByTestId("mailbox-backfill");
    expect(connect).toHaveBeenCalledTimes(2);
  });

  it("reads the DEK on mount, not on the connect tap (the WebKit gesture fix)", async () => {
    // The popup must open synchronously inside the gesture, so `vault.read()`
    // (an await) must not sit between the tap and the connect. It is read once,
    // on mount; the tap re-uses it and never reads again.
    const read = vi.fn(vault.read);
    const connect = vi.fn(async () => ({ email: "x@gmail.com" }));
    setup({ vault: { read, write: vault.write, clear: vault.clear }, connect });
    await waitFor(() => expect(read).toHaveBeenCalledTimes(1));
    await userEvent.click(screen.getByText("Connect with Google"));
    expect(connect).toHaveBeenCalledTimes(1);
    expect(read).toHaveBeenCalledTimes(1); // NOT read again on the tap path
  });

  it("keeps Connect disabled until the DEK has been read", async () => {
    let resolveRead: (k: StoredKeys) => void = () => {};
    const read = vi.fn(() => new Promise<StoredKeys>((r) => (resolveRead = r)));
    setup({ vault: { read, write: vault.write, clear: vault.clear } });
    const button = () => screen.getByText("Connect with Google").closest("button")!;
    expect(button()).toBeDisabled();
    resolveRead({
      accountId: "u_1",
      ingestPub: new Uint8Array(32),
      ingestPrivSealed: new Uint8Array(64),
      ingestPrivIv: new Uint8Array(12),
      dek: {} as CryptoKey,
    });
    await waitFor(() => expect(button()).toBeEnabled());
  });

  it("keeps both escapes reachable: skip and forward-instead", async () => {
    const props = setup();
    await userEvent.click(screen.getByRole("button", { name: /forward to a ledger address/i }));
    expect(props.onForward).toHaveBeenCalledTimes(1);
    await userEvent.click(screen.getByText("Set this up later"));
    expect(props.onSkip).toHaveBeenCalledTimes(1);
  });
});
