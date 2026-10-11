import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { Category, Txn } from "../../api/types";
import { SwipeDeck } from "./SwipeDeck";
import { ToastProvider } from "../Toast";
import { MotionProvider } from "../../app/MotionProvider";
import { DEFAULT_SWIPE_CONFIG } from "../../lib/swipe";

// One category per rail, so every rail has something to open onto. A deck with
// none is its own case, at the bottom of this file.
const CATS: Category[] = [
  { ID: 1, Name: "Dining", Kind: "spending", Bucket: "want", IsActive: true, Color: "" },
  { ID: 2, Name: "Groceries", Kind: "spending", Bucket: "need", IsActive: true, Color: "" },
  { ID: 3, Name: "Savings", Kind: "spending", Bucket: "saving", IsActive: true, Color: "" },
  { ID: 4, Name: "Transfer", Kind: "excluded", Bucket: "", IsActive: true, Color: "" },
];

function txn(p: Partial<Txn> = {}): Txn {
  return {
    ID: 1, PostedAt: "2026-07-03T10:00:00Z", AmountFils: 5000, AmountAedFils: 5000, Currency: "AED",
    Direction: "debit", MerchantRaw: "Carrefour", Status: "needs_review", Confidence: 1, Source: "email",
    CategoryID: null, CategoryName: "", Bucket: "", Kind: "", BucketSnapshot: "", RefundOfID: null,
    ...p,
  };
}

function renderDeck(transactions: Txn[], categories: Category[] = CATS) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  // MotionProvider: `strict` does not throw on an unwrapped `m.*`, it renders
  // with no features loaded — the card's drag and exit would be silently inert
  // and the deck would only look covered.
  render(
    <MotionProvider>
      <QueryClientProvider client={qc}>
        <ToastProvider>
          <SwipeDeck transactions={transactions} categories={categories} />
        </ToastProvider>
      </QueryClientProvider>
    </MotionProvider>,
  );
}

afterEach(() => vi.restoreAllMocks());

// The rails render as filled, labelled pills that look exactly like buttons.
// They used to be pointer-events-none decoration, which made swiping the only
// way to triage anything — no keyboard, switch control, or screen-reader path.
describe("SwipeDeck bucket rails", () => {
  it("exposes all four rails as real buttons", () => {
    renderDeck([txn()]);
    for (const dir of ["up", "down", "left", "right"] as const) {
      const label = DEFAULT_SWIPE_CONFIG[dir].label;
      expect(screen.getByRole("button", { name: new RegExp(label, "i") })).toBeInTheDocument();
    }
  });

  it("starts the same sort a swipe would, with no gesture involved", async () => {
    renderDeck([txn({ ID: 7 })]);
    fireEvent.click(screen.getByRole("button", { name: new RegExp(DEFAULT_SWIPE_CONFIG.left.label, "i") }));
    // A left swipe opens the category panel to finish the sort; tapping the
    // rail must reach that same state rather than doing nothing.
    expect(await screen.findByRole("dialog")).toBeInTheDocument();
  });

  it("opens the transfer sheet when the Transfer rail has categories", async () => {
    renderDeck([txn({ ID: 8 })]);
    fireEvent.click(screen.getByRole("button", { name: new RegExp(DEFAULT_SWIPE_CONFIG.up.label, "i") }));
    expect(await screen.findByRole("dialog")).toBeInTheDocument();
  });

  it("shows no rails once the queue is empty", () => {
    renderDeck([]);
    expect(
      screen.queryByRole("button", { name: new RegExp(DEFAULT_SWIPE_CONFIG.left.label, "i") }),
    ).not.toBeInTheDocument();
  });
});

// A sheet with nothing in it is a question with no answers: it costs a tap to
// open, offers no way to sort the card, and the only way out is to cancel. The
// rail says so instead of opening one.
describe("SwipeDeck rails with nothing to sort into", () => {
  const NO_EXCLUDED = CATS.filter((c) => c.Kind !== "excluded");

  /** The toast region, which is where a refusal has to say so. */
  const notifications = (): HTMLElement => screen.getByRole("region", { name: /notifications/i });

  it("does not open an empty sheet on the Transfer rail", async () => {
    renderDeck([txn({ ID: 9 })], NO_EXCLUDED);
    fireEvent.click(screen.getByRole("button", { name: new RegExp(DEFAULT_SWIPE_CONFIG.up.label, "i") }));
    await waitFor(() => expect(within(notifications()).getByText(/transfer/i)).toBeInTheDocument());
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("says which rail is empty, and where to fix it", async () => {
    renderDeck([txn({ ID: 10 })], NO_EXCLUDED);
    fireEvent.click(screen.getByRole("button", { name: new RegExp(DEFAULT_SWIPE_CONFIG.up.label, "i") }));
    await waitFor(() => expect(within(notifications()).getByText(/transfer/i)).toBeInTheDocument());
    // The rail's own label, and the one place the set can be changed.
    expect(within(notifications()).getByText(/your categories/i)).toBeInTheDocument();
  });

  it("still opens the rails that DO have categories", async () => {
    renderDeck([txn({ ID: 11 })], NO_EXCLUDED);
    fireEvent.click(screen.getByRole("button", { name: new RegExp(DEFAULT_SWIPE_CONFIG.left.label, "i") }));
    expect(await screen.findByRole("dialog")).toBeInTheDocument();
  });

  it("counts the income group, so a credit's transfer rail still opens", async () => {
    // The transfer sheet offers income categories to a credit alongside the
    // excluded ones ("Is this income?"). That group is a real answer, so a
    // credit card with income categories and no excluded ones is not empty.
    const income: Category[] = [
      ...NO_EXCLUDED,
      { ID: 5, Name: "Salary", Kind: "income", Bucket: "", IsActive: true, Color: "" },
    ];
    renderDeck([txn({ ID: 12, Direction: "credit" })], income);
    fireEvent.click(screen.getByRole("button", { name: new RegExp(DEFAULT_SWIPE_CONFIG.up.label, "i") }));
    expect(await screen.findByRole("dialog")).toBeInTheDocument();
  });
});
