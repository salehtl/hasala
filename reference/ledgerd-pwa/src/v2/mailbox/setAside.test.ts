/**
 * The set-aside log: the device-local record of mail that was NOT imported
 * because it did not come from a bank domain, and the grouping the user acts on.
 *
 * The load-bearing proofs, each with its mutation named in the task report:
 *   - the log is capped and counts what it dropped, so it can never grow
 *     unbounded inside the state row;
 *   - the same message id is never counted twice (a backfill re-lists);
 *   - "this is my bank" forgets exactly that domain's entries and nothing else.
 */
import { describe, expect, it } from "vitest";

import { memoryKeyStore } from "../mailboxToken";
import {
  MAX_SET_ASIDE_RECENT,
  emptySetAsideLog,
  forgetSetAsideDomain,
  recordSetAside,
  writeMailboxState,
  type SetAsideLog,
  type SetAsideRecord,
} from "./state";
import { SET_ASIDE_COPY, readMailboxSetAside, setAsideGroups, setAsideIdsForDomain } from "./setAside";

function rec(over: Partial<SetAsideRecord> = {}): SetAsideRecord {
  return {
    message_id: "m1",
    domain: "news.example.test",
    subject: "Your weekly digest",
    receivedAt: "2026-08-03T10:00:00.000Z",
    ...over,
  };
}

function logOf(records: readonly SetAsideRecord[]): SetAsideLog {
  let log = emptySetAsideLog();
  for (const r of records) log = recordSetAside(log, r);
  return log;
}

describe("recordSetAside", () => {
  it("counts a message once, however many times it is re-listed", () => {
    const log = logOf([rec(), rec({ subject: "different subject" })]);
    expect(log.count).toBe(1);
    expect(log.recent).toHaveLength(1);
  });

  it("caps the ring and counts what fell off it", () => {
    const many = Array.from({ length: MAX_SET_ASIDE_RECENT + 5 }, (_, i) => rec({ message_id: `m${i}` }));
    const log = logOf(many);
    expect(log.recent).toHaveLength(MAX_SET_ASIDE_RECENT);
    expect(log.count).toBe(MAX_SET_ASIDE_RECENT + 5);
    expect(log.dropped).toBe(5);
    // Newest kept, oldest dropped.
    expect(log.recent[log.recent.length - 1]!.message_id).toBe(`m${MAX_SET_ASIDE_RECENT + 4}`);
  });

  it("truncates a long subject rather than storing an unbounded string", () => {
    const log = logOf([rec({ subject: "x".repeat(500) })]);
    expect(log.recent[0]!.subject.length).toBeLessThanOrEqual(120);
  });
});

describe("setAsideGroups", () => {
  it("groups by sender domain with counts, busiest first", () => {
    const log = logOf([
      rec({ message_id: "a", domain: "news.example.test", receivedAt: "2026-08-01T00:00:00.000Z" }),
      rec({ message_id: "b", domain: "news.example.test", receivedAt: "2026-08-04T00:00:00.000Z" }),
      rec({ message_id: "c", domain: "shop.example.test" }),
    ]);

    const groups = setAsideGroups(log);
    expect(groups.map((g) => [g.domain, g.count])).toEqual([
      ["news.example.test", 2],
      ["shop.example.test", 1],
    ]);
    expect(groups[0]!.latestAt).toBe("2026-08-04T00:00:00.000Z");
    expect(groups[0]!.subjects).toContain("Your weekly digest");
  });

  it("puts the domain-less entries in one unknown group that offers no trust action", () => {
    const groups = setAsideGroups(logOf([rec({ message_id: "z", domain: "" })]));
    expect(groups).toHaveLength(1);
    expect(groups[0]!.domain).toBe("");
    expect(groups[0]!.canTrust).toBe(false);
  });

  /**
   * A hand-forward's set-aside group is the FORWARDER, not the bank. Trusting it
   * would auto-file everything relayed through the mailbox as permanent ops, and
   * `trustSender` plus the server's 409 `forwarder_domain` both refuse it — so
   * the button would only ever fail. The group still lists (it is real mail the
   * user should see); only the action is withheld.
   */
  it("offers no trust action on a forwarder group, while still listing it", () => {
    const groups = setAsideGroups(
      logOf([
        rec({ message_id: "f", domain: "gmail.com", subject: "Fwd: your statement" }),
        rec({ message_id: "g", domain: "accounts.google.com" }),
        rec({ message_id: "h", domain: "dib.ae" }),
      ]),
    );
    const byDomain = new Map(groups.map((g) => [g.domain, g]));
    expect(byDomain.get("gmail.com")?.canTrust).toBe(false);
    expect(byDomain.get("gmail.com")?.subjects).toContain("Fwd: your statement");
    expect(byDomain.get("accounts.google.com")?.canTrust).toBe(false);
    // The control: a real bank domain in the same log is still trustable, so
    // this cannot pass by refusing everything.
    expect(byDomain.get("dib.ae")?.canTrust).toBe(true);
  });
});

describe("setAsideIdsForDomain", () => {
  it("returns the message ids of that domain and its subdomains only", () => {
    const log = logOf([
      rec({ message_id: "a", domain: "dib.ae" }),
      rec({ message_id: "b", domain: "alerts.dib.ae" }),
      rec({ message_id: "c", domain: "notdib.ae" }),
    ]);
    expect(setAsideIdsForDomain(log, "dib.ae")).toEqual(["a", "b"]);
  });
});

describe("forgetSetAsideDomain", () => {
  it("drops that domain's entries and leaves every other domain intact", () => {
    const log = logOf([
      rec({ message_id: "a", domain: "dib.ae" }),
      rec({ message_id: "b", domain: "alerts.dib.ae" }),
      rec({ message_id: "c", domain: "news.example.test" }),
    ]);

    const after = forgetSetAsideDomain(log, "dib.ae");
    expect(after.recent.map((r) => r.message_id)).toEqual(["c"]);
    expect(after.count).toBe(1);
  });
});

describe("readMailboxSetAside", () => {
  it("reads the persisted log, and an untouched device reads an empty one", async () => {
    const store = memoryKeyStore();
    expect(await readMailboxSetAside(store)).toEqual({ count: 0, dropped: 0, recent: [] });

    await writeMailboxState(
      {
        historyId: "1",
        backfillDays: 30,
        lastCycleAt: null,
        unreadable: { count: 0, recent: [] },
        setAside: logOf([rec()]),
      },
      store,
    );

    expect((await readMailboxSetAside(store)).count).toBe(1);
  });
});

describe("the copy is honest about what set-aside means", () => {
  it("says the mail is still in the mailbox and nothing was lost", () => {
    const all = `${SET_ASIDE_COPY.title} ${SET_ASIDE_COPY.body} ${SET_ASIDE_COPY.trustHint}`.toLowerCase();
    expect(all).toContain("still in your mailbox");
    // Never a claim that they were deleted, dropped or filtered out for good.
    expect(all).not.toContain("deleted");
    expect(all).not.toContain("discarded");
  });
});
