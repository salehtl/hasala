/**
 * The review queue, on the local projection.
 *
 * # What changed, and what deliberately did not
 *
 * The deck is the same deck. The gesture, the four rails, the fly-out, the ghost
 * card, the category sheet and the undo toast are untouched — the design is
 * frozen, and this screen changes exactly two things: where the cards come from
 * and what answering one does.
 *
 *  - **The feed** is `v2/sources/review.ts`'s `DECK_LANES` — the flagged rows
 *    and the ones with no category — over SQLite, not
 *    `GET /api/transactions?status=needs_review`. There is no `fetch` on this
 *    screen at all, and its test asserts that.
 *  - **The commit** appends a `txn_categorized` op (plus, first time for a
 *    merchant, a `rule_added`) through the outbox. `Client.emit` commits before
 *    it returns, so the card leaves the deck the moment the user answers rather
 *    than when the network agrees — a queue used on a plane has to work.
 *
 * # The queue IS period-scoped now, and the word doing the work is "silently"
 *
 * v1 filtered this by the shell's scope selector and lost transactions: a row
 * that needed a look last month vanished when the month rolled over — silently,
 * into a list nobody was going to open. The scope is app-wide now (the owner's
 * call: every surface but Settings honours it), so the deck is bounded again —
 * but nothing may disappear without being counted:
 *
 *   - **What the period excludes is stated on the glass**, by number, with one
 *     tap to every period ("Show all periods"). `ReviewFeed.outside` is that
 *     number, and it is computed from the lane counts rather than from the page,
 *     so it is right even when the excluded work is deeper than one page.
 *   - **The empty state cannot say "all caught up" over hidden work.** With
 *     items outside the period it names the period and says how many are
 *     elsewhere; only a genuinely empty queue gets the finished sentence.
 *   - **The nav badge stays whole-log** (`ReviewFeed.counts`, deliberately
 *     unwindowed). "Needs a decision" is a state, not a date, and a badge that
 *     emptied when you stepped back a month would be the app forgetting work on
 *     the user's behalf.
 *
 * This is still, on the evidence in this file's own history, a design worth
 * reconsidering: a queue is not a view of a period. The disclosure above is what
 * makes it defensible, not what makes it obviously right.
 *
 * # Why a confirmed card does not come back on the next refetch
 *
 * The projection only moves when a sync folds new ops, so for the whole of an
 * offline session every row the user has confirmed is still `needs_review = 1`
 * in SQLite. `settledBy`/`isSettled` read the outbox — the durable record of
 * what the user has already answered — and take those rows off the deck. A `Set`
 * in component state would do the same until the tab was killed, and would then
 * hand the user thirty cards they had already sorted.
 */

import { useCallback, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { newEntityID } from "@ledger/client/net/client";

import { AlertTriangle, CheckCircle2, Inbox } from "../components/ui/PixelIcon";
import { PixelSpinner } from "../components/ui/PixelSpinner";
import { Pressable } from "../components/ui/Pressable";
import { EmptyState } from "../components/EmptyState";
import { SwipeDeck } from "../components/swipe/SwipeDeck";
import { useToast } from "../components/Toast";
import type { Category, Txn as ApiTxn } from "../api/types";
import { loadSwipeConfig } from "../lib/swipe";
import { formatMinor } from "../lib/minorMoney";
import { cardIdSource, deckCategories, deckRows, type DeckRow } from "../v2/reviewDeck";
import { useHomeCurrency, useReviewFeed, useReviewSource, useTxnFacets, useTxnSource, v2Keys } from "../v2/queries";
import { useSettleAuthored } from "../v2/settle";
import {
  categorizeOps,
  DECK_LANES,
  isSettled,
  itemKey,
  settledBy,
  undoConfirmOps,
  type ReviewItem,
  type ReviewSource,
} from "../v2/sources/review";
import { useWriter, type Writer } from "../v2/writer";
import { useV2 } from "../v2/BootGate";
import { MailboxReviewList } from "./mailbox/MailboxReviewList";
import { scopeBounds, scopeLabel, type Scope } from "../lib/scope";

/** The unparsed lane, read on its own so the mailbox list can open its rows. */
const UNPARSED_LANE = ["unparsed"] as const;

export interface ReviewProps {
  /**
   * The app-wide period. Defaults to the whole log — which is what a caller with
   * no shell around it means, and the one value that withholds nothing.
   */
  scope?: Scope;
  /**
   * Applies a new period. The one thing this screen ever asks for is all of
   * them; absent, the "outside this period" line keeps its sentence and loses
   * its button rather than offering an action nothing honours.
   */
  onScopeChange?: (s: Scope) => void;
  /** Opens the held-mail lane. Absent hides the entry point. */
  onOpenQuarantine?: () => void;
  /** Opens the "Transaction mailbox" settings drill-in (the reconnect affordance). */
  onOpenMailboxSettings?: () => void;
  /** Test seam: a source over a projection the test built. */
  source?: ReviewSource;
  /** Test seam: a writer that records what the screen would append. */
  writer?: Writer;
}

const ALL_TIME: Scope = { kind: "all" };

export function Review({
  scope = ALL_TIME,
  onScopeChange,
  onOpenQuarantine,
  onOpenMailboxSettings,
  source: injectedSource,
  writer: injectedWriter,
}: ReviewProps) {
  const [config] = useState(loadSwipeConfig);
  const source = useReviewSource(injectedSource);
  const writer = useWriter(injectedWriter);
  const qc = useQueryClient();
  const settle = useSettleAuthored();
  const toast = useToast();
  const homeCurrency = useHomeCurrency(useTxnSource());

  /**
   * Both lanes the deck can answer, dealt flagged-first.
   *
   * `uncategorized` is here because the deck already answers exactly its
   * question. A template-tier parse with every capture group filled is never
   * `needs_review`, so a real transaction with no category used to belong to no
   * lane at all — the queue said "All caught up" over a row nothing had filed,
   * and there was no way to categorise it from this screen. The card, the
   * gesture and the commit are unchanged; only the feed grew.
   */
  const bounds = scopeBounds(scope);
  const feed = useReviewFeed(source, DECK_LANES, bounds);

  /**
   * Every row the lane page returned, adapted, in the page's own order.
   *
   * The settled filter is applied AFTER this and never to it.
   */
  const page = useMemo(() => feed.data?.items ?? [], [feed.data]);

  /**
   * Card ids, stable per transaction for as long as this screen is mounted.
   *
   * Not positions. A position renumbers whenever the feed changes — when the
   * settled filter drops a confirmed row, and, unavoidably, when a sync folds
   * that row out of the lane while the undo toast is still up. Both make
   * `byCard.get(card.ID)` resolve a *different* transaction, and `undo` would
   * then author a compensating op against a row the user never touched.
   */
  const idFor = useRef(cardIdSource()).current;
  const allRows = useMemo(() => deckRows(page, homeCurrency, idFor), [page, homeCurrency, idFor]);

  /**
   * Every card this screen has ever handed the deck, by id — **cumulative**.
   *
   * A `Map` rebuilt from the current page would forget a row the moment a sync
   * folded it out, and forgetting is not a safe default here: `undo` early-returns
   * on a miss (there is nothing sensible to do with an id it cannot resolve), so
   * the user's undo would quietly do nothing at the exact moment the sync they
   * were waiting for arrived. The deck outlives the feed, so the lookup has to
   * as well.
   *
   * It grows with the number of distinct cards seen in one sitting, which is
   * bounded by the queue the user is working through, and is dropped when the
   * screen unmounts.
   */
  const cards = useRef(new Map<number, DeckRow>()).current;
  const byCard = useMemo(() => {
    for (const r of allRows) cards.set(r.card.ID, r);
    return cards;
  }, [allRows, cards]);

  /**
   * What the deck is handed: the page minus what the outbox has already
   * answered.
   *
   * `writer.pending` is read rather than `writer`, because `Client.emitMany`
   * REPLACES the array (`this.st.pending = [...previous, ...ops]`) while the
   * outbox object itself is memoised for the tab's lifetime — a memo keyed on
   * the writer would never recompute, and the filter would only ever be correct
   * by accident of react-query's structural sharing.
   */
  const rows = useMemo(() => {
    const settlement = settledBy(writer?.pending ?? []);
    return allRows.filter((r) => !isSettled(r.item.txn, settlement));
  }, [allRows, writer?.pending]);
  const categories = useMemo(
    () => deckCategories(feed.data?.categories ?? [], feed.data?.categoryDefs ?? []),
    [feed.data],
  );

  /**
   * The mailbox needs-review rows: unparsed ops carrying a `mailbox_message_id`
   * (Task Pj). They cannot go on the confirm deck — they are empty by design — so
   * they get their own list, which opens the re-fetch sheet (carry-forward c).
   * The `unparsed` lane read is over the same projection, no HTTP.
   */
  const unparsedFeed = useReviewFeed(source, UNPARSED_LANE, bounds);
  const v2 = useV2();
  const facets = useTxnFacets(useTxnSource());
  const mailboxItems = useMemo<ReviewItem[]>(
    () => (unparsedFeed.data?.items ?? []).filter((i) => (i.txn.mailbox_message_id ?? null) !== null),
    [unparsedFeed.data],
  );
  const categoryNames = useMemo(() => categories.map((c) => c.Name), [categories]);
  const currencyChoices = useMemo(
    () => [...new Set([homeCurrency ?? "", ...(facets.data?.currencies ?? [])].filter((c) => c !== ""))],
    [homeCurrency, facets.data],
  );

  const dismissMailbox = useCallback(
    (item: ReviewItem): void => {
      if (source === null) return;
      void source.dismiss(itemKey(item.txn), "unparsed", "acknowledged").then(async () => {
        await qc.invalidateQueries({ queryKey: v2Keys.all });
      });
    },
    [source, qc],
  );

  /**
   * Appends one answer.
   *
   * The parent version comes from a FRESH read of the projection plus whatever
   * this device has already queued for that row — never from the card, which can
   * be minutes old. An op naming a stale parent is a fork against yourself, and
   * inside one millisecond the later op is the one discarded.
   */
  const commit = useCallback(
    async (card: ApiTxn, category: Category, makeRule: boolean): Promise<void> => {
      const row = byCard.get(card.ID);
      if (row === undefined) throw new Error("the deck committed a card this screen does not hold");
      if (source === null || writer === null) throw new Error("no local ledger is open");
      const head = await source.version(row.item.txn.id);
      const specs = categorizeOps({
        txn: row.item.txn,
        category: category.Name,
        // The sheet's "remember this merchant" switch. Dropping the spec rather
        // than not asking for it keeps the rule's shape in one place — see
        // `categorizeOps`, which the transaction list's sheet also authors
        // through.
        makeRule,
        // A row the projection no longer knows about cannot be confirmed at a
        // guessed version; its own version is the only defensible fallback.
        projectedVersion: head ?? row.item.txn.version,
        pending: writer.pending,
        rules: feed.data?.rules ?? [],
        newID: newEntityID,
      });
      writer.enqueueMany(specs);
      await qc.invalidateQueries({ queryKey: v2Keys.all });
      // Not awaited: the ops are already durable, and a deck that stalled on the
      // network would be unusable exactly where this queue is used. Once the
      // upload lands, the settle folds it and every screen re-reads.
      writer.flush().then(
        () => void settle(),
        () => {
          toast.show({ message: "Saved on this device — it will sync when you're back online" });
        },
      );
    },
    [byCard, source, writer, feed.data, qc, toast, settle],
  );

  const undo = useCallback(
    async (card: ApiTxn): Promise<void> => {
      const row = byCard.get(card.ID);
      if (row === undefined || source === null || writer === null) return;
      const head = await source.version(row.item.txn.id);
      // The log is append-only, so this is a compensating op rather than a
      // deletion: the row goes back to the category it had and back to
      // `needs_review`, and both ops stay in the log forever.
      writer.enqueueMany(
        undoConfirmOps({
          txn: row.item.txn,
          projectedVersion: head ?? row.item.txn.version,
          pending: writer.pending,
        }),
      );
      await qc.invalidateQueries({ queryKey: v2Keys.all });
      writer.flush().then(
        () => void settle(),
        () => undefined,
      );
    },
    [byCard, source, writer, qc, settle],
  );

  const counts = feed.data?.counts;
  const money = feed.data?.money;
  /**
   * How much work this period is holding back.
   *
   * From the lane COUNTS, not from the dealt page: the page is a 20-row window
   * over the lane, so a page-derived number would report zero whenever the
   * excluded work happened to sit deeper than the window — which is exactly the
   * case where the user most needs to be told.
   */
  const outside = feed.data?.outside ?? 0;
  const showAll = onScopeChange === undefined ? null : (
    <Pressable
      onClick={() => onScopeChange(ALL_TIME)}
      className="min-h-11 px-3 text-sm font-medium text-fg underline underline-offset-2"
    >
      Show all periods
    </Pressable>
  );

  // No v2 runtime and nothing injected. NOT a v1 fallback — see `Home.tsx`'s
  // header for why there is no correct one.
  if (source === null || writer === null) {
    return (
      <EmptyState
        icon={AlertTriangle}
        title="Your local ledger isn't open"
        hint="This screen reads the copy of your ledger on this device. Reopen the app to reconnect."
      />
    );
  }

  return (
    // flex-1, not a min-h floor: AppShell's content wrapper is a full-height
    // flex column, so the deck takes exactly the space that's there.
    <div className="flex flex-1 flex-col min-h-0">
      {feed.isPending && (
        <div className="flex-1 flex items-center justify-center py-16">
          <PixelSpinner size={36} role="status" aria-label="Loading transactions" className="text-muted" />
        </div>
      )}

      {/* A failed read is not an empty queue. Without this, a broken projection
          rendered "All caught up" — telling you your queue was clear when it had
          simply failed to load. */}
      {feed.isError && (
        <div className="flex-1 flex items-center justify-center">
          <EmptyState
            icon={AlertTriangle}
            title="Couldn't read your review queue"
            hint="The copy of your ledger on this device could not be read. Reopen the app to try again."
          />
        </div>
      )}

      {!feed.isPending && !feed.isError && rows.length === 0 && outside === 0 && (
        <div className="flex-1 flex flex-col items-center justify-center gap-3 px-8 py-16 text-center">
          <CheckCircle2 size={48} className="text-fg" />
          {/* The same words the deck uses when you finish sorting — one state,
              one name, whether you cleared it just now or arrived to nothing. */}
          <h2 className="text-xl font-semibold text-fg">All caught up</h2>
          <p className="text-muted">Nothing is waiting for a decision.</p>
        </div>
      )}

      {/*
        An empty period over a queue that is NOT empty.

        "All caught up" here would be the app telling the user their queue is
        clear while holding work it has decided not to show them — the exact
        sentence this file's header exists to forbid. So the period is named, the
        remainder is counted, and the way out is on the screen.
      */}
      {!feed.isPending && !feed.isError && rows.length === 0 && outside > 0 && (
        <div className="flex-1 flex flex-col items-center justify-center gap-3 px-8 py-16 text-center">
          <Inbox size={48} className="text-muted" />
          <h2 className="text-xl font-semibold text-fg">Nothing waiting in {scopeLabel(scope)}</h2>
          <p className="text-muted">
            {outside} {outside === 1 ? "item needs" : "need"} a decision in another period.
          </p>
          {showAll}
        </div>
      )}

      {/*
        Work the period is holding back, above the deck rather than under it: a
        line below the cards sits behind the fly-out and under the bottom nav on
        a short phone, which is where a disclosure goes to be missed.
      */}
      {!feed.isPending && !feed.isError && rows.length > 0 && outside > 0 && (
        <div className="mb-3 flex items-center justify-between gap-2 border border-border rounded-[var(--radius)] px-3 py-1.5">
          <p className="text-xs text-muted">
            {outside} more {outside === 1 ? "needs" : "need"} a decision outside {scopeLabel(scope)}
          </p>
          {showAll}
        </div>
      )}

      {!feed.isPending && !feed.isError && rows.length > 0 && (
        <SwipeDeck
          // NO `key`. `SwipeDeck` freezes its list at mount by design — a
          // refetch must not shift the index under the user's thumb — and the
          // key is the only thing that can force it to re-freeze. Every
          // content-derived key tried here was wrong in the same way: it moved
          // when the outbox grew, or when a sync folded the confirmed row out
          // of the lane, and a remount resets the index AND drops the deck's
          // `commitRef`, which is the undo the toast is at that moment
          // offering. So the deck mounts once per visit to this screen, which
          // is what freezing at mount already meant. Work that arrives mid-
          // session is on the next visit; the counts below say it is there.
          transactions={rows.map((r) => r.card)}
          categories={categories}
          config={config}
          onCommit={commit}
          onUndo={undo}
          amountOf={(t) => byCard.get(t.ID)?.amount ?? { text: "—", label: "" }}
          reasonOf={(t) => byCard.get(t.ID)?.reason ?? ""}
        />
      )}

      {/*
        Mailbox needs-review rows, openable at last: the confirm deck cannot ask
        an empty row's question, so these get their own list that opens the
        re-fetch sheet (carry-forward c). Only when a runtime is present — the
        sheet re-fetches on the holder device, which needs the real handle.
      */}
      {v2 !== null && (
        <MailboxReviewList
          items={mailboxItems}
          handle={v2.handle}
          writer={writer}
          homeCurrency={homeCurrency ?? ""}
          categories={categoryNames}
          currencies={currencyChoices}
          onDismiss={dismissMailbox}
          onSettled={() => void settle()}
          onReconnect={() => onOpenMailboxSettings?.()}
        />
      )}

      {/*
        The lanes this deck cannot answer, stated rather than hidden.

        An unparsed message needs typing in and a duplicate notice needs a
        yes/no — two questions the confirm deck cannot ask, and whose ops
        (`txn_superseded`, `txn_duplicate_disposition`) this task does not wire.
        §2 forbids anything sitting silently unhandled, so the count is on the
        glass even though the control for it is not built yet.
      */}
      {counts !== undefined && (() => {
        // The mailbox unparsed rows are openable above now, so this line counts
        // only the REST — a genuinely unreadable row with no message to re-fetch.
        const otherUnparsed = Math.max(0, counts.unparsed - mailboxItems.length);
        return (otherUnparsed > 0 || counts.duplicate > 0 || counts.forks > 0) && (
        <p className="mt-3 px-1 text-center text-xs text-muted">
          {[
            otherUnparsed > 0 ? `${otherUnparsed} couldn't be read` : null,
            counts.duplicate > 0 ? `${counts.duplicate} possible duplicate${counts.duplicate === 1 ? "" : "s"}` : null,
            counts.forks > 0 ? `${counts.forks} resolved edit${counts.forks === 1 ? "" : "s"}` : null,
          ]
            .filter((s): s is string => s !== null)
            .join(" · ")}
          {/* "visible in", not "reachable from": those rows can be FILTERED to
              in Transactions, but there is no control anywhere that answers
              them yet, and naming an action the code does not honour is the
              thing this line exists to avoid. */}
          {" — still waiting, visible in Transactions."}
        </p>
        );
      })()}

      {/* The money in the lane, and how much of it has no rate yet. A total
          printed without the second number is a total that is quietly short. */}
      {money !== undefined && money.counted > 0 && (
        <p className="mt-1 px-1 text-center text-xs text-muted tnum">
          {formatMinor(money.totalHomeMinor)} waiting
          {money.awaitingRate > 0 && `, plus ${money.awaitingRate} with no rate yet`}
        </p>
      )}

      {onOpenQuarantine !== undefined && (
        <Pressable
          onClick={onOpenQuarantine}
          className="mt-3 mx-auto flex min-h-11 items-center gap-2 px-3 text-sm font-medium text-fg underline underline-offset-2"
        >
          <Inbox size={16} aria-hidden />
          Held mail
        </Pressable>
      )}
    </div>
  );
}
