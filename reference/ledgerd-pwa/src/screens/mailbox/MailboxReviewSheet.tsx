/**
 * The needs-review surface for a mailbox message (spec §2.2).
 *
 * A mailbox-lane needs-review op is empty — no amount, no body — so this sheet's
 * content comes from re-fetching the message by its provenance id
 * (`mailbox/reviewContent.ts`), which only the holder device with a live token
 * can do. That is why the sheet renders four states, not one form:
 *
 *   - **ready** (holder + live token) — the re-fetched message, normalized into a
 *     form the human verifies, plus, when Gmail's own verdict passed AND the
 *     domain it verified is not a mail provider, one action to trust that domain
 *     for automatic import from here on. A forwarder gets an explanation in the
 *     action's place; see the block that renders it.
 *   - **non_holder** — this device holds no mailbox connection, so it says where
 *     the message can be read and offers no form: nothing was fetched.
 *   - **reconnect_required** — the connection is dead; this routes to the
 *     reconnect affordance, and is deliberately NOT an error banner (D10).
 *   - **unavailable** — a transient fetch failure, offered a retry.
 *
 * # Two honesty rules this sheet keeps, from the lanes it borrows from
 *
 *  1. **The body is React text children.** The re-fetched message is
 *     attacker-influenceable (anyone who learns the burner address can mail it),
 *     so it is rendered as an escaped string — never markup, never a link — the
 *     same rule `HeldMessageSheet` states at length.
 *  2. **Nothing here claims this message is genuine.** The human is the verifier;
 *     adding it authors a `txn_ingested` with exactly the authority a hand-typed
 *     row carries (`entry_method: "mailbox"`, a label the fold ignores, D6a). The
 *     "trust" action is about FUTURE mail from a domain, and it is offered only
 *     when trusting it would actually let that mail auto-import — never as a
 *     verdict on the message on screen.
 *
 * Resolving the review item itself (taking it off the deck) is the deck's
 * existing local disposition — `ReviewSource.dismiss` over the `review_disposition`
 * table — which the caller runs on `onAdded`. This sheet authors NO
 * `txn_superseded`: automatic supersede is out of scope (spec §2.2).
 */

import { useCallback, useMemo, useState } from "react";
import { AnimatePresence, m } from "motion/react";

import { newEntityID } from "@ledger/client/net/client";

import { Button } from "../../components/ui/Button";
import { Dialog, DialogFooter } from "../../components/ui/Dialog";
import { InfoTip } from "../../components/ui/InfoTip";
import { SectionLabel } from "../../components/ui/SectionLabel";
import { ManualTxnFields, emptyDraft, todayISO } from "../../components/transactions/ManualTxnSheet";
import { FADE } from "../../lib/motion";
import type { MailboxReviewContent } from "../../v2/mailbox/reviewContent";
import { isForwarderDomain } from "../../v2/mailbox/senders";
import { MAILBOX_ENTRY_METHOD, manualTxnOps, newIngestID, type ManualDraft } from "../../v2/sources/transactions";
import type { Writer } from "../../v2/writer";

export interface MailboxReviewSheetProps {
  /** From `loadMailboxReviewContent`, or `null` while the fetch is in flight. */
  content: MailboxReviewContent | null;
  /** The currency a draft with none falls back to. */
  homeCurrency: string;
  categories: readonly string[];
  currencies: readonly string[];
  writer: Writer | null;
  onClose: () => void;
  /** Called once the transaction op is queued, so the caller can dismiss the item. */
  onAdded: () => void;
  /** Route to the reconnect affordance (the dead-token state). */
  onReconnect: () => void;
  /** Re-attempt the fetch (the transient-failure state). */
  onRetry: () => void;
  /** Trust this domain for automatic import (`POST /api/v1/mailbox/senders`). */
  onTrust: (domain: string) => void;
  /** Called once the flush lands, so the caller can settle (sync + re-read). */
  onFlushed?: () => void;
  /** The trust request is in flight. */
  trustBusy?: boolean;
  /** The domain has already been trusted in this session. */
  trusted?: boolean;
}

export function MailboxReviewSheet(props: MailboxReviewSheetProps) {
  const { content, onClose } = props;
  const stateKey = content?.state ?? "loading";
  return (
    <Dialog title="Add a transaction from this message" onClose={onClose}>
      {/*
        Each state materialises with an opacity fade rather than a cut — a small
        Apple-style "the content arrived" cue as the re-fetch resolves. Keyed on
        the state so a resolve remounts and fades in; `FADE` is a lib/motion token
        under the app's one motion root, and its opacity survives reduced-motion
        (MotionConfig reducedMotion="user"), so this file adds no per-component
        preference handling.
      */}
      <AnimatePresence mode="wait" initial={false}>
        <m.div key={stateKey} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={FADE}>
          <Body {...props} />
        </m.div>
      </AnimatePresence>
    </Dialog>
  );
}

function Body(props: MailboxReviewSheetProps) {
  const { content } = props;
  if (content === null) {
    return (
      <p role="status" className="text-sm text-muted">
        Reading this message…
      </p>
    );
  }
  switch (content.state) {
    case "non_holder":
      return <NonHolder onClose={props.onClose} />;
    case "reconnect_required":
      return <Reconnect onReconnect={props.onReconnect} onClose={props.onClose} />;
    case "unavailable":
      return <Unavailable reason={content.reason} onRetry={props.onRetry} onClose={props.onClose} />;
    case "ready":
      return <Ready {...props} content={content} />;
  }
}

function NonHolder({ onClose }: { onClose: () => void }) {
  return (
    <div className="space-y-4">
      <p data-testid="mailbox-review-nonholder" className="text-sm font-semibold leading-relaxed text-fg">
        Open this on the device connected to your mailbox.
      </p>
      <p className="text-sm leading-relaxed text-muted">
        The message stays in your mailbox and is read only on the device that holds the connection. Open ledger there to
        add this transaction.
      </p>
      <DialogFooter>
        <Button variant="primary" onClick={onClose}>
          Got it
        </Button>
      </DialogFooter>
    </div>
  );
}

function Reconnect({ onReconnect, onClose }: { onReconnect: () => void; onClose: () => void }) {
  return (
    <div className="space-y-4">
      <p data-testid="mailbox-review-reconnect" className="text-sm font-semibold leading-relaxed text-fg">
        Reconnect to read this message.
      </p>
      <p className="text-sm leading-relaxed text-muted">
        Your mailbox connection has ended, so this message can’t be read here yet. Reconnect and it will be waiting.
      </p>
      <DialogFooter>
        <Button variant="ghost" onClick={onClose}>
          Not now
        </Button>
        <Button variant="primary" data-testid="mailbox-review-reconnect-action" onClick={onReconnect}>
          Reconnect mailbox
        </Button>
      </DialogFooter>
    </div>
  );
}

function Unavailable({ reason, onRetry, onClose }: { reason: string; onRetry: () => void; onClose: () => void }) {
  return (
    <div className="space-y-4">
      <p data-testid="mailbox-review-unavailable" role="alert" className="text-sm leading-relaxed text-fg">
        {reason}
      </p>
      <DialogFooter>
        <Button variant="ghost" onClick={onClose}>
          Close
        </Button>
        <Button variant="primary" data-testid="mailbox-review-retry" onClick={onRetry}>
          Try again
        </Button>
      </DialogFooter>
    </div>
  );
}

function Ready({
  content,
  homeCurrency,
  categories,
  currencies,
  writer,
  onAdded,
  onFlushed,
  onTrust,
  trustBusy = false,
  trusted = false,
  onClose,
}: MailboxReviewSheetProps & { content: Extract<MailboxReviewContent, { state: "ready" }> }) {
  const { prefill, trustDomain } = content;

  const initial = useMemo<ManualDraft>(() => {
    const filled = prefill.draft;
    if (filled === null) return emptyDraft(homeCurrency);
    return {
      ...filled,
      currency: filled.currency === "" ? homeCurrency : filled.currency,
      date: filled.date === "" ? todayISO() : filled.date,
    };
  }, [prefill, homeCurrency]);

  const [draft, setDraft] = useState<ManualDraft>(initial);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const add = useCallback((): void => {
    if (writer === null) return;
    setBusy(true);
    setError("");
    try {
      const built = manualTxnOps({
        draft,
        // Random, never a hash of the message: a repeat surfaces through replay's
        // fingerprint index as a duplicate notice, not a dropped op.
        ingestID: newIngestID(),
        newID: newEntityID,
        entryMethod: MAILBOX_ENTRY_METHOD,
      });
      if (!built.ok) {
        setError(built.reason);
        return;
      }
      writer.enqueueMany(built.specs);
      writer.flush().then(
        () => onFlushed?.(),
        () => undefined,
      );
      onAdded();
    } finally {
      setBusy(false);
    }
  }, [writer, draft, onAdded, onFlushed]);

  return (
    <div className="space-y-4">
      <p className="text-sm leading-relaxed text-muted">
        This came from the mailbox you connected. Read it below and enter what it says — adding it puts a row in your own
        ledger and moves no money.{" "}
        <InfoTip about="what adding this does" testId="mailbox-review-tip">
          You are the one reading the message and confirming the details. The row you add can be edited later.
        </InfoTip>
      </p>

      <p data-testid="mailbox-review-reason" className="text-sm leading-relaxed text-fg">
        {prefill.reason}
      </p>

      <ManualTxnFields idPrefix="mailbox-review" draft={draft} onChange={setDraft} categories={categories} currencies={currencies} />

      <div>
        <SectionLabel>The message</SectionLabel>
        {prefill.subject !== "" && (
          <p data-testid="mailbox-review-subject" className="mt-1 text-sm text-muted break-words">
            Subject: {prefill.subject}
          </p>
        )}
        {/* Text children only — never markup. See this file's header. */}
        <p
          data-testid="mailbox-review-body"
          className="mt-2 max-h-64 overflow-y-auto whitespace-pre-wrap break-words rounded-[var(--radius)] border border-border bg-surface-2 p-3 text-xs leading-relaxed text-muted"
        >
          {prefill.body === "" ? "This message has no readable text." : prefill.body}
        </p>
      </div>

      {/*
        A forwarder is NEVER offered. `reviewContent` hands us the domain Gmail's
        Authentication-Results verified, and for a message someone forwarded by
        hand that domain is the forwarder itself — so the action would read
        "Trust gmail.com for automatic import" and, if the server honoured it,
        auto-file every Gmail-signed message in the mailbox as a permanent op.
        The server refuses it (409 forwarder_domain); this is the product not
        offering a dead button, and saying why instead of going quiet.
      */}
      {trustDomain !== null && isForwarderDomain(trustDomain) && (
        <div className="rounded-[var(--radius)] border border-border p-3">
          <p data-testid="mailbox-review-forwarder" className="text-sm leading-relaxed text-fg">
            This message was signed by <span className="font-mono">{trustDomain}</span>, not by a bank.
          </p>
          <p className="mt-2 text-xs leading-relaxed text-muted">
            That happens when a message is forwarded by hand: the bank’s own signature does not survive it, and what
            arrives is signed by the mail provider. Trusting{" "}
            <span className="font-mono">{trustDomain}</span> would mean trusting everything that passes through your
            mailbox, so ledger doesn’t offer it. Add the transaction above, and set up an automatic rule at your bank or
            in your mail so future messages arrive with the bank’s signature intact.
          </p>
        </div>
      )}

      {/*
        The auto-import action. Offered only when trusting the domain would
        actually let its future mail import (a passing Gmail verdict), and worded
        about future messages — never as a claim about the one on screen.
      */}
      {trustDomain !== null && !isForwarderDomain(trustDomain) && (
        <div className="rounded-[var(--radius)] border border-border p-3">
          {trusted ? (
            <p data-testid="mailbox-review-trusted" className="text-sm leading-relaxed text-fg">
              Future messages from <span className="font-mono">{trustDomain}</span> will be added automatically.
            </p>
          ) : (
            <>
              <Button
                variant="secondary"
                data-testid="mailbox-review-trust"
                disabled={trustBusy}
                onClick={() => onTrust(trustDomain)}
              >
                Trust {trustDomain} for automatic import
              </Button>
              <p className="mt-2 text-xs leading-relaxed text-muted">
                Future messages from <span className="font-mono">{trustDomain}</span> would be added to your ledger
                without landing here first. Only for a sender you recognise as your own bank.
              </p>
            </>
          )}
        </div>
      )}

      {error !== "" && (
        <p role="alert" data-testid="mailbox-review-error" className="text-sm text-bad">
          {error}
        </p>
      )}

      <DialogFooter>
        <Button variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button variant="primary" data-testid="mailbox-review-add" disabled={busy || writer === null} onClick={add}>
          Add transaction
        </Button>
      </DialogFooter>
    </div>
  );
}
