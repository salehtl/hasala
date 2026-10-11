import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";

import type { CycleReport } from "../../v2/mailbox/fetch";
import type { SetAsideLog } from "../../v2/mailbox/state";
import { SetAsideSection } from "./SetAsideSection";

function log(over: Partial<SetAsideLog> = {}): SetAsideLog {
  return {
    count: 3,
    dropped: 0,
    recent: [
      { message_id: "a", domain: "news.example.test", subject: "Your weekly digest", receivedAt: "2026-08-01T00:00:00.000Z" },
      { message_id: "b", domain: "news.example.test", subject: "Another digest", receivedAt: "2026-08-02T00:00:00.000Z" },
      { message_id: "c", domain: "dib.test", subject: "Card transaction", receivedAt: "2026-08-03T00:00:00.000Z" },
    ],
    ...over,
  };
}

const report = (over: Partial<CycleReport> = {}): CycleReport => ({
  fetched: 1,
  ops: 1,
  review: 1,
  unreadable: 0,
  setAside: 0,
  ...over,
});

describe("SetAsideSection", () => {
  it("renders nothing when nothing was set aside", () => {
    render(<SetAsideSection log={{ count: 0, dropped: 0, recent: [] }} importDomain={async () => report()} />);
    expect(screen.queryByTestId("mailbox-set-aside")).toBeNull();
  });

  it("groups by sender with counts and says the mail is still in the mailbox", () => {
    render(<SetAsideSection log={log()} importDomain={async () => report()} />);
    const section = screen.getByTestId("mailbox-set-aside");
    expect(section.textContent).toMatch(/still in your mailbox/i);
    expect(screen.getByTestId("mailbox-set-aside-group-news.example.test").textContent).toMatch(/2 messages/);
    expect(screen.getByTestId("mailbox-set-aside-group-dib.test").textContent).toMatch(/1 message/);
    // The subject is what lets a human recognise their bank.
    expect(screen.getByTestId("mailbox-set-aside-group-dib.test").textContent).toMatch(/Card transaction/);
  });

  it("'This is my bank' imports that domain and reports what it imported", async () => {
    const importDomain = vi.fn(async () => report({ fetched: 1, ops: 1 }));
    const onImported = vi.fn();
    render(<SetAsideSection log={log()} importDomain={importDomain} onImported={onImported} />);

    fireEvent.click(screen.getByTestId("mailbox-set-aside-trust-dib.test"));

    await waitFor(() => expect(screen.getByTestId("mailbox-set-aside-imported-dib.test")).toBeInTheDocument());
    expect(importDomain).toHaveBeenCalledWith("dib.test");
    expect(screen.getByTestId("mailbox-set-aside-imported-dib.test").textContent).toMatch(/1 message imported/);
    expect(onImported).toHaveBeenCalledWith("dib.test", expect.objectContaining({ ops: 1 }));
    // The other sender is untouched: trusting one bank trusts one bank.
    expect(screen.getByTestId("mailbox-set-aside-trust-news.example.test")).toBeInTheDocument();
  });

  // A halted import wrote nothing it could not push. Reporting "0 messages
  // imported" as a success is the failure class this repo keeps producing: a UI
  // sentence the code does not honour.
  it("says an import failed rather than reporting a cheerful zero", async () => {
    render(
      <SetAsideSection
        log={log()}
        importDomain={async () => report({ fetched: 1, ops: 1, haltedOn: "budget_full" })}
      />,
    );
    fireEvent.click(screen.getByTestId("mailbox-set-aside-trust-dib.test"));
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());
    expect(screen.queryByTestId("mailbox-set-aside-imported-dib.test")).toBeNull();
  });

  it("says a thrown import failed and leaves the action available", async () => {
    render(
      <SetAsideSection
        log={log()}
        importDomain={async () => {
          throw new Error("offline");
        }}
      />,
    );
    fireEvent.click(screen.getByTestId("mailbox-set-aside-trust-dib.test"));
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());
    expect(screen.getByTestId("mailbox-set-aside-trust-dib.test")).toBeEnabled();
  });

  it("offers no trust action for mail whose sender it could not identify", () => {
    render(
      <SetAsideSection
        log={{ count: 1, dropped: 0, recent: [{ message_id: "z", domain: "", subject: "", receivedAt: "" }] }}
        importDomain={async () => report()}
      />,
    );
    expect(screen.getByTestId("mailbox-set-aside-group-unknown")).toBeInTheDocument();
    expect(screen.queryByTestId("mailbox-set-aside-trust-")).toBeNull();
  });

  it("says out loud how many older messages are not listed", () => {
    render(<SetAsideSection log={log({ count: 250, dropped: 50 })} importDomain={async () => report()} />);
    expect(screen.getByTestId("mailbox-set-aside-dropped").textContent).toMatch(/50 older messages are not listed/);
  });
});
