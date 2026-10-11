/**
 * The bank-domain set and the backfill narrowing query.
 *
 * The load-bearing proofs, each with its mutation named in the task report:
 *   - an EMPTY bank set falls back to the unfiltered query (an over-eager filter
 *     here would make a brand-new account import nothing, forever);
 *   - a set larger than the term bound falls back rather than truncating, so no
 *     sender is silently excluded from the backfill;
 *   - a domain that is not query-safe falls back whole, for the same reason.
 */
import { describe, expect, it } from "vitest";

import type { Definition } from "@ledger/client/tmpl/exec";

import { MAX_BACKFILL_FROM_TERMS, backfillQuery, bankDomainSet, isBankDomain, setAsideImportQuery } from "./bankDomains";

function template(id: string, domains: string[]): Definition {
  return {
    id,
    version: 1,
    bank: id,
    normalizer_version: 1,
    match: { sender_domain: domains },
    default_currency: "AED",
    date_from: "email",
    extract: [],
    required: [],
  } as unknown as Definition;
}

describe("bankDomainSet", () => {
  it("is the union of every template sender_domain and the account's trusted senders", () => {
    const set = bankDomainSet([template("dib", ["dib.ae"]), template("enbd", ["emiratesnbd.com"])], ["mashreq.com"]);
    expect(set).toEqual(["dib.ae", "emiratesnbd.com", "mashreq.com"]);
  });

  it("lower-cases, de-duplicates and drops blanks", () => {
    const set = bankDomainSet([template("a", ["DIB.ae", "", " "]), template("b", ["dib.ae"])], ["DIB.AE"]);
    expect(set).toEqual(["dib.ae"]);
  });

  it("is empty for a build with no templates and an account with no senders", () => {
    expect(bankDomainSet([], [])).toEqual([]);
  });
});

describe("isBankDomain", () => {
  const set = ["dib.ae", "emiratesnbd.com"];

  it("matches exactly and as a subdomain, the way the sender list already does", () => {
    expect(isBankDomain("dib.ae", set)).toBe(true);
    expect(isBankDomain("alerts.dib.ae", set)).toBe(true);
  });

  it("refuses a lookalike that merely ends with the same letters", () => {
    expect(isBankDomain("notdib.ae", set)).toBe(false);
    expect(isBankDomain("dib.ae.evil.test", set)).toBe(false);
  });

  it("refuses the empty domain and any domain off the set", () => {
    expect(isBankDomain("", set)).toBe(false);
    expect(isBankDomain("news.example.test", set)).toBe(false);
  });
});

describe("backfillQuery", () => {
  it("narrows to the bank domains with an OR group", () => {
    expect(backfillQuery(30, ["dib.ae", "emiratesnbd.com"])).toBe(
      "newer_than:30d -in:trash {from:dib.ae OR from:emiratesnbd.com}",
    );
  });

  it("falls back to the unfiltered window when the bank set is EMPTY", () => {
    // The whole product depends on this: a new account's sender list is empty by
    // construction, and its first bank message is what creates the review card
    // that trusts the domain. Filtering on an empty set imports nothing, forever.
    expect(backfillQuery(90, [])).toBe("newer_than:90d -in:trash");
  });

  it("falls back to the unfiltered window rather than truncating an over-long set", () => {
    const many = Array.from({ length: MAX_BACKFILL_FROM_TERMS + 1 }, (_, i) => `bank${i}.test`);
    expect(backfillQuery(30, many)).toBe("newer_than:30d -in:trash");
  });

  it("keeps a set exactly at the bound", () => {
    const many = Array.from({ length: MAX_BACKFILL_FROM_TERMS }, (_, i) => `bank${i}.test`);
    expect(backfillQuery(30, many)).toContain("{from:bank0.test OR ");
  });

  it("falls back whole when any domain is not query-safe, never dropping one silently", () => {
    expect(backfillQuery(30, ["dib.ae", 'evil".test'])).toBe("newer_than:30d -in:trash");
    expect(backfillQuery(30, ["dib.ae", "has space.test"])).toBe("newer_than:30d -in:trash");
  });

  // Spam is where forwarded bank mail lands: it fails SPF at the forwarding hop,
  // which is exactly what Gmail spam-files on. The request carries
  // `includeSpamTrash=true` (proven in gmail.test.ts), so the ONLY thing that
  // could exclude spam here is a query term — and there must not be one.
  it("never excludes spam, on any path through the query builder", () => {
    for (const q of [
      backfillQuery(30, ["dib.ae"]),
      backfillQuery(30, []),
      backfillQuery(30, Array.from({ length: MAX_BACKFILL_FROM_TERMS + 1 }, (_, i) => `b${i}.test`)),
      setAsideImportQuery(30, "dib.ae") ?? "",
    ]) {
      expect(q).not.toContain("-in:spam");
      expect(q).not.toContain("in:inbox");
      // …and Trash IS excluded on every one of them, which is the deliberate
      // other half of the call (see the doc on `windowTerms`).
      expect(q).toContain("-in:trash");
    }
  });
});

describe("setAsideImportQuery", () => {
  it("asks for one sender inside the window, spam included and trash excluded", () => {
    expect(setAsideImportQuery(90, "dib.ae")).toBe("newer_than:90d -in:trash from:dib.ae");
  });

  it("lower-cases and trims what the user's trusted domain gave it", () => {
    expect(setAsideImportQuery(30, "  DIB.AE ")).toBe("newer_than:30d -in:trash from:dib.ae");
  });

  it("returns null rather than build a query out of an unsafe domain", () => {
    // The caller answers null by importing the retained ids alone. A query built
    // from these could mean something other than "this sender".
    expect(setAsideImportQuery(30, 'evil".test')).toBeNull();
    expect(setAsideImportQuery(30, "has space.test")).toBeNull();
    expect(setAsideImportQuery(30, "")).toBeNull();
  });
});
