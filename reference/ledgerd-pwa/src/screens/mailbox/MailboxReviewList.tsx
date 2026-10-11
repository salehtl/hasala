/**
 * The live wiring for the mailbox needs-review surface (Task 13's
 * {@link MailboxReviewSheet}, Task 15 carry-forward c).
 *
 * A mailbox-lane needs-review op is authored EMPTY and lands in the projection's
 * `unparsed` lane carrying only its `mailbox_message_id` (Task Pj). The confirm
 * deck cannot answer an empty row, so those rows were only ever counted, never
 * openable. This surfaces them: each unparsed row with a `mailbox_message_id`
 * becomes a tappable item that opens the sheet, which re-fetches the message by
 * that id (`loadMailboxReviewContent`) on the holder device and lets the human
 * enter what it says.
 *
 * It also closes carry-forward b: the sheet's "Trust <domain> for automatic
 * import" is wired to {@link trustSender} (`POST /api/v1/mailbox/senders`).
 *
 * # No fetch until a row is tapped
 *
 * `Review.test.tsx` asserts the review screen makes no HTTP call on render. This
 * component honours that: the vault read on mount is IndexedDB, not fetch, and
 * `loadMailboxReviewContent` runs only inside the effect that fires when a row is
 * opened. Nothing here fetches while the list is merely displayed.
 */

import { useCallback, useEffect, useMemo, useState } from "react";

import { SectionLabel } from "../../components/ui/SectionLabel";
import { Pressable } from "../../components/ui/Pressable";
import { ChevronRight } from "../../components/ui/PixelIcon";
import { browserKeyVault, type KeyVault } from "../../v2/keys";
import { mintAccessToken } from "../../v2/mailboxConnect";
import {
  browserMailboxTokenStore,
  openMailboxToken,
  type KeyStore,
} from "../../v2/mailboxToken";
import { readTemplateDefinitions } from "../../v2/onboardingIO";
import { loadMailboxReviewContent, type MailboxReviewContent } from "../../v2/mailbox/reviewContent";
import { trustSender } from "../../v2/mailbox/senders";
import type { ReviewItem } from "../../v2/sources/review";
import type { V2Handle } from "../../v2/session";
import type { Writer } from "../../v2/writer";
import { MailboxReviewSheet } from "./MailboxReviewSheet";

export interface MailboxReviewListProps {
  /** The unparsed rows with a `mailbox_message_id`, from the review feed. */
  items: readonly ReviewItem[];
  handle: V2Handle;
  writer: Writer | null;
  homeCurrency: string;
  categories: readonly string[];
  currencies: readonly string[];
  /** Removes the item from the deck once a transaction is added (`review_disposition`). */
  onDismiss: (item: ReviewItem) => void;
  /** Settle (sync + re-read) after an add flushes. */
  onSettled?: () => void;
  /** Route to the "Transaction mailbox" reconnect affordance (the dead-token state). */
  onReconnect: () => void;
  /** Test seams. */
  vault?: KeyVault;
  store?: KeyStore;
}

export function MailboxReviewList({
  items,
  handle,
  writer,
  homeCurrency,
  categories,
  currencies,
  onDismiss,
  onSettled,
  onReconnect,
  vault,
  store,
}: MailboxReviewListProps) {
  const activeVault = useMemo(() => vault ?? browserKeyVault(), [vault]);
  const tokenStore = useMemo(() => store ?? browserMailboxTokenStore(), [store]);
  const [creds, setCreds] = useState<{ dek: CryptoKey; accountId: string } | null>(null);

  useEffect(() => {
    let live = true;
    void activeVault.read().then(
      (k) => {
        if (live && k !== null) setCreds({ dek: k.dek, accountId: k.accountId });
      },
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [activeVault]);

  const [open, setOpen] = useState<ReviewItem | null>(null);
  const [content, setContent] = useState<MailboxReviewContent | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [trustBusy, setTrustBusy] = useState(false);
  const [trustedDomains, setTrustedDomains] = useState<ReadonlySet<string>>(new Set());

  // Loads the sheet content for the open item. Runs ONLY when a row is opened,
  // never on render — the no-fetch-on-render guarantee.
  useEffect(() => {
    if (open === null) return;
    let live = true;
    setContent(null);
    const messageId = open.txn.mailbox_message_id ?? "";
    void loadMailboxReviewContent({
      provenance: { message_id: messageId },
      receivedAt: open.txn.posted_at,
      hasSealedToken: async () => {
        if (creds === null) return false;
        try {
          return (await openMailboxToken(creds.dek, creds.accountId, tokenStore)) !== null;
        } catch {
          return false;
        }
      },
      mintAccessToken: () => {
        if (creds === null) throw new Error("no account keys on this device");
        return mintAccessToken(handle, creds.dek, creds.accountId, { store: tokenStore });
      },
      loadTemplates: () => readTemplateDefinitions(handle.client),
    }).then(
      (c) => {
        if (live) setContent(c);
      },
      () => {
        if (live) setContent({ state: "unavailable", reason: "Couldn't fetch this message right now. Try again in a moment." });
      },
    );
    return () => {
      live = false;
    };
  }, [open, attempt, creds, handle, tokenStore]);

  const onTrust = useCallback(
    (domain: string): void => {
      setTrustBusy(true);
      void trustSender(handle, domain).then(
        () => {
          setTrustedDomains((s) => new Set(s).add(domain));
          setTrustBusy(false);
        },
        () => setTrustBusy(false),
      );
    },
    [handle],
  );

  const onAdded = useCallback((): void => {
    if (open !== null) onDismiss(open);
    setOpen(null);
    setContent(null);
  }, [open, onDismiss]);

  if (items.length === 0) return null;

  const trustDomain = content?.state === "ready" ? content.trustDomain : null;

  return (
    <div data-testid="mailbox-review-list" className="mt-4 space-y-2">
      <SectionLabel>Messages to review</SectionLabel>
      <div className="rounded-[var(--radius)] border border-border divide-y divide-border overflow-hidden">
        {items.map((item) => (
          <Pressable
            key={item.txn.id}
            data-testid={`mailbox-review-item-${item.txn.id}`}
            onClick={() => {
              setContent(null);
              setOpen(item);
            }}
            className="w-full min-h-11 px-4 py-3 flex items-center justify-between gap-3 text-left text-sm hover:bg-surface-2/50"
          >
            <span className="text-fg">A message from your mailbox to check</span>
            <ChevronRight size={16} aria-hidden className="shrink-0 text-muted" />
          </Pressable>
        ))}
      </div>

      {open !== null && (
        <MailboxReviewSheet
          content={content}
          homeCurrency={homeCurrency}
          categories={categories}
          currencies={currencies}
          writer={writer}
          onClose={() => {
            setOpen(null);
            setContent(null);
          }}
          onAdded={onAdded}
          onReconnect={onReconnect}
          onRetry={() => setAttempt((n) => n + 1)}
          onTrust={onTrust}
          onFlushed={onSettled}
          trustBusy={trustBusy}
          trusted={trustDomain !== null && trustedDomains.has(trustDomain)}
        />
      )}
    </div>
  );
}
