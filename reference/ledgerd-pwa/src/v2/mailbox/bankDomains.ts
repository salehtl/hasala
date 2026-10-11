/**
 * The bank-domain set: which senders this lane treats as "plausibly a bank", and
 * the Gmail query that narrows a BACKFILL to them.
 *
 * # Why a set at all — the asymmetry between an op and a set-aside
 *
 * The fetch lane used to author a `txn_ingested` op for EVERY message in the
 * burner mailbox. A newsletter, a password reset or Google's own security notice
 * therefore became an empty needs-review card — and the op log is append-only, so
 * that card is permanent on every device, forever. There is no undo.
 *
 * Setting a message aside has no such cost: D5 makes the burner mailbox itself
 * the durable archive, so a set-aside message is still in Gmail and can be
 * re-fetched by id the moment the user says "this is my bank". That asymmetry —
 * an op is irreversible, a set-aside is one tap from being imported — is the
 * whole argument for filtering before authoring rather than after.
 *
 * # The set is the union of two lists, and neither is a trust decision
 *
 * `bankDomainSet` unions every published template's `match.sender_domain` (the
 * banks this build can READ — `dib.ae` and `emiratesnbd.com` ship today) with the
 * account's mailbox sender list (the banks this USER has confirmed, D6). Being in
 * the set only earns a message an op; it never auto-files one. Auto-filing still
 * needs all three gates in `fetch.ts` — a PASSING Gmail verdict, the VERIFIED
 * domain on the sender list, and a template hit.
 */

import type { Definition } from "@ledger/client/tmpl/exec";

/**
 * The bank-domain set for this account: the domains whose mail is worth authoring
 * an op for. Lower-cased, de-duplicated, sorted for a stable query string.
 */
export function bankDomainSet(
  templates: readonly Definition[],
  senders: readonly string[],
): string[] {
  const out = new Set<string>();
  const add = (raw: string): void => {
    const d = raw.trim().toLowerCase();
    if (d !== "") out.add(d);
  };
  for (const def of templates) for (const d of def.match?.sender_domain ?? []) add(d);
  for (const s of senders) add(s);
  return [...out].sort();
}

/**
 * Whether a domain is in the bank set — exactly, or as a subdomain of a member
 * (`alerts.dib.ae` is `dib.ae`'s), the same semantics `senderListed` in `fetch.ts`
 * and `domainMatches` in `sources/heldMessage.ts` already use. Never a suffix
 * match on raw letters: `notdib.ae` is not `dib.ae`.
 */
export function isBankDomain(domain: string, set: readonly string[]): boolean {
  if (domain === "") return false;
  return set.some((s) => domain === s || domain.endsWith(`.${s}`));
}

/**
 * The most `from:` terms a backfill query may carry. A sender list is capped
 * server-side, but nothing here may build an unbounded URL, so a set past this
 * bound falls back to the unfiltered window (see {@link backfillQuery}).
 */
export const MAX_BACKFILL_FROM_TERMS = 20;

/** Gmail query syntax is fenced to this shape; anything else falls the query back. */
const QUERY_SAFE_DOMAIN = /^[a-z0-9][a-z0-9.-]*$/;

/**
 * The `messages.list` query for a backfill over `days`, narrowed to the bank set.
 *
 * # A deliberate, narrowed reversal of this lane's original rationale
 *
 * `gmail.ts` records that server-side filtering "would leak the sender list to
 * Google as a search term", and that note stands for INCREMENTAL catch-up —
 * `users.history.list` takes no query anyway, so that path filters client-side and
 * always will. The reversal is for BACKFILL only, where the flood is: Google
 * already receives this mail and already knows who sent it, so the marginal
 * disclosure is *which* of those senders ledger acts on, weighed against pulling
 * (and paying the round trip for) a year of a mailbox's unrelated mail. Recorded
 * here rather than deleted there.
 *
 * # Every fallback is toward MORE mail, never less
 *
 * An empty set, a set past {@link MAX_BACKFILL_FROM_TERMS}, or a single domain
 * that is not query-safe all fall back to the plain window. That direction is not
 * an accident: a brand-new account's sender list is empty by construction and its
 * first bank message is the one that creates the review card that trusts the
 * domain — so a filter applied to an empty set would make the product import
 * nothing, forever. Truncating an over-long set would silently exclude whichever
 * senders fell off the end. Filtering is an optimisation; the client-side
 * disposition in `fetch.ts` is the authority.
 *
 * Gmail matches `from:` on the address's domain tokens, so `from:dib.ae` also
 * returns mail from `alerts.dib.ae` — the same subdomain reach {@link isBankDomain}
 * gives the client-side check.
 */
export function backfillQuery(days: number, bankDomains: readonly string[]): string {
  if (bankDomains.length === 0 || bankDomains.length > MAX_BACKFILL_FROM_TERMS) return windowTerms(days);
  if (!bankDomains.every((d) => QUERY_SAFE_DOMAIN.test(d))) return windowTerms(days);
  return `${windowTerms(days)} {${bankDomains.map((d) => `from:${d}`).join(" OR ")}}`;
}

/**
 * The window every backfill query starts from: `days` back, Spam INCLUDED, Trash
 * excluded.
 *
 * # Spam is in, and that is the point
 *
 * The `messages.list` request carries `includeSpamTrash=true` (`gmail.ts`), which
 * is the fix for a real hole: mail a user forwards to the burner fails SPF at the
 * forwarding hop, so Gmail spam-files it readily — a probe this project ran landed
 * in Spam and had to be found with `in:anywhere`. Without the flag such a message
 * was invisible to BACKFILL forever, even though `users.history.list` surfaces
 * spam with no flag at all, so the incremental path and the backfill path
 * disagreed about what the mailbox contained.
 *
 * # Trash is out, deliberately
 *
 * `-in:trash` is the judgement call, and it goes the other way for three reasons:
 * moving a message to Trash is an explicit human act on THAT message, unlike the
 * spam filing which is a machine's guess; Gmail purges Trash after 30 days, so a
 * trashed message violates D5's premise that the burner mailbox is the durable
 * archive (import it and the review card's re-fetch by provenance id will 404
 * within the month); and the failure direction is recoverable — a user who wants
 * a trashed bank mail imported can move it back out of Trash, whereas an op
 * authored for something they deleted is permanent on every device, forever.
 */
function windowTerms(days: number): string {
  return `newer_than:${days}d -in:trash`;
}

/**
 * The `messages.list` query that finds ONE domain's mail in the window — the
 * fallback "This is my bank" uses so an import is not limited to whatever
 * survived the set-aside ring (`state.ts`'s {@link MAX_SET_ASIDE_RECENT}).
 *
 * Returns `null` when the domain is not query-safe, which the caller answers by
 * importing the retained ids alone. That is the same direction every fallback in
 * this file takes — never a query that might mean something other than intended.
 */
export function setAsideImportQuery(days: number, domain: string): string | null {
  const d = domain.trim().toLowerCase();
  if (d === "" || !QUERY_SAFE_DOMAIN.test(d)) return null;
  return `${windowTerms(days)} from:${d}`;
}
