import { describe, expect, it } from "vitest";

import type { Txn } from "@ledger/client/replay/state";

import {
  bucketOf,
  cardIdSource,
  deckAmount,
  deckCard,
  deckCategories,
  deckRows,
  mailboxProvenanceOf,
} from "./reviewDeck";
import type { ReviewItem } from "./sources/review";

function txn(over: Partial<Txn> = {}): Txn {
  return {
    id: "t1",
    ingest_id: "a".repeat(64),
    amount_minor: 25_000n,
    currency: "AED",
    direction: "debit",
    posted_at: "2026-07-11T08:00:00Z",
    merchant_raw: "CARREFOUR",
    last4: "8642",
    category: null,
    needs_review: true,
    provenance: "ingest",
    amount_home_minor: 25_000n,
    unparsed: false,
    tier: "template",
    parse_error: "",
    superseded_by: null,
    possible_duplicate_of: null,
    duplicate_disposition: null,
    version: 1,
    splits: [],
    ...over,
  } as Txn;
}

const item = (t: Txn): ReviewItem => ({ key: `txn:${t.id}`, lane: "needs_review", reason: "unsigned_headers", txn: t, counterpart: null });

describe("deckAmount", () => {
  it("formats from the bigint, never a number", () => {
    // 2^53 fils would be lossy through a JS number; the figure below is exact
    // only because nothing converts.
    const big = deckAmount(txn({ amount_minor: 90_071_992_547_409_93n, amount_home_minor: 90_071_992_547_409_93n }), "AED");
    expect(big.text).toBe("−90,071,992,547,409.93");
  });

  it("names the currency the figure is actually in", () => {
    const converted = deckAmount(txn({ currency: "USD", amount_minor: 1_009n, amount_home_minor: 3_706n }), "AED");
    expect(converted.label).toBe("Spent · AED");
    expect(converted.note).toBe("USD 10.09");
  });

  it("says so when there is no rate, instead of labelling the native amount as home", () => {
    // v1's bug: the hero fell back to the native amount while the label still
    // said AED, so a USD 10.09 charge read as AED 10.09 at 48px.
    const none = deckAmount(txn({ currency: "USD", amount_minor: 1_009n, amount_home_minor: null }), "AED");
    expect(none.label).toBe("Spent · USD");
    expect(none.text).toBe("−10.09");
    expect(none.note).toBe("no AED rate yet");
  });

  it("prints an em dash for a row nothing was read out of", () => {
    const empty = deckAmount(txn({ unparsed: true, direction: "", currency: "", amount_minor: 0n, amount_home_minor: null }), "AED");
    expect(empty.text).toBe("—");
  });

  it("marks a credit", () => {
    expect(deckAmount(txn({ direction: "credit" }), "AED").credit).toBe(true);
  });
});

describe("deckCard", () => {
  it("carries no amount at all, because the hero is stated separately", () => {
    expect(deckCard(item(txn()), 0).AmountFils).toBe(0);
  });

  it("gives an unreadable row a name rather than an empty card", () => {
    expect(deckCard(item(txn({ merchant_raw: "" })), 0).MerchantRaw).toBe("Unreadable message");
  });

  it("offers no source-email link, because there is no route to serve it", () => {
    expect(deckCard(item(txn()), 0).Source).toBe("");
  });

  it("numbers cards from the id source rather than from the feed", () => {
    const rows = deckRows([item(txn({ id: "a" })), item(txn({ id: "b" }))], "AED", cardIdSource());
    expect(rows.map((r) => r.card.ID)).toEqual([1, 2]);
    expect(rows[1]!.item.txn.id).toBe("b");
  });
});

describe("cardIdSource", () => {
  it("gives a transaction the same id for as long as it is asked", () => {
    const idFor = cardIdSource();
    expect(idFor("a")).toBe(1);
    expect(idFor("b")).toBe(2);
    expect(idFor("a")).toBe(1);
  });

  it("does not renumber when a row leaves the feed", () => {
    // THE property. A position would renumber here, and the undo toast — which
    // holds the card it committed — would resolve a different transaction.
    const idFor = cardIdSource();
    const before = deckRows([item(txn({ id: "a" })), item(txn({ id: "b" }))], "AED", idFor);
    // A sync folds "a" out of the lane while the toast for it is still up.
    const after = deckRows([item(txn({ id: "b" }))], "AED", idFor);
    expect(before.find((r) => r.item.txn.id === "b")!.card.ID).toBe(after[0]!.card.ID);
    expect(after[0]!.card.ID).toBe(2);
    // …and the id "a" held is never handed to anybody else.
    expect(idFor("c")).toBe(3);
    expect(idFor("a")).toBe(1);
  });
});

describe("deckCategories", () => {
  it("puts a category in the bucket the budget already sums it under", () => {
    expect(bucketOf("Groceries")).toBe("need");
    expect(bucketOf("Dining")).toBe("want");
    // Nothing maps it, so it is discretionary until the user says otherwise.
    expect(bucketOf("Falconry")).toBe("want");
  });

  it("fills every rail even for an account with no history", () => {
    const cats = deckCategories([]);
    for (const bucket of ["need", "want", "saving"]) {
      expect(cats.some((c) => c.Kind === "spending" && c.Bucket === bucket)).toBe(true);
    }
    expect(cats.some((c) => c.Kind === "excluded" && c.Name === "Transfer")).toBe(true);
    expect(cats.some((c) => c.Kind === "income")).toBe(true);
  });

  it("puts the user's own categories first and does not duplicate them", () => {
    const cats = deckCategories(["Groceries", "Falconry"]);
    expect(cats[0]!.Name).toBe("Groceries");
    expect(cats.filter((c) => c.Name.toLowerCase() === "groceries").length).toBe(1);
    expect(cats.every((c) => c.IsActive)).toBe(true);
  });

  it("with NO definitions the grid is exactly what it has always been", () => {
    // Backwards compatibility, asserted against the call every caller made
    // before definitions existed.
    expect(deckCategories(["Groceries", "Falconry"], [])).toEqual(deckCategories(["Groceries", "Falconry"]));
  });

  it("offers a defined category, in the bucket it was defined in", () => {
    const cats = deckCategories([], [
      { id: "c1", name: "Gym", kind: "spending", bucket: "need", color: "#1373d9", active: true },
    ]);
    const gym = cats.find((c) => c.Name === "Gym");
    // A need, from its definition — not `bucketOf`'s "nothing maps it, so want".
    expect(gym).toMatchObject({ Kind: "spending", Bucket: "need", Color: "#1373d9" });
    expect(cats[0]!.Name).toBe("Gym");
  });

  it("offers a re-added name even though an older def of the same name is retired", () => {
    // Add "Gym", retire it, add "Gym" again: the panel mints a NEW id, so the
    // log holds one inactive def and one active def with the same name. The
    // withheld-names set must not let the corpse outvote the living: a name
    // with ANY active def is offered. Found in the field 2026-08-11 — two
    // user categories invisible in every picker on every screen, forever.
    const cats = deckCategories([], [
      { id: "old", name: "Gym", kind: "spending", bucket: "need", color: null, active: false },
      { id: "new", name: "Gym", kind: "spending", bucket: "need", color: null, active: true },
    ]);
    expect(cats.map((c) => c.Name)).toContain("Gym");
    // And in the bucket the ACTIVE def declares, not the retired one's.
    expect(cats.find((c) => c.Name === "Gym")?.Bucket).toBe("need");
  });

  it("stops offering a retired one, even where the user has already used it", () => {
    const retired = [
      { id: "c1", name: "Gym", kind: "spending", bucket: "need", color: null, active: false } as const,
    ];
    // "Gym" is in the used-names list — it is in the user's history — and it
    // must still leave the picker: retiring is what "stop offering this" means.
    const cats = deckCategories(["Gym", "Groceries"], retired);
    expect(cats.some((c) => c.Name.toLowerCase() === "gym")).toBe(false);
    expect(cats.some((c) => c.Name === "Groceries")).toBe(true);
  });

  it("a retired name that clashes with a built-in one is still withheld", () => {
    // "Dining" is seeded from DEFAULT_BUDGET_MAPPING, so a retirement has to be
    // able to remove a name the grid would otherwise supply itself.
    const cats = deckCategories([], [
      { id: "c2", name: "Dining", kind: "spending", bucket: "want", color: null, active: false },
    ]);
    expect(cats.some((c) => c.Name.toLowerCase() === "dining")).toBe(false);
  });

  it("gives the Transfer rail a set to choose from, not one name equal to the rail", () => {
    // The Transfer rail opens the same picker every other rail does. Seeding it
    // with the single name "Transfer" made that picker a question with one
    // answer, which is the rail's own label — no reason to exclude was ever on
    // offer. Every rail gets a real set.
    const excluded = deckCategories([]).filter((c) => c.Kind === "excluded");
    expect(excluded.length).toBeGreaterThan(1);
    expect(excluded.map((c) => c.Name)).toContain("Transfer");
    const income = deckCategories([]).filter((c) => c.Kind === "income");
    expect(income.length).toBeGreaterThan(1);
  });

  it("a used name that IS a built-in transfer name stays on the Transfer rail", () => {
    // Every used name arrives here as `spending`, and the grid de-duplicates by
    // name — so sorting one card into "Transfer" used to shadow the built-in
    // excluded entry of the same name and leave the Transfer rail's sheet
    // EMPTY, for good. Found in the field 2026-08-16.
    const cats = deckCategories(["Transfer", "Groceries"]);
    const transfer = cats.filter((c) => c.Name === "Transfer");
    expect(transfer.length).toBe(1);
    expect(transfer[0]!.Kind).toBe("excluded");
    // And it is not also sitting in a spending bucket, where `bucketOf` would
    // have filed an unmapped name under Want.
    expect(cats.some((c) => c.Name === "Transfer" && c.Kind === "spending")).toBe(false);
  });

  it("a used name that IS a built-in income name stays income", () => {
    // The same collision, on the other non-spending kind: an imported ledger
    // that files salary under "Income" emptied the credit card's income group.
    const cats = deckCategories(["Income", "Groceries"]);
    expect(cats.find((c) => c.Name === "Income")?.Kind).toBe("income");
    expect(cats.filter((c) => c.Kind === "income").length).toBeGreaterThan(0);
  });

  it("the user's own definition still beats the built-in classification", () => {
    // Defining "Transfer" as a spending need is a deliberate act and wins; the
    // rail keeps its other built-ins, so it does not empty out either.
    const cats = deckCategories(["Transfer"], [
      { id: "c1", name: "Transfer", kind: "spending", bucket: "need", color: null, active: true },
    ]);
    expect(cats.find((c) => c.Name === "Transfer")).toMatchObject({ Kind: "spending", Bucket: "need" });
    expect(cats.some((c) => c.Kind === "excluded")).toBe(true);
  });

  it("buckets a category by the user's definition, retired or not", () => {
    const defs = [
      { id: "c1", name: "Falconry", kind: "spending", bucket: "need", color: null, active: false } as const,
    ];
    // The money already filed under a retired category still belongs to its
    // bucket, so the lookup must not care whether it is active.
    expect(bucketOf("Falconry", defs)).toBe("need");
    expect(bucketOf("Falconry")).toBe("want");
  });
});

describe("mailboxProvenanceOf", () => {
  const prov = { provider: "gmail", grant_id: "acct-1", message_id: "m-42" };

  it("reads a well-formed mailbox provenance out of an op payload", () => {
    expect(mailboxProvenanceOf({ unparsed: true, provenance: prov })).toEqual(prov);
  });

  it("is null for a payload with no provenance (a hand-typed row)", () => {
    expect(mailboxProvenanceOf({ merchant_raw: "Corner Shop" })).toBeNull();
  });

  it("is null when any id is missing or empty — a half-read id must not re-fetch", () => {
    expect(mailboxProvenanceOf({ provenance: { provider: "gmail", grant_id: "acct-1", message_id: "" } })).toBeNull();
    expect(mailboxProvenanceOf({ provenance: { provider: "gmail", message_id: "m-42" } })).toBeNull();
    expect(mailboxProvenanceOf({ provenance: { provider: "", grant_id: "a", message_id: "m" } })).toBeNull();
  });

  it("is null for non-object inputs, never a throw", () => {
    expect(mailboxProvenanceOf(null)).toBeNull();
    expect(mailboxProvenanceOf(undefined)).toBeNull();
    expect(mailboxProvenanceOf("provenance")).toBeNull();
    expect(mailboxProvenanceOf({ provenance: "gmail" })).toBeNull();
  });
});
