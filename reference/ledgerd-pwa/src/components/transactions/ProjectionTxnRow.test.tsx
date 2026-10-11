import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import type { Txn } from "@ledger/client/replay/state";
import { ProjectionTxnRow } from "./ProjectionTxnRow";

const mk = (over: Partial<Txn> = {}): Txn => ({
  id: "t1",
  ingest_id: "i1",
  amount_minor: 31500n,
  currency: "AED",
  direction: "debit",
  posted_at: "2026-08-09T00:00:00Z",
  merchant_raw: "ETISALAT POSTPAID",
  last4: "",
  category: null,
  needs_review: false,
  unparsed: false,
  tier: "template",
  parse_error: null,
  provenance: "ingest",
  amount_home_minor: 31500n,
  splits: [],
  superseded_by: null,
  possible_duplicate_of: null,
  version: 1,
  ...over,
});

/** The row a real account produces and the harness seeds: every annotation at once. */
const loaded = () => mk({ provenance: "user", needs_review: true, amount_home_minor: null });

describe("ProjectionTxnRow", () => {
  it("opens the row on tap", () => {
    const onOpen = vi.fn();
    render(<ProjectionTxnRow txn={mk()} categoryDefs={[]} onOpen={onOpen} />);
    fireEvent.click(screen.getByRole("button", { name: /open etisalat postpaid/i }));
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("shows every annotation a row can carry at once", () => {
    render(<ProjectionTxnRow txn={loaded()} categoryDefs={[]} onOpen={() => {}} />);
    expect(screen.getByText("AED")).toBeInTheDocument();
    expect(screen.getByText("no home rate")).toBeInTheDocument();
    expect(screen.getByText("Added by you")).toBeInTheDocument();
    expect(screen.getByText("Needs review")).toBeInTheDocument();
  });

  /*
   * jsdom lays nothing out, so this asserts the CLASSES that make the wrap
   * possible rather than the wrap itself; the geometry proof is
   * `harness/v2shoot.mjs --screens transactions`, where those four annotations
   * measured 333px against the 324px a 390px phone leaves inside the list card
   * and `shrink-0` pushed 9px past an `overflow-hidden` edge with nothing to
   * scroll. What this test does catch is the regression that put it there: a
   * cluster pinned to one unbreakable line.
   */
  it("lets the annotation cluster shrink and wrap, and never the amount", () => {
    render(<ProjectionTxnRow txn={loaded()} categoryDefs={[]} onOpen={() => {}} />);
    const cluster = screen.getByText("Needs review").parentElement!;
    expect(cluster).toHaveClass("flex-wrap", "min-w-0", "justify-end");
    expect(cluster).not.toHaveClass("shrink-0");
    // The amount is the one thing that must never be the part that is lost.
    expect(screen.getByText("−315.00")).toHaveClass("shrink-0");
  });
});
