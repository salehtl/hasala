/**
 * The content behind a mailbox needs-review card: re-fetch the message by its
 * provenance id, read it as far as this device honestly can, and answer the
 * three device states the surface renders (spec §2.2, "the needs-review surface
 * is designed, not implied").
 *
 * # Why re-fetching is the whole design
 *
 * A mailbox-lane needs-review op is deliberately EMPTY — no amount, no body text
 * on the hot stream, and D5 forbids a cold copy (`mailbox/fetch.ts`). So the card
 * has nothing to show until it goes back to Gmail for the message, by the
 * `message_id` the op recorded in its provenance. That fetch can only run on the
 * holder device with a live token, which is exactly what makes the three states
 * below different questions rather than three flavours of one error:
 *
 *   - **holder + live token** → the message is fetched, normalized, and the
 *     lane-2 prefill (the same building blocks `sources/heldMessage.ts` uses)
 *     turns it into a form the human verifies. This is the only state that reads
 *     the message at all.
 *   - **non-holder** → this device holds no sealed token, so it CANNOT read the
 *     mailbox and does not try. It says so and points at the device that can. No
 *     mint, no fetch: a non-holder must never even attempt the read.
 *   - **reconnect_required** → a token is here but dead (`mintAccessToken` throws
 *     the typed `reconnect_required`; Task 9). This routes to the reconnect
 *     affordance, never an error banner — the distinction the fetch lane already
 *     draws (`fetch.ts`, D10).
 *
 * `unavailable` is a fourth, transient answer: a network blip, a Gmail 5xx, an
 * undecodable body. It is retryable and is NOT reconnect — telling a holder whose
 * mailbox is merely unreachable to reconnect would be the same lie `mailboxConnect`
 * is at pains to avoid.
 *
 * # This module reads a message; it never authors an op and never trusts a sender
 *
 * It returns a {@link Prefill} (a form to be verified by a human) and, when the
 * message carries a Gmail A-R that PASSES, the verified signing domain the card
 * may offer to trust for future auto-import. The domain is offered ONLY on a pass
 * because trusting a domain whose mail would still miss the D4/D6 gates would not
 * import anything — the honest surface offers the action only where it works. No
 * verdict here says anything about whether THIS message is genuine; a human is
 * the verifier, exactly as in the held-mail lane (D6a).
 */

import { normalize, CURRENT_VERSION, type NormalizeResult } from "@ledger/client/norm/norm";
import { gmailVerdict, verifiedDomain } from "@ledger/client/mail/authres";
import { webPlatform } from "@ledger/client/platform.web";
import { compileDefinition, produced, validateExtraction, type Definition, type Extraction } from "@ledger/client/tmpl/exec";

import { isMailboxReconnectRequired } from "../mailboxConnect";
import { candidateTemplates, draftFromExtraction, type Prefill } from "../sources/heldMessage";
import { gmailRest, type GmailApi } from "./gmail";
import { headerBlock } from "./headers";
import { isForwarderDomain } from "./senders";

/**
 * What the card can be shown, keyed by the one fact that decides everything: can
 * this device read the mailbox, and if so did the read succeed.
 */
export type MailboxReviewContent =
  | {
      state: "ready";
      /** The message, read as far as this device honestly can (form + preview). */
      prefill: Prefill;
      /**
       * The verified signing domain to offer for automatic import, or `null` when
       * the message's own Gmail verdict did not pass — in which case trusting the
       * domain would import nothing, so the action is not offered.
       */
      trustDomain: string | null;
    }
  | { state: "non_holder" }
  | { state: "reconnect_required" }
  | { state: "unavailable"; reason: string };

export interface MailboxReviewContentDeps {
  /** The op's provenance — the id the message is re-fetched by. */
  provenance: { message_id: string };
  /**
   * The op's `posted_at`, the normalizer's date fallback: a raw Gmail message
   * carries no top-level `Date:` the normalizer reads, so the op's day stands in.
   */
  receivedAt: string;
  /**
   * Whether this device holds a usable sealed token — i.e. it is the holder (D9).
   * Checked FIRST and, on a throw (a shared-browser residual row), read as "not a
   * holder" rather than surfaced — the same rule the fetch-lane scheduler applies.
   */
  hasSealedToken(): Promise<boolean>;
  /**
   * Mints a Gmail access token (`mailboxConnect.mintAccessToken`). A
   * `reconnect_required` MailboxError is the reconnect state; anything else is
   * transient `unavailable`.
   */
  mintAccessToken(): Promise<string>;
  /** The published template definitions the prefill executor tries. */
  loadTemplates(): Promise<readonly Definition[]>;
  /** Builds the Gmail driver for a token. Defaults to {@link gmailRest}. */
  makeGmail?(accessToken: string): GmailApi;
  /** Decodes the raw base64url body. Defaults to the strict platform decoder. */
  decodeBase64Url?(rawBase64Url: string): Uint8Array;
}

/** A retryable, non-reconnect failure. One sentence, no jargon, no blame. */
const UNAVAILABLE_REASON = "Couldn't fetch this message right now. Try again in a moment.";

/**
 * Loads a mailbox review card's content, answering exactly one of the four
 * states. Never rejects: every failure it can name becomes a state, because a
 * surface that threw would take out whatever is rendering the card.
 */
export async function loadMailboxReviewContent(deps: MailboxReviewContentDeps): Promise<MailboxReviewContent> {
  // Non-holder FIRST, and a residual-row throw counts as non-holder: a device
  // that cannot even check its token is certainly not reading the mailbox, and
  // it must not mint or fetch. This is the "no re-fetch attempted" guarantee.
  let holder: boolean;
  try {
    holder = await deps.hasSealedToken();
  } catch {
    holder = false;
  }
  if (!holder) return { state: "non_holder" };

  let accessToken: string;
  try {
    accessToken = await deps.mintAccessToken();
  } catch (err) {
    if (isMailboxReconnectRequired(err)) return { state: "reconnect_required" };
    return { state: "unavailable", reason: UNAVAILABLE_REASON };
  }

  const gmail = (deps.makeGmail ?? ((token: string): GmailApi => gmailRest(token)))(accessToken);
  const decode = deps.decodeBase64Url ?? ((b: string): Uint8Array => webPlatform.fromBase64Url(b));

  let bytes: Uint8Array;
  try {
    const raw = await gmail.getRaw(deps.provenance.message_id);
    bytes = decode(raw.rawBase64Url);
  } catch {
    return { state: "unavailable", reason: UNAVAILABLE_REASON };
  }

  const templates = await deps.loadTemplates().catch(() => [] as readonly Definition[]);

  // The domain to offer for auto-import is the one Gmail's own A-R vouched for,
  // and ONLY when that verdict passed — otherwise future mail from it would still
  // miss the D4 gate and trusting it would import nothing. `verifiedDomain`
  // already returns null unless the verdict is trusted, so this reads the same
  // HEADER BLOCK the fetch lane's gates read (`headers.ts` — handing the whole
  // message would make any mail over 256 KiB a `parse_error` on size alone).
  //
  // A FORWARDER is never offered. For a hand-forward the domain Gmail vouches
  // for is the forwarder itself (`gmail.com`), and trusting that would auto-file
  // everything ever relayed through the mailbox — as permanent ops, on every
  // device. The server refuses it too (`handleMailboxAddSender` → 409
  // `forwarder_domain`); nulling it here means the UI never offers a button the
  // server would reject.
  const headers = headerBlock(webPlatform.utf8Decode(bytes));
  const vouched = gmailVerdict(headers).reason === "pass" ? verifiedDomain(headers) : null;
  const trustDomain = vouched !== null && isForwarderDomain(vouched) ? null : vouched;

  // The verified domain FIRST, then the claimed `From:` — the same order, from
  // the same bytes, that `fetch.ts`'s `domainsToTry` uses. This used to pass the
  // claimed From alone, so a bank that signs as `dib.ae` but sends as
  // `no-reply@alerts.dibmail.example` got a template hit on the fetch path and a
  // bare "no reader for this sender" here: the same message, two answers.
  //
  // Widening it changes nothing about trust. `candidateTemplates` only decides
  // which template to TRY, and this whole module authors nothing and files
  // nothing — a human verifies the form. `fetch.ts` states the rule the same way:
  // matching is not believing.
  const prefill = prefillFromRaw(bytes, templates, deps.receivedAt, trustDomain);

  return { state: "ready", prefill, trustDomain };
}

/**
 * A held-message-style prefill over the raw bytes of a mailbox message.
 *
 * It reuses `sources/heldMessage.ts`'s building blocks — {@link candidateTemplates}
 * to narrow by the message's domains and {@link draftFromExtraction} to shape a
 * matched template into a form — so the mailbox review card and the held-mail lane
 * fill a form the same way. The domains are the A-R-verified one (when there is
 * one) and the claimed `From:`, in that order, exactly as `fetch.ts` tries them.
 * A claim, never a verdict — matching narrows which template to try, it never
 * decides anything is true.
 *
 * Never throws: an unreadable message is a `reason` and an empty form, because
 * the fallback is plain manual entry and a card that crashed would take that away.
 */
function prefillFromRaw(
  raw: Uint8Array,
  templates: readonly Definition[],
  fallbackDate: string,
  verified: string | null,
): Prefill {
  let norm: NormalizeResult;
  try {
    norm = normalize(CURRENT_VERSION, raw, fallbackDate);
  } catch {
    return {
      body: "",
      subject: "",
      claimedFrom: "",
      draft: null,
      templateId: null,
      reason: "ledger could not read this message's text. You can still add the transaction yourself.",
    };
  }

  const base = { body: norm.text, subject: norm.subject, claimedFrom: norm.from };
  const candidates = candidateTemplates(templates, domainsToTry(verified, norm.from));
  if (candidates.length === 0) {
    return {
      ...base,
      draft: null,
      templateId: null,
      reason: "ledger has no reader for this sender, so nothing was filled in. The message is below — copy the details across.",
    };
  }

  for (const definition of candidates) {
    let extraction: Extraction;
    try {
      extraction = compileDefinition(definition).execute(norm.subject, norm.text);
      if (!extraction.matched) continue;
      if (validateExtraction(extraction, definition) !== "") continue;
      if (!produced(extraction, "amount")) continue;
    } catch {
      continue;
    }
    return {
      ...base,
      draft: draftFromExtraction(extraction, norm.emailDate),
      templateId: definition.id,
      reason: "Filled in from the message below. Check every field before you add it.",
    };
  }

  return {
    ...base,
    draft: null,
    templateId: null,
    reason: "ledger could not read the details out of this message, so nothing was filled in. The message is below.",
  };
}

/**
 * The domains a template may be tried against: the A-R-verified one first, then
 * the claimed `From:`. Mirrors `fetch.ts`'s `domainsToTry` field for field, so a
 * message cannot get a prefill on one path and none on the other.
 */
function domainsToTry(verified: string | null, from: string): string[] {
  const out = new Set<string>();
  if (verified !== null && verified !== "") out.add(verified);
  const at = from.lastIndexOf("@");
  if (at >= 0) {
    const claimed = from
      .slice(at + 1)
      .trim()
      .toLowerCase()
      .replace(/[>\s]+$/, "");
    if (claimed !== "") out.add(claimed);
  }
  return [...out];
}
