/**
 * The Gmail fetch lane: pull mail from the burner mailbox, decide trust, and
 * author ops on the holder device (spec §2.2, D2/D4/D5/D6/D6a).
 *
 * This is op-authoring code — the highest-risk kind in the repo, because one
 * malformed op is a permanent anomaly on every device forever (CLAUDE.md). Two
 * disciplines follow from that and run through the whole file:
 *
 *   1. **Every fetched message ends as an op or an accounted item — never a
 *      silent skip.** A message becomes a no-review op, an empty needs-review
 *      op, a SET-ASIDE entry (not from a bank — see below), an `unreadable`
 *      count (over-cap, undecodable, or PERMANENTLY unfetchable — the burner
 *      mailbox remains the durable copy for all but the last, D5), or a dedup
 *      skip of an id already authored.
 *      The `historyId` checkpoint advances ONLY after a page's every message is
 *      accounted; a thrown mid-page error leaves it exactly where it was, so the
 *      next cycle re-fetches — safe under ingest-id dedup.
 *
 *      **"Accounted" now includes a message Gmail refuses to serve.** A download
 *      that fails permanently (404/410) is recorded `unreadable` and the cycle
 *      moves PAST it; only a transient failure that outlives its retries halts
 *      the cycle. Before that split, one deleted message rejected the whole
 *      concurrent chunk, the checkpoint never advanced, and the same page was
 *      re-fetched and re-failed every 60 seconds forever — so nothing after it
 *      was ever read, and the screen said "0 emails read". The more mail in the
 *      mailbox, the more messages per page and the likelier the wedge, which is
 *      exactly the "it works until another bank's mail is in there" shape.
 *
 *      **An op is authored only for mail plausibly from a bank.** A burner
 *      mailbox still receives newsletters, password resets and Google's own
 *      security notices, and this lane used to author an empty needs-review op
 *      for every one of them — permanent review cards, on every device, forever,
 *      because the op log is append-only and there is no undo. Everything from a
 *      domain outside the bank set (`bankDomains.ts`) is instead recorded in the
 *      device-local state row and shown to the user, grouped by sender, with a
 *      "This is my bank" action that trusts the domain and imports those exact
 *      messages ({@link importSetAsideDomain}). That is not a silent drop, and
 *      the asymmetry is the whole argument: **an op is irreversible; a set-aside
 *      is not.** D5 makes the burner mailbox the durable archive, so a set-aside
 *      message is still in Gmail and re-fetchable by id at any time.
 *   2. **The trust boundary is three gates, all required (D4/D6, Task 10
 *      carry-forward).** A no-review op needs the Gmail `Authentication-Results`
 *      verdict to PASS *and* its verified domain to be on the account's mailbox
 *      sender list *and* a template-tier parse to hit. There is no heuristic
 *      tier client-side. Miss any one and the message becomes an EMPTY
 *      needs-review op (no amount, no body text on the hot stream, D5), resolved
 *      later by re-fetching the message by its provenance id.
 *
 * Ops are authored through the device writer with `entry_method: "mailbox"` (a
 * label the fold reads for nothing, D6a — provenance comes from the writer) and
 * `provenance {provider, grant_id, message_id}` in the payload, then pushed over
 * `POST /api/v1/sync`. A full account answers 413 `account_full`, which halts the
 * cycle with the checkpoint intact so it resumes when room frees.
 */

import { normalize, CURRENT_VERSION, type NormalizeResult } from "@ledger/client/norm/norm";
import { gmailVerdict, verifiedDomain } from "@ledger/client/mail/authres";
import { ApiError } from "@ledger/client/net/client";
import type { OpSpec } from "@ledger/client/outbox/outbox";
import { webPlatform } from "@ledger/client/platform.web";
import {
  compileDefinition,
  produced,
  validateExtraction,
  type Definition,
  type Extraction,
} from "@ledger/client/tmpl/exec";
import type { Op } from "@ledger/client/wire/op";

import { isMailboxReconnectRequired } from "../mailboxConnect";
import { browserMailboxTokenStore, type KeyStore } from "../mailboxToken";
import { candidateTemplates, draftFromExtraction } from "../sources/heldMessage";
import { manualTxnPayload, MAILBOX_ENTRY_METHOD } from "../sources/transactions";
import type { Writer } from "../writer";
import { backfillQuery, bankDomainSet, isBankDomain, setAsideImportQuery } from "./bankDomains";
import {
  GmailApiError,
  GmailHistoryGapError,
  gmailRest,
  type GmailApi,
  type GmailRawMessage,
} from "./gmail";
import { headerBlock } from "./headers";
import { setAsideIdsForDomain } from "./setAside";
import {
  emptySetAsideLog,
  forgetSetAsideDomain,
  readMailboxState,
  recordSetAside,
  recordUnreadable,
  writeMailboxState,
  type BackfillCursor,
  type MailboxState,
  type SetAsideLog,
  type SetAsideRecord,
  type UnreadableRecord,
} from "./state";

/**
 * The per-message size cap, aligned with the SMTP `MaxMessageBytes` — which
 * defaults to `blob.MaxColdMail` (1,000,000 bytes), the largest raw message the
 * cold store guarantees to seal. A message at or over it is refused on the SMTP
 * lane, so it is an `unreadable` item here rather than a parse attempt. Kept as a
 * constant (overridable via {@link FetchCycleDeps.maxMessageBytes}) because the
 * client cannot read the server's SMTP config; it mirrors the server's value.
 */
export const MAILBOX_MAX_MESSAGE_BYTES = 1_000_000;

/**
 * The tally one cycle reports (Task 13/15 render it).
 *
 * `ops` counts every op authored (no-review AND needs-review); `review` is how
 * many of those were needs-review; `unreadable` is messages that became a
 * visible "couldn't read" item without an op (over-cap, undecodable, or one
 * Gmail permanently refuses to serve — the mailbox keeps all but the last).
 * `fetched` is every message the cycle actually pulled, so a message that never
 * downloaded is counted in `unreadable` and NOT in `fetched`: "N emails read"
 * must not include one that was not.
 */
export interface CycleReport {
  fetched: number;
  ops: number;
  review: number;
  unreadable: number;
  /**
   * Messages that were NOT imported because they did not come from a bank
   * domain — no op was authored for any of them. They stay in the mailbox and
   * are listed for the user, who can say "this is my bank" and have them
   * imported ({@link importSetAsideDomain}).
   *
   * Optional ONLY so that a caller's hand-built stub report (the "this device is
   * not ready" placeholder in the settings drill-in, for instance) need not name
   * it. Every report a real cycle returns carries it, always a number.
   */
  setAside?: number;
  /**
   * Why the cycle stopped short, if it did:
   *   - `budget_full` — the account is full (413); checkpoint intact, resumes.
   *   - `reconnect_required` — no usable token; the user must reconnect (D10).
   *   - `error` — a fetch/push failure mid-cycle; checkpoint unmoved, retries.
   * Absent on a clean cycle.
   */
  haltedOn?: "budget_full" | "reconnect_required" | "error";
  /**
   * A short, content-free description of the failure behind `haltedOn: "error"`
   * — the HTTP status Gmail answered, or the transport failure. It exists
   * because a halted cycle used to render as "0 emails read" with no indication
   * anything had gone wrong, which is the one thing a debugging user needs.
   *
   * Never carries a token: access tokens travel in the Authorization header, so
   * neither a URL nor a Gmail error body contains one, and this is built from
   * the status and the operation name only.
   */
  haltedDetail?: string;
}

/** What one cycle needs. Defaults are the real primitives; tests inject fakes. */
export interface FetchCycleDeps {
  /**
   * Pulls this device's op log to head before authoring (D5/D9). Syncing first
   * shrinks the `duplicate_ingest` window: a message another device already
   * authored is visible via {@link alreadyIngested} and skipped, rather than
   * re-ingested into a permanent anomaly.
   */
  syncToHead(): Promise<void>;
  /**
   * Mints a Gmail access token via the broker (`mailboxConnect.mintAccessToken`).
   * A `reconnect_required` MailboxError halts the cycle honestly; any other
   * failure is an `error`.
   */
  mintAccessToken(): Promise<string>;
  /** The account's mailbox sender allowlist (`GET /api/v1/mailbox/senders`). */
  loadSenders(): Promise<readonly string[]>;
  /** The published template definitions the executor tries. */
  loadTemplates(): Promise<readonly Definition[]>;
  /** True iff an op with this ingest id has already folded on this device. */
  alreadyIngested(ingestId: string): boolean | Promise<boolean>;
  /** The device writer: enqueue + flush + read pending. */
  writer: Writer;
  /** A ULID/entity-id source for each authored txn (`newEntityID`). */
  newID(): string;
  /**
   * The grant identifier recorded in every op's provenance, so a review card can
   * re-fetch the message from the right mailbox. The server exposes no grant id
   * (its grant response is deliberately id-less), so the caller supplies a stable
   * per-grant value — the account id serves, since D9 pins one grant per account.
   */
  grantId: string;
  /** Builds the Gmail driver for a token. Defaults to {@link gmailRest}. */
  makeGmail?(accessToken: string): GmailApi;
  /** The checkpoint/backfill store. Defaults to the sealed token's store. */
  store?: KeyStore;
  /** Clock. Defaults to `() => new Date()`. */
  now?(): Date;
  /** Per-message size cap. Defaults to {@link MAILBOX_MAX_MESSAGE_BYTES}. */
  maxMessageBytes?: number;
  /**
   * Waits between download retries. Injected ONLY so tests need not burn real
   * seconds; production is a plain `setTimeout`.
   */
  sleep?(ms: number): Promise<void>;
}

/** The provenance every mailbox op records (D5). Content-free of the message body. */
interface MailboxProvenance {
  provider: "gmail";
  grant_id: string;
  message_id: string;
}

/**
 * Runs one fetch cycle and reports what it did. Never rejects: every failure it
 * can name becomes a `haltedOn` on the report, because a fetch loop that threw
 * would take out whatever background scheduler drives it.
 */
export async function runFetchCycle(deps: FetchCycleDeps): Promise<CycleReport> {
  const report: CycleReport = { fetched: 0, ops: 0, review: 0, unreadable: 0, setAside: 0 };
  const store = deps.store ?? browserMailboxTokenStore();
  const now = deps.now ?? ((): Date => new Date());
  const cap = deps.maxMessageBytes ?? MAILBOX_MAX_MESSAGE_BYTES;
  const makeGmail = deps.makeGmail ?? ((token: string): GmailApi => gmailRest(token));

  try {
    // D5: op log to head first, so dedup sees peers' ops before we author.
    await deps.syncToHead();

    let accessToken: string;
    try {
      accessToken = await deps.mintAccessToken();
    } catch (err) {
      if (isMailboxReconnectRequired(err)) return { ...report, haltedOn: "reconnect_required" };
      throw err;
    }

    const gmail = makeGmail(accessToken);
    const senders = await deps.loadSenders();
    const templates = await deps.loadTemplates();
    const state = await readMailboxState(store);

    // Ingest ids this device has authored but not yet pushed (a previous cycle
    // that halted on budget, or an app kill between emit and flush). Skipping
    // them is what keeps a checkpoint-intact resume from minting a second op —
    // and therefore a permanent duplicate_ingest anomaly — for the same message.
    const pendingIngest = pendingIngestIds(deps.writer.pending);

    // The domains worth authoring an op for: what this build can read (template
    // sender domains) plus what this user has confirmed (the sender list).
    const bank = bankDomainSet(templates, senders);

    const plan = await planFetch(gmail, state, bank);

    // Messages that couldn't be read this cycle, folded into the durable log only
    // once the page is fully accounted (below), so a halted page records nothing.
    let unreadable = state.unreadable;
    const markUnreadable = (rec: UnreadableRecord): void => {
      report.unreadable += 1;
      unreadable = recordUnreadable(unreadable, rec);
    };

    // Set-aside entries ride the SAME barrier as the checkpoint and the unreadable
    // log: accumulated in memory, persisted only once the page is fully accounted.
    // A throw mid-page therefore records nothing, and the re-fetch next cycle
    // re-derives it — the alternative (writing as we go) would leave a page
    // half-recorded against a checkpoint that never moved.
    let setAside = state.setAside ?? emptySetAsideLog();
    const markSetAside = (rec: SetAsideRecord): void => {
      report.setAside = (report.setAside ?? 0) + 1;
      setAside = recordSetAside(setAside, rec);
    };

    // Downloads run a few at a time; the accounting below stays strictly
    // sequential and in page order. One message per round trip was the whole
    // cost of a cycle — a page of 100 at ~300ms each is half a minute of
    // nothing. Only the network is overlapped, so op authoring, dedup and the
    // unreadable log see exactly the order they saw before.
    const downloader = messageDownloader(gmail, deps.sleep ?? realSleep);
    for (let i = 0; i < plan.messageIds.length; ) {
      const chunk = plan.messageIds.slice(i, i + downloader.width());
      i += chunk.length;
      const outcomes = await Promise.all(chunk.map((id) => downloader.get(id)));

      for (const outcome of outcomes) {
      if (outcome.kind === "gone") {
        // PERMANENTLY unfetchable — a 404/410 (deleted between the list and the
        // download) or a 2xx with no `raw` body. Accounted and recorded, and the
        // cycle ADVANCES PAST IT. Before this, one such message rejected the
        // whole `Promise.all`, the checkpoint never moved, and the same page was
        // re-fetched and re-failed every 60 seconds forever — nothing after it
        // was ever read. That is the "0 emails read" wedge.
        markUnreadable({ message_id: outcome.id, reason: "gone" });
        continue;
      }
      if (outcome.kind === "failed") {
        // TRANSIENT and still failing after the retries: throw, exactly as
        // before. The checkpoint may not move — a message that was never read is
        // not accounted, and advancing past it would lose it — so the cycle
        // halts and the next one re-reads the page. Progress is not lost: ops
        // authored above are already durably queued and dedup against their
        // ingest ids on the re-read.
        throw outcome.error;
      }
      const raw = outcome.raw;
      const id = raw.id;
      report.fetched += 1;

      let bytes: Uint8Array;
      try {
        bytes = webPlatform.fromBase64Url(raw.rawBase64Url);
      } catch {
        // Undecodable: the strict decoder refused it rather than hand back a
        // plausible short body. Accounted, recorded — the mailbox keeps it.
        markUnreadable({ message_id: id, reason: "undecodable", ...internalDateField(raw.internalDate) });
        continue;
      }
      if (bytes.length >= cap) {
        // Over the SMTP cap: a visible "couldn't read" item, never a silent skip.
        markUnreadable({ message_id: id, reason: "over_cap", ...internalDateField(raw.internalDate) });
        continue;
      }

      // Fail-soft: a garbage/out-of-range internalDate must route THIS message to
      // unreadable, never throw a RangeError out of the whole cycle.
      const receivedAt = receivedAtOf(raw.internalDate, now());
      if (receivedAt === null) {
        markUnreadable({ message_id: id, reason: "bad_date", ...internalDateField(raw.internalDate) });
        continue;
      }

      const ingestId = webPlatform.toHex(webPlatform.sha256(bytes)).toLowerCase();
      if (pendingIngest.has(ingestId) || (await deps.alreadyIngested(ingestId))) {
        // Already authored (locally or folded): accounted, no new op.
        continue;
      }

      const disposed = disposeMessage({
        bytes,
        ingestId,
        messageId: id,
        senders,
        templates,
        bank,
        deps,
        now: now(),
        receivedAt,
      });
      if (disposed.kind === "set_aside") {
        // No op. Accounted, recorded, visible, and reversible — the message is
        // still in the mailbox and one tap from being imported.
        markSetAside(disposed.record);
        continue;
      }
      deps.writer.enqueueMany([disposed.spec]); // durable emit
      pendingIngest.add(ingestId);
      report.ops += 1;
      if (disposed.review) report.review += 1;
      }
    }

    // Every message on the page is accounted. Push, THEN advance the checkpoint —
    // a push that 413s must leave the checkpoint where it was so the cycle
    // resumes (the queued ops stay durable and dedup against them next time).
    try {
      await deps.writer.flush();
    } catch (err) {
      if (isAccountFull(err)) return { ...report, haltedOn: "budget_full" };
      throw err;
    }

    // The checkpoint and the unreadable log advance together, and only here — a
    // halted page persists neither, so nothing is double-counted on a resume.
    await writeMailboxState(
      {
        ...state,
        // Null while a backfill still has pages: the checkpoint may only move
        // once its last page is accounted, or the rest would never be read.
        historyId: plan.nextHistoryId ?? state.historyId,
        backfill: plan.nextBackfill,
        lastCycleAt: now().toISOString(),
        unreadable,
        setAside,
      },
      store,
    );
    return report;
  } catch (err) {
    // Any fetch/push failure the cases above did not name. The checkpoint was not
    // written, so the next cycle re-fetches from where this one started.
    //
    // The detail is carried, not swallowed: a bare `catch {}` here rendered every
    // failure as "0 emails read" with nothing to act on.
    return { ...report, haltedOn: "error", haltedDetail: haltDetail(err) };
  }
}

/**
 * A short, safe description of a cycle failure. Content-free by construction: a
 * Gmail refusal contributes its operation name and HTTP status, anything else
 * contributes its error name and a trimmed message. No token can appear —
 * access tokens ride the Authorization header, never a URL or a response body.
 */
function haltDetail(err: unknown): string {
  if (err instanceof GmailApiError) {
    if (err.status === 403) {
      return `Gmail refused the request (403). Usually the Gmail API is not enabled for this Google Cloud project, or the grant lacks the read scope.`;
    }
    if (err.status === 401) return `Gmail rejected the access token (401). Reconnecting the mailbox should fix it.`;
    if (err.status === 429) return `Gmail is rate-limiting this mailbox (429). It will catch up on the next try.`;
    return `Gmail answered ${err.status}.`;
  }
  if (err instanceof TypeError) {
    return `The browser could not reach Gmail (blocked or offline).`;
  }
  const name = err instanceof Error && err.name !== "" ? err.name : "Error";
  const message = err instanceof Error ? err.message.slice(0, 120) : "";
  return message === "" ? name : `${name}: ${message}`;
}

/**
 * Imports the messages this lane set aside for one sender domain — the other
 * half of "ask the user which bank".
 *
 * The caller has already trusted the domain (`senders.trustSender`), so
 * {@link FetchCycleDeps.loadSenders} returns it; it is also forced into this
 * run's bank set so that every message recorded under it (and its subdomains) is
 * authored, exactly as the user asked. The trust gates are UNCHANGED: a message
 * whose Gmail verdict does not pass, or that no template reads, still becomes a
 * needs-review op rather than a filed one. Trusting a sender says "import from
 * here", never "believe this".
 *
 * What it imports is {@link importableIds}: the set-aside ring's entries for the
 * domain UNIONED with what Gmail itself still has from that sender in the window.
 * The ring alone under-imported silently once unrelated mail evicted a bank's
 * older entries, which made the button's own sentence false.
 *
 * Two orderings this shares with {@link runFetchCycle}, for the same reasons:
 * the log is synced to head first so dedup sees peers' ops, and the state row is
 * written only after `flush()` succeeds — a refused push (413 `account_full`)
 * leaves the entries set aside, so a retry still finds them. The `historyId`
 * checkpoint is never touched: this is a targeted re-read of messages the cycle
 * already accounted, not a catch-up.
 */
export async function importSetAsideDomain(deps: FetchCycleDeps, domain: string): Promise<CycleReport> {
  const report: CycleReport = { fetched: 0, ops: 0, review: 0, unreadable: 0, setAside: 0 };
  const store = deps.store ?? browserMailboxTokenStore();
  const now = deps.now ?? ((): Date => new Date());
  const cap = deps.maxMessageBytes ?? MAILBOX_MAX_MESSAGE_BYTES;
  const makeGmail = deps.makeGmail ?? ((token: string): GmailApi => gmailRest(token));

  try {
    await deps.syncToHead();

    let accessToken: string;
    try {
      accessToken = await deps.mintAccessToken();
    } catch (err) {
      if (isMailboxReconnectRequired(err)) return { ...report, haltedOn: "reconnect_required" };
      throw err;
    }

    const gmail = makeGmail(accessToken);
    const senders = await deps.loadSenders();
    const templates = await deps.loadTemplates();
    const state = await readMailboxState(store);
    const log: SetAsideLog = state.setAside ?? emptySetAsideLog();
    // The user's answer is authoritative for this run: the domain is in the bank
    // set even if the server round trip that trusted it has not propagated here.
    const bank = bankDomainSet(templates, [...senders, domain]);
    const pendingIngest = pendingIngestIds(deps.writer.pending);

    let unreadable = state.unreadable;
    const downloader = messageDownloader(gmail, deps.sleep ?? realSleep);
    for (const id of await importableIds(gmail, log, domain, state.backfillDays)) {
      const outcome = await downloader.get(id);
      if (outcome.kind === "gone") {
        report.unreadable += 1;
        unreadable = recordUnreadable(unreadable, { message_id: id, reason: "gone" });
        continue;
      }
      if (outcome.kind === "failed") throw outcome.error;
      const raw = outcome.raw;
      report.fetched += 1;

      let bytes: Uint8Array;
      try {
        bytes = webPlatform.fromBase64Url(raw.rawBase64Url);
      } catch {
        report.unreadable += 1;
        unreadable = recordUnreadable(unreadable, { message_id: id, reason: "undecodable", ...internalDateField(raw.internalDate) });
        continue;
      }
      if (bytes.length >= cap) {
        report.unreadable += 1;
        unreadable = recordUnreadable(unreadable, { message_id: id, reason: "over_cap", ...internalDateField(raw.internalDate) });
        continue;
      }
      const receivedAt = receivedAtOf(raw.internalDate, now());
      if (receivedAt === null) {
        report.unreadable += 1;
        unreadable = recordUnreadable(unreadable, { message_id: id, reason: "bad_date", ...internalDateField(raw.internalDate) });
        continue;
      }

      const ingestId = webPlatform.toHex(webPlatform.sha256(bytes)).toLowerCase();
      if (pendingIngest.has(ingestId) || (await deps.alreadyIngested(ingestId))) continue;

      const disposed = disposeMessage({
        bytes,
        ingestId,
        messageId: id,
        senders,
        templates,
        bank,
        deps,
        now: now(),
        receivedAt,
      });
      // Unreachable in practice — the domain is in the bank set by construction
      // above — but a set-aside answer here must stay set aside rather than be
      // dropped on the floor, so the entry survives the forget below.
      if (disposed.kind === "set_aside") {
        report.setAside = (report.setAside ?? 0) + 1;
        continue;
      }
      deps.writer.enqueueMany([disposed.spec]);
      pendingIngest.add(ingestId);
      report.ops += 1;
      if (disposed.review) report.review += 1;
    }

    try {
      await deps.writer.flush();
    } catch (err) {
      if (isAccountFull(err)) return { ...report, haltedOn: "budget_full" };
      throw err;
    }

    await writeMailboxState(
      { ...state, unreadable, setAside: forgetSetAsideDomain(log, domain) },
      store,
    );
    return report;
  } catch (err) {
    return { ...report, haltedOn: "error", haltedDetail: haltDetail(err) };
  }
}

/**
 * How many `messages.list` pages one "This is my bank" import will read. A bound
 * for the same reason {@link MAX_PAGES} is one, but far smaller: this is a single
 * user-initiated action behind a spinner, not a background catch-up, and 500
 * messages from one sender inside the window is already far past any real bank.
 */
const MAX_IMPORT_PAGES = 5;

/**
 * Every message id "This is my bank" must import for a domain: the ids still in
 * the set-aside ring, PLUS everything Gmail itself has from that sender in the
 * backfill window.
 *
 * # Why the ring alone was a lie
 *
 * The ring is capped at {@link MAX_SET_ASIDE_RECENT} (200) and is GLOBAL, so a
 * mailbox with a lot of unrelated traffic evicts a bank's oldest entries. The
 * user then taps a row and gets fewer messages than the surface implied, with
 * nothing to tell them so and no second chance — the fetch checkpoint has long
 * passed those messages, so no later cycle would ever see them again either. That
 * is the "other mail crowds it out" defect in its second form, and asking Gmail
 * is the only answer that survives eviction.
 *
 * # Safe to widen
 *
 * A query can return messages the ring never held, and that is the point; every
 * one of them still goes through the SAME three gates and the SAME ingest-id
 * dedup as any other message, so widening the input set cannot author a duplicate
 * op and cannot file anything the gates would not have filed. `alreadyIngested`
 * and the pending-ingest set catch anything a previous cycle already authored.
 *
 * Falls back to the ring alone when the domain is not query-safe or the listing
 * fails — an import that returns what it can is strictly better than one that
 * throws, and the entries stay set aside on a throw anyway.
 */
async function importableIds(
  gmail: GmailApi,
  log: SetAsideLog,
  domain: string,
  days: number,
): Promise<string[]> {
  const ids = new Set<string>(setAsideIdsForDomain(log, domain));
  const q = setAsideImportQuery(days, domain);
  if (q === null) return [...ids];
  try {
    let pageToken: string | undefined;
    for (let page = 0; page < MAX_IMPORT_PAGES; page += 1) {
      const res = await gmail.messagesList(q, pageToken);
      for (const m of res.messages) ids.add(m.id);
      if (res.nextPageToken === undefined) break;
      pageToken = res.nextPageToken;
    }
  } catch {
    // The listing is an enrichment, not the contract: keep what the ring knows.
  }
  return [...ids];
}

/** The ids to fetch this cycle, and the checkpoint to advance to once accounted. */
interface FetchPlan {
  messageIds: string[];
  /**
   * The checkpoint to adopt once every id above is accounted, or `null` when
   * this cycle only advanced part of a backfill — the checkpoint may not move
   * until the last page lands, or the pages after it would be skipped forever.
   */
  nextHistoryId: string | null;
  /** Where the next cycle resumes an unfinished backfill, or `null` when done. */
  nextBackfill: BackfillCursor | null;
}

/**
 * Incremental catch-up from the stored checkpoint, or a full backfill when there
 * is no checkpoint or Gmail no longer retains the history since it.
 *
 * The head `historyId` for a backfill is read from the profile FIRST, before the
 * message list, so a message that lands during the backfill is not skipped by a
 * checkpoint set past it (spec §2.2, sync-to-head).
 */
async function planFetch(gmail: GmailApi, state: MailboxState, bank: readonly string[]): Promise<FetchPlan> {
  // An unfinished backfill outranks everything: it is already mid-flight, and
  // its head is the checkpoint the whole run will adopt.
  const cursor = state.backfill ?? null;
  if (cursor !== null) {
    return backfillPage(gmail, state.backfillDays, cursor.head, cursor.pageToken, bank);
  }
  if (state.historyId === null) {
    return backfillStart(gmail, state.backfillDays, bank);
  }
  try {
    // `users.history.list` takes NO query — Gmail offers no way to narrow it — so
    // incremental catch-up pulls every added message and filters CLIENT-side in
    // `disposeMessage`. That is not a gap to be closed later; it is the API.
    return await incremental(gmail, state.historyId);
  } catch (err) {
    if (err instanceof GmailHistoryGapError) return backfillStart(gmail, state.backfillDays, bank);
    throw err;
  }
}

/** A bound on paging so a malfunctioning API cannot spin a cycle forever. */
const MAX_PAGES = 100;

/**
 * How many message downloads are in flight at once. Small on purpose: enough to
 * hide per-request latency, far below anything Gmail would rate-limit.
 */
const FETCH_CONCURRENCY = 6;

/**
 * The backoff between download attempts, in ms — and, by its length, the retry
 * budget: three attempts in all. Short, because the cycle itself retries in a
 * minute; the point of retrying here is only to survive a blip without throwing
 * away a page's worth of already-downloaded work.
 */
const GET_RETRY_BACKOFF_MS = [400, 1_200] as const;

/** The real waiter. Injected away in tests (see {@link FetchCycleDeps.sleep}). */
function realSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * What one message download came back as. Three answers, not two, because the
 * middle one is the whole fix: a message Gmail will NEVER serve must not be
 * treated like a message it could not serve just now.
 */
type Download =
  | { kind: "ok"; raw: GmailRawMessage }
  | { kind: "gone"; id: string }
  | { kind: "failed"; id: string; error: unknown };

/**
 * How a `messages.get` refusal must be answered.
 *
 *   - `gone`   — permanent, message-scoped. 404/410 (deleted or purged between
 *                the list and the download) and any non-error status that still
 *                carried no `raw` body (`gmail.ts` reports that as a
 *                `GmailApiError` with the OK status). Record and move on.
 *   - `retry`  — transient. 429 and 5xx from Gmail, and the browser's `TypeError`
 *                for a blocked or offline fetch. Worth another attempt.
 *   - `fatal`  — account-scoped, so retrying every message on the page would only
 *                be slower before the same halt: 401 (dead token), 403 (API off or
 *                scope missing), and anything this module does not recognise.
 *                Thrown immediately, which is exactly the pre-existing behaviour.
 */
function classifyDownloadFailure(err: unknown): "gone" | "retry" | "fatal" {
  if (err instanceof GmailApiError) {
    if (err.status === 404 || err.status === 410) return "gone";
    if (err.status < 400) return "gone"; // a 2xx that carried no usable body
    if (err.status === 429 || err.status >= 500) return "retry";
    return "fatal"; // 401/403 and friends: the whole grant, not this message
  }
  // The browser's fetch rejects with a TypeError when it cannot reach the host.
  if (err instanceof TypeError) return "retry";
  return "fatal";
}

/** True for Gmail's rate-limit refusal, the one that must narrow the pipe. */
function isRateLimited(err: unknown): boolean {
  return err instanceof GmailApiError && err.status === 429;
}

/**
 * A `messages.get` caller that contains a failure to the ONE message it belongs
 * to, and narrows the pipe when Gmail says it is going too fast.
 *
 * The narrowing matters because {@link FETCH_CONCURRENCY} is itself a plausible
 * cause of a 429: six-way concurrency over a long backfill is the shape that
 * provokes one. Once a 429 is seen anywhere in a cycle the width drops to a
 * single request for the rest of it, so the retries are not fighting the same
 * five siblings that triggered the refusal. It never widens again within a cycle
 * — the next cycle starts fresh, which is a cheap enough recovery for a lane that
 * runs once a minute.
 */
function messageDownloader(
  gmail: GmailApi,
  sleep: (ms: number) => Promise<void>,
): { get(id: string): Promise<Download>; width(): number } {
  let width = FETCH_CONCURRENCY;
  return {
    width: (): number => width,
    async get(id: string): Promise<Download> {
      for (let attempt = 0; ; attempt += 1) {
        try {
          return { kind: "ok", raw: await gmail.getRaw(id) };
        } catch (err) {
          if (isRateLimited(err)) width = 1;
          const how = classifyDownloadFailure(err);
          if (how === "fatal") throw err;
          if (how === "gone") return { kind: "gone", id };
          const backoff = GET_RETRY_BACKOFF_MS[attempt];
          if (backoff === undefined) return { kind: "failed", id, error: err };
          await sleep(backoff);
        }
      }
    },
  };
}

async function incremental(gmail: GmailApi, startHistoryId: string): Promise<FetchPlan> {
  const ids = new Set<string>();
  let nextHistoryId = startHistoryId;
  let pageToken: string | undefined;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const res = await gmail.historyList(startHistoryId, pageToken);
    for (const id of res.added) ids.add(id);
    nextHistoryId = res.historyId;
    if (res.nextPageToken === undefined) break;
    pageToken = res.nextPageToken;
  }
  return { messageIds: [...ids], nextHistoryId, nextBackfill: null };
}

/**
 * Starts a backfill: captures the head FIRST (so a message arriving mid-run is
 * not skipped by a checkpoint set past it), then reads its first page.
 */
async function backfillStart(gmail: GmailApi, days: number, bank: readonly string[]): Promise<FetchPlan> {
  const head = (await gmail.profile()).historyId; // captured before the list
  return backfillPage(gmail, days, head, undefined, bank);
}

/**
 * ONE page of a backfill, and where to resume.
 *
 * A page at a time, deliberately: this used to read every page (up to
 * `MAX_PAGES` × 100 = 10,000 messages) and then download each message in the
 * same cycle, which on a mailbox with a real history is many minutes of a
 * spinner that shows nothing and cannot be resumed if the app is closed. Now
 * each cycle does a bounded slice of work, reports what it read, and parks the
 * rest — the liveness loop and the "Catch up now" button both drain it.
 */
async function backfillPage(
  gmail: GmailApi,
  days: number,
  head: string,
  pageToken: string | undefined,
  bank: readonly string[],
): Promise<FetchPlan> {
  // Narrowed to the bank domains when there are any, and to the plain window
  // when there are not — see `bankDomains.ts` for why every fallback is toward
  // MORE mail, and for the deliberate, backfill-only reversal of `gmail.ts`'s
  // "do not send the sender list to Google" note.
  const res = await gmail.messagesList(backfillQuery(days, bank), pageToken);
  const ids = res.messages.map((m) => m.id);
  if (res.nextPageToken !== undefined) {
    // More to read: hold the checkpoint where it is and resume here next cycle.
    return { messageIds: ids, nextHistoryId: null, nextBackfill: { head, pageToken: res.nextPageToken } };
  }
  return { messageIds: ids, nextHistoryId: head, nextBackfill: null };
}

/** The ingest ids of txn creates this device has queued but not pushed. */
function pendingIngestIds(pending: readonly Op[]): Set<string> {
  const out = new Set<string>();
  for (const op of pending) {
    if ((op.type === "txn_ingested" || op.type === "txn_superseded") && typeof op.ingest_id === "string") {
      out.add(op.ingest_id);
    }
  }
  return out;
}

interface AuthorArgs {
  bytes: Uint8Array;
  ingestId: string;
  messageId: string;
  senders: readonly string[];
  templates: readonly Definition[];
  /** The domains worth authoring an op for (`bankDomains.ts`). */
  bank: readonly string[];
  deps: FetchCycleDeps;
  now: Date;
  /** The mailbox arrival time (from Gmail's internalDate), the normalizer's date fallback. */
  receivedAt: string;
}

/**
 * What one message becomes: an op (with whether it needs review), or a set-aside
 * entry — mail this lane will not author anything for, recorded so the user can
 * see it and import it.
 */
type Disposition =
  | { kind: "op"; spec: OpSpec; review: boolean }
  | { kind: "set_aside"; record: SetAsideRecord };

/**
 * Decides what a message becomes: the bank-set question first, then the three
 * gates.
 *
 * ## The disposition table this implements
 *
 * | bank domain | template hit | verdict + listed sender | result             |
 * | ----------- | ------------ | ----------------------- | ------------------ |
 * | yes         | yes          | both pass               | filed op           |
 * | yes         | yes          | either fails            | needs-review op, prefilled |
 * | yes         | no           | *                       | EMPTY needs-review op |
 * | no          | *            | *                       | set aside, NO op   |
 *
 * "Bank domain" is the verified signing domain OR, failing that, the claimed
 * `From:` — a claimed-only match is enough to earn a review card (the message is
 * worth showing a human) and NEVER enough to file one, because gate 2 below reads
 * the VERIFIED domain and nothing else. That ordering is the same one
 * {@link domainsToTry} keeps for template candidacy: matching is not believing.
 *
 * A template that hits but whose amount the money checker refuses (zero,
 * negative, over-precise) is treated as a miss — the safe direction — and the
 * message becomes an empty needs-review op.
 */
function disposeMessage(args: AuthorArgs): Disposition {
  const { bytes, ingestId, messageId, senders, templates, bank, deps, now, receivedAt } = args;
  // The HEADER BLOCK, not the whole message — see {@link headerBlock}.
  const headers = headerBlock(webPlatform.utf8Decode(bytes));

  // Gate 1: Gmail's own Authentication-Results verdict (D4).
  const trusted = gmailVerdict(headers).reason === "pass";
  // Gate 2: the verified domain is on the account's mailbox sender list (D6).
  const domain = verifiedDomain(headers);
  const listed = domain !== null && senderListed(domain, senders);

  // Gate 3: a template-tier parse hit (D6). Runs regardless of the other gates —
  // its extraction is what a no-review op's money comes from.
  let norm: NormalizeResult | null = null;
  try {
    norm = normalize(CURRENT_VERSION, bytes, receivedAt);
  } catch {
    norm = null;
  }

  // Before any of that matters: is this plausibly a bank at all? A message from
  // a domain no template names and this account has not trusted becomes NO op —
  // see the file header for why that is not a silent drop.
  const domains = domainsToTry(domain, norm?.from ?? "");
  if (!domains.some((d) => isBankDomain(d, bank))) {
    return {
      kind: "set_aside",
      record: {
        message_id: messageId,
        domain: domains[0] ?? "",
        subject: norm?.subject ?? "",
        receivedAt,
      },
    };
  }

  const hit = norm === null ? null : firstTemplateHit(norm, templates, domains);

  // A template read the message: KEEP what it extracted, whatever the trust
  // gates said. The gates decide whether it files itself, not whether the user
  // is allowed to see the amount.
  //
  // This used to require all three gates before the extraction was kept, and
  // threw it away otherwise — which made the first backfill of any mailbox emit
  // nothing but empty cards, because gate 2 is the account's sender list and a
  // new account's list is EMPTY by construction. Every message "failed to
  // parse" until a sender was trusted, and trusting one did not go back and fix
  // the cards already written. An unconfirmed extraction is a form PREFILL the
  // human verifies — the held-mail lane's model exactly (`heldMessage.ts`: "no
  // machine believes it, the human is the verifier") — so it belongs on the
  // card. Auto-filing, which no human checks, still needs all three gates.
  if (hit !== null && norm !== null) {
    const draft = draftFromExtraction(hit.extraction, norm.emailDate);
    const built = manualTxnPayload(draft, MAILBOX_ENTRY_METHOD);
    if (built.ok) {
      const filesItself = trusted && listed;
      const payload = {
        ...built.payload,
        // The flag that actually keeps a row off the deck (D6a). Only a message
        // that passed every gate skips review.
        needs_review: !filesItself,
        tier: "template",
        provenance: provenanceOf(deps.grantId, messageId),
      };
      return { kind: "op", spec: txnSpec(deps.newID(), ingestId, payload), review: !filesItself };
    }
    // Template hit but the amount is unusable: fall through to the empty card.
  }

  // Empty needs-review op: no amount, no currency, no direction, no body text on
  // the hot stream (D5). The review card re-fetches the message by provenance id.
  const emailDay = norm === null ? null : norm.emailDate;
  const payload = {
    unparsed: true,
    needs_review: true,
    entry_method: MAILBOX_ENTRY_METHOD,
    posted_at: dayInstant(emailDay, now),
    merchant_raw: "",
    last4: "",
    category: null,
    provenance: provenanceOf(deps.grantId, messageId),
  };
  return { kind: "op", spec: txnSpec(deps.newID(), ingestId, payload), review: true };
}

/** The domains a template may be tried against: the verified one, and the claimed From. */
function domainsToTry(verified: string | null, from: string): string[] {
  const out = new Set<string>();
  if (verified !== null) out.add(verified);
  const claimed = domainOf(from);
  if (claimed !== "") out.add(claimed);
  return [...out];
}

/** The first candidate template that matches, validates and produced an amount. */
function firstTemplateHit(
  norm: NormalizeResult,
  templates: readonly Definition[],
  domains: readonly string[],
): { def: Definition; extraction: Extraction } | null {
  for (const def of candidateTemplates(templates, domains)) {
    try {
      const extraction = compileDefinition(def).execute(norm.subject, norm.text);
      if (!extraction.matched) continue;
      if (validateExtraction(extraction, def) !== "") continue;
      // No amount means no money to carry into a no-review op.
      if (!produced(extraction, "amount")) continue;
      return { def, extraction };
    } catch {
      // A definition this build cannot run, or a pattern outside the dialect.
      continue;
    }
  }
  return null;
}

/**
 * Whether a proven domain is on the account's sender list — exactly, or as a
 * subdomain of a listed domain (`alerts.dib.ae` is `dib.ae`'s), mirroring how
 * `internal/origin` treats a verified domain. Both sides are already lower-cased
 * bare domains (the server validates the list; `verifiedDomain` returns one).
 */
function senderListed(domain: string, senders: readonly string[]): boolean {
  return senders.some((s) => domain === s || domain.endsWith(`.${s}`));
}

/** The domain half of an address, lower-cased, or `""`. */
function domainOf(address: string): string {
  const at = address.lastIndexOf("@");
  return at < 0 ? "" : address.slice(at + 1).trim().toLowerCase().replace(/[>\s]+$/, "");
}

function provenanceOf(grantId: string, messageId: string): MailboxProvenance {
  return { provider: "gmail", grant_id: grantId, message_id: messageId };
}

function txnSpec(id: string, ingestId: string, payload: Record<string, unknown>): OpSpec {
  return {
    type: "txn_ingested",
    entity: { kind: "txn", id },
    parentVersion: null,
    ingestId,
    payload,
  };
}

/**
 * A canonical midnight-UTC instant for a review op's `posted_at` — the field is
 * required and must decode, so it is built from a VALIDATED day and never handed
 * the raw email date, whose format the fold would then have to trust. An
 * unparseable candidate falls back to today (UTC), the same shape manual entry
 * uses.
 */
function dayInstant(candidate: string | null, now: Date): string {
  return `${safeDay(candidate, now)}T00:00:00.000Z`;
}

function safeDay(candidate: string | null, now: Date): string {
  if (candidate !== null && candidate !== "") {
    const d = new Date(candidate);
    if (!Number.isNaN(d.getTime())) return d.toISOString().slice(0, 10);
  }
  return now.toISOString().slice(0, 10);
}

/**
 * The RFC3339 received time from Gmail's `internalDate` (ms since epoch).
 *
 *   - Absent (`""`) ⇒ now: a missing internalDate is not an error, just no date.
 *   - Present but garbage or out of the Date range ⇒ `null`: the caller routes
 *     THAT message to the unreadable path (reason `bad_date`). `new Date(ms)`
 *     with a huge ms yields an Invalid Date whose `toISOString()` throws a
 *     `RangeError`, which would otherwise stall the whole lane permanently — so
 *     it is caught here and turned into a per-message miss, never a cycle throw.
 */
function receivedAtOf(internalDate: string, now: Date): string | null {
  if (internalDate === "") return now.toISOString();
  const ms = Number(internalDate);
  if (!Number.isFinite(ms) || ms <= 0) return null;
  const d = new Date(ms);
  if (Number.isNaN(d.getTime())) return null;
  try {
    return d.toISOString();
  } catch {
    return null;
  }
}

/** The `internalDate` record field, present only when Gmail gave one. */
function internalDateField(internalDate: string): { internalDate?: string } {
  return internalDate === "" ? {} : { internalDate };
}

/** True for the broker's account-full refusal (413 `account_full`). */
function isAccountFull(err: unknown): boolean {
  return err instanceof ApiError && err.status === 413 && err.code === "account_full";
}

// ---------------------------------------------------------------------------
// Liveness (spec D8, brief Step 5)
// ---------------------------------------------------------------------------

/** What the while-open scheduler needs. Injected so the cadence is testable. */
export interface MailboxLivenessDeps {
  /**
   * Whether this device holds a usable sealed token — i.e. it is the holder
   * (D9). Non-holder devices have none and must NEVER fetch; a device whose
   * token is a shared-browser residual is not a holder either, so an
   * implementation resolves `false` rather than surfacing that as fetchable.
   */
  hasSealedToken(): Promise<boolean>;
  /** Runs one cycle. Never rejects (see {@link runFetchCycle}). */
  runCycle(): Promise<CycleReport>;
  /** The while-open interval in ms. Defaults to 60s (the held-mail precedent). */
  intervalMs?: number;
  /** Injected for tests; default the globals. The handle is opaque to this module. */
  setInterval?: (fn: () => void, ms: number) => unknown;
  clearInterval?: (handle: unknown) => void;
}

/**
 * Starts fetching on the holder device: one cycle at ready-state boot, then one
 * on a while-open interval, each gated on a sealed token being present. Returns a
 * stop function. A device with no token never runs a cycle — the gate is checked
 * before boot and before every tick, so a token that appears (a connect) or
 * disappears (a disconnect) is picked up without restarting the scheduler.
 */
export function startMailboxLiveness(deps: MailboxLivenessDeps): () => void {
  const intervalMs = deps.intervalMs ?? 60_000;
  const setIntervalFn: (fn: () => void, ms: number) => unknown =
    deps.setInterval ?? ((fn, ms) => setInterval(fn, ms));
  const clearIntervalFn: (handle: unknown) => void =
    deps.clearInterval ?? ((h) => clearInterval(h as ReturnType<typeof setInterval>));

  let running = false;
  let stopped = false;

  const tick = async (): Promise<void> => {
    if (stopped || running) return; // never overlap cycles
    running = true;
    try {
      if (await deps.hasSealedToken()) await deps.runCycle();
    } catch {
      // hasSealedToken can throw on a residual row; a cycle that could not even
      // check its token is not a fetch, and must not take out the scheduler.
    } finally {
      running = false;
    }
  };

  void tick(); // boot
  const handle = setIntervalFn(() => void tick(), intervalMs);

  return () => {
    stopped = true;
    clearIntervalFn(handle);
  };
}
