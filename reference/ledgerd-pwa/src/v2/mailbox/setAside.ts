/**
 * Set-aside mail, grouped for the user to act on — the "ask the user which bank"
 * half of the Gmail lane's filtering.
 *
 * # Setting mail aside is only honest if it is VISIBLE
 *
 * The fetch lane authors an op only for mail plausibly from a bank
 * (`bankDomains.ts`); everything else is recorded in the device-local state row
 * and imported nothing. That is not a silent drop — the three things that make it
 * one are all refused here:
 *
 *   - it is **counted and shown**, grouped by sender domain, with what fell past
 *     the ring's cap said out loud;
 *   - it is **reversible**: D5 makes the burner mailbox the durable archive, so
 *     "This is my bank" trusts the domain and re-fetches those exact messages by
 *     id (`fetch.ts`'s `importSetAsideDomain`);
 *   - the **copy says what happened** — not imported, still in the mailbox,
 *     nothing lost.
 *
 * This module is pure derivation plus one store read, so the settings drill-in
 * and the onboarding catch-up summary render the same facts from the same place.
 * `readMailboxSetAside` and {@link setAsideGroups} are the seam for both.
 */

import { browserMailboxTokenStore, type KeyStore } from "../mailboxToken";
import { isForwarderDomain } from "./senders";
import { emptySetAsideLog, readMailboxState, type SetAsideLog } from "./state";

/** One sender domain's set-aside mail, as the surface renders it. */
export interface SetAsideGroup {
  /** The sender domain, or `""` when the message proved no domain at all. */
  domain: string;
  /** How many of this domain's messages are in the log. */
  count: number;
  /** The newest arrival time in the group, ISO-8601 (`""` if none was recorded). */
  latestAt: string;
  /** A few subjects, newest first, so the user can recognise the sender. */
  subjects: string[];
  /**
   * Whether "This is my bank" can be offered. False for the domain-less group:
   * there is nothing to trust, and a trust action that cannot work must not be
   * shown.
   *
   * False for a FORWARDER too. `trustSender` refuses one before it reaches the
   * network and the server answers 409 `forwarder_domain`, so offering the
   * button here would only ever produce `trustFailed` — and if it somehow did
   * succeed it would auto-file everything relayed through the mailbox, as
   * permanent ops. A group like this is real mail worth showing; it is only the
   * ACTION that cannot work.
   */
  canTrust: boolean;
}

/** How many subjects a group carries into the UI. */
const SUBJECTS_PER_GROUP = 3;

/**
 * Groups a set-aside log by sender domain, busiest first (ties broken by domain
 * so the order is stable across renders). Pure.
 */
export function setAsideGroups(log: SetAsideLog): SetAsideGroup[] {
  const byDomain = new Map<string, SetAsideGroup>();
  // Newest last in the ring, so walk it backwards to collect newest-first subjects.
  for (let i = log.recent.length - 1; i >= 0; i -= 1) {
    const rec = log.recent[i]!;
    const existing = byDomain.get(rec.domain);
    if (existing === undefined) {
      byDomain.set(rec.domain, {
        domain: rec.domain,
        count: 1,
        latestAt: rec.receivedAt,
        subjects: rec.subject === "" ? [] : [rec.subject],
        canTrust: rec.domain !== "" && !isForwarderDomain(rec.domain),
      });
      continue;
    }
    existing.count += 1;
    if (rec.receivedAt > existing.latestAt) existing.latestAt = rec.receivedAt;
    if (rec.subject !== "" && existing.subjects.length < SUBJECTS_PER_GROUP) existing.subjects.push(rec.subject);
  }
  return [...byDomain.values()].sort((a, b) => b.count - a.count || a.domain.localeCompare(b.domain));
}

/**
 * The message ids set aside for a domain (and its subdomains) — exactly the
 * messages "This is my bank" re-fetches. Same subdomain reach as the trust itself,
 * so nothing the user just trusted is left behind in the log.
 */
export function setAsideIdsForDomain(log: SetAsideLog, domain: string): string[] {
  return log.recent
    .filter((r) => r.domain === domain || r.domain.endsWith(`.${domain}`))
    .map((r) => r.message_id);
}

/**
 * The device's persisted set-aside log. Never throws — a device that never
 * connected, or one whose row predates this field, reads an empty log.
 *
 * This is the seam the onboarding catch-up summary should call; it needs no
 * handle, no keys and no network.
 */
export async function readMailboxSetAside(store: KeyStore = browserMailboxTokenStore()): Promise<SetAsideLog> {
  return (await readMailboxState(store)).setAside ?? emptySetAsideLog();
}

/**
 * The copy for the set-aside surface.
 *
 * Honest by construction: it says these messages were not imported, that they are
 * still in the mailbox, and that ledger will import a sender's mail once the user
 * says it is a bank. It never says anything was deleted, discarded or filtered
 * away, because none of that happened — and it makes no claim that a set-aside
 * message is *not* a transaction, only that ledger did not recognise the sender.
 */
export const SET_ASIDE_COPY = {
  title: "Mail ledger did not import",
  body:
    "These did not come from a bank ledger recognises, so nothing was written to your ledger for them. " +
    "They are still in your mailbox, exactly as they arrived.",
  trustHint: "If one of these is your bank, tell ledger and it will read those messages now, and future ones as they arrive.",
  /** The per-domain action. `domain` is shown so the user knows what they trust. */
  trustAction: "This is my bank — import from here",
  trustWorking: "Importing…",
  trustFailed: "ledger could not import from that sender just now. Nothing changed; you can try again.",
  /** How many older entries are past the ring's cap. Said out loud, never hidden. */
  dropped: (n: number): string =>
    `${n} older ${n === 1 ? "message is" : "messages are"} not listed here. They are still in your mailbox.`,
  unknownDomain: "Sender ledger could not identify",
  imported: (n: number): string => `${n} ${n === 1 ? "message" : "messages"} imported. Check your review deck.`,
} as const;
