import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";

import type { MailboxState, UnreadableLog } from "../../v2/mailbox/state";
import type { CycleReport } from "../../v2/mailbox/fetch";
import { mailboxRevokeUnconfirmed } from "../../v2/mailboxConnect";
import { MailboxSettingsPanel, type MailboxSettingsPanelProps } from "./MailboxSettingsPanel";

function unreadable(count = 0): UnreadableLog {
  return { count, recent: [] };
}

function state(over: Partial<MailboxState> = {}): MailboxState {
  return {
    historyId: "h1",
    backfillDays: 30,
    lastCycleAt: "2026-08-12T10:00:00.000Z",
    unreadable: unreadable(),
    connectedEmail: "ledger.beta.7f3a@example.com",
    ...over,
  };
}

function props(over: Partial<MailboxSettingsPanelProps> = {}): MailboxSettingsPanelProps {
  return {
    loadGrantStatus: async () => "active",
    hasSealedToken: async () => true,
    loadState: async () => state(),
    forwardingConfigured: false,
    catchUpNow: async (): Promise<CycleReport> => ({ fetched: 3, ops: 2, review: 1, unreadable: 0, setAside: 0 }),
    importSetAside: async (): Promise<CycleReport> => ({ fetched: 1, ops: 1, review: 1, unreadable: 0, setAside: 0 }),
    saveBackfill: async () => undefined,
    onConnect: () => {},
    disconnect: async () => undefined,
    now: () => Date.parse("2026-08-12T10:05:00.000Z"),
    ...over,
  };
}

describe("MailboxSettingsPanel", () => {
  it("active: shows the connected address, a catch-up, backfill and disconnect", async () => {
    render(<MailboxSettingsPanel {...props()} />);
    expect(await screen.findByTestId("mailbox-settings")).toBeInTheDocument();
    expect(screen.getByTestId("mailbox-settings-connected-label").textContent).toMatch(/Connected as ledger.beta/);
    expect(screen.getByTestId("mailbox-settings-status").textContent?.toLowerCase()).toMatch(/last caught up/);
    expect(screen.getByTestId("mailbox-settings-catchup")).toBeInTheDocument();
    expect(screen.getByTestId("mailbox-settings-backfill")).toBeInTheDocument();
    expect(screen.getByTestId("mailbox-settings-disconnect")).toBeInTheDocument();
    // No D7 notice without forwarding also configured.
    expect(screen.queryByTestId("mailbox-settings-route-overlap")).toBeNull();
  });

  it("active: 'Catch up now' runs a cycle and renders its counts", async () => {
    render(<MailboxSettingsPanel {...props()} />);
    fireEvent.click(await screen.findByTestId("mailbox-settings-catchup"));
    const summary = await screen.findByTestId("mailbox-settings-catchup-summary");
    expect(summary.textContent).toMatch(/3 emails read/);
    expect(summary.textContent).toMatch(/1 filed as a transaction/);
    expect(summary.textContent).toMatch(/1 waiting for review/);
  });

  // A halted cycle used to render as a cheerful "0 emails read" with no other
  // sign — the failure class the repo calls "a UI sentence the code does not
  // honour". A broken mailbox is indistinguishable from an empty one, which is
  // exactly how a real connect failure went undiagnosed. Delete the halted
  // paragraph and this fails.
  it("a halted cycle says so, and says why — never a silent zero", async () => {
    render(
      <MailboxSettingsPanel
        {...props({
          catchUpNow: async (): Promise<CycleReport> => ({
            fetched: 0,
            ops: 0,
            review: 0,
            unreadable: 0,
            haltedOn: "error",
            haltedDetail: "Gmail refused the request (403).",
          }),
        })}
      />,
    );
    fireEvent.click(await screen.findByTestId("mailbox-settings-catchup"));
    const halted = await screen.findByTestId("mailbox-settings-catchup-halted");
    expect(halted.textContent).toMatch(/could not finish reading/i);
    expect(halted.textContent).toMatch(/403/);
  });

  it("active + forwarding configured: shows the D7 'pick one route per bank' notice", async () => {
    render(<MailboxSettingsPanel {...props({ forwardingConfigured: true })} />);
    expect(await screen.findByTestId("mailbox-settings-route-overlap")).toBeInTheDocument();
  });

  it("active: the durable unreadable count is shown as its own surface", async () => {
    render(<MailboxSettingsPanel {...props({ loadState: async () => state({ unreadable: unreadable(4) }) })} />);
    const box = await screen.findByTestId("mailbox-settings-unreadable");
    expect(box.textContent?.toLowerCase()).toMatch(/4 messages couldn't be read/);
  });

  it("reconnect_required and another_device are DISTINCT renders, not one component", async () => {
    const { unmount } = render(<MailboxSettingsPanel {...props({ loadGrantStatus: async () => "reconnect_required" })} />);
    expect(await screen.findByTestId("mailbox-settings-reconnect")).toBeInTheDocument();
    expect(screen.queryByTestId("mailbox-settings-another-device")).toBeNull();
    unmount();

    render(<MailboxSettingsPanel {...props({ loadGrantStatus: async () => "active", hasSealedToken: async () => false })} />);
    expect(await screen.findByTestId("mailbox-settings-another-device")).toBeInTheDocument();
    expect(screen.queryByTestId("mailbox-settings-reconnect")).toBeNull();
  });

  it("never_connected: offers a connect affordance and no catch-up/disconnect", async () => {
    render(<MailboxSettingsPanel {...props({ loadGrantStatus: async () => null })} />);
    expect(await screen.findByTestId("mailbox-settings-never-connected")).toBeInTheDocument();
    expect(screen.getByTestId("mailbox-settings-connect")).toBeInTheDocument();
    expect(screen.queryByTestId("mailbox-settings-catchup")).toBeNull();
    expect(screen.queryByTestId("mailbox-settings-disconnect")).toBeNull();
  });

  it("disconnect: confirm calls disconnect and lands on the disconnected state", async () => {
    const disconnect = vi.fn(async () => undefined);
    render(<MailboxSettingsPanel {...props({ disconnect })} />);
    fireEvent.click(await screen.findByTestId("mailbox-settings-disconnect"));
    fireEvent.click(await screen.findByTestId("mailbox-settings-disconnect-confirm"));
    await waitFor(() => expect(disconnect).toHaveBeenCalledTimes(1));
    expect(await screen.findByTestId("mailbox-settings-disconnected")).toBeInTheDocument();
  });

  // The disconnect sweeps this device's sealed token and mailbox state BEFORE
  // the fallible network steps. So when the revoke cannot reach Google, ledger
  // has ALREADY stopped reading the mailbox — treating that as a plain failure
  // would leave the panel saying "connected" about a mailbox it can no longer
  // read, and the old copy said "Nothing changed", which was false.
  it("an unconfirmed revoke is a disconnect with a warning, not a failure", async () => {
    const disconnect = vi.fn(async () => {
      throw mailboxRevokeUnconfirmed(new Error("503"));
    });
    render(<MailboxSettingsPanel {...props({ disconnect })} />);
    fireEvent.click(await screen.findByTestId("mailbox-settings-disconnect"));
    fireEvent.click(await screen.findByTestId("mailbox-settings-disconnect-confirm"));

    // It names Google's own permissions page, because that is the only place
    // the outstanding half can be finished.
    const note = await screen.findByTestId("mailbox-settings-revoke-unconfirmed");
    expect(note.textContent ?? "").toMatch(/myaccount\.google\.com\/permissions/);
    // And it must NOT claim nothing changed.
    expect(note.textContent ?? "").not.toMatch(/nothing changed/i);

    // Acknowledging lands on the disconnected state — the mailbox really is gone.
    fireEvent.click(await screen.findByTestId("mailbox-settings-revoke-unconfirmed-ack"));
    expect(await screen.findByTestId("mailbox-settings-disconnected")).toBeInTheDocument();
  });

  it("a genuine disconnect failure still reports a failure", async () => {
    const disconnect = vi.fn(async () => {
      throw new Error("nope");
    });
    render(<MailboxSettingsPanel {...props({ disconnect })} />);
    fireEvent.click(await screen.findByTestId("mailbox-settings-disconnect"));
    fireEvent.click(await screen.findByTestId("mailbox-settings-disconnect-confirm"));

    const alert = await screen.findByRole("alert");
    expect(alert.textContent ?? "").not.toMatch(/nothing changed/i);
    expect(screen.queryByTestId("mailbox-settings-revoke-unconfirmed")).toBeNull();
    expect(screen.queryByTestId("mailbox-settings-disconnected")).toBeNull();
  });

  it("a grant-read failure renders a distinct error state, not 'never connected'", async () => {
    render(
      <MailboxSettingsPanel
        {...props({
          loadGrantStatus: async () => {
            throw new Error("503");
          },
        })}
      />,
    );
    expect(await screen.findByTestId("mailbox-settings-error")).toBeInTheDocument();
    expect(screen.queryByTestId("mailbox-settings-never-connected")).toBeNull();
  });

  // Filtering is only honest if the user can see what was held back and
  // overrule it. Drop the SetAsideSection from the panel and this fails.
  it("active: lists set-aside senders and imports one on 'This is my bank'", async () => {
    const importSetAside = vi.fn(
      async (): Promise<CycleReport> => ({ fetched: 2, ops: 2, review: 2, unreadable: 0, setAside: 0 }),
    );
    render(
      <MailboxSettingsPanel
        {...props({
          importSetAside,
          loadState: async () =>
            state({
              setAside: {
                count: 2,
                dropped: 0,
                recent: [
                  { message_id: "a", domain: "news.example.test", subject: "Digest", receivedAt: "2026-08-01T00:00:00.000Z" },
                  { message_id: "b", domain: "alerts.mybank.test", subject: "Card transaction", receivedAt: "2026-08-02T00:00:00.000Z" },
                ],
              },
            }),
        })}
      />,
    );

    expect(await screen.findByTestId("mailbox-set-aside")).toBeInTheDocument();
    fireEvent.click(screen.getByTestId("mailbox-set-aside-trust-alerts.mybank.test"));
    await waitFor(() => expect(importSetAside).toHaveBeenCalledWith("alerts.mybank.test"));
  });

  it("active: a catch-up that set mail aside says so in its summary", async () => {
    render(
      <MailboxSettingsPanel
        {...props({
          catchUpNow: async (): Promise<CycleReport> => ({ fetched: 5, ops: 1, review: 1, unreadable: 0, setAside: 4 }),
        })}
      />,
    );
    fireEvent.click(await screen.findByTestId("mailbox-settings-catchup"));
    const line = await screen.findByTestId("mailbox-settings-catchup-setaside");
    expect(line.textContent).toMatch(/4 not from a bank ledger recognises/);
    expect(line.textContent).toMatch(/still in your mailbox/);
  });
});
