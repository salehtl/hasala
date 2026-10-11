/**
 * The fetch lane's non-secret bookkeeping: the Gmail `historyId` checkpoint and
 * the chosen backfill window, kept beside the sealed refresh token (spec §2.2).
 *
 * # Why it lives in the token's store and not the op log
 *
 * D5 forbids cold rows for this lane — the burner mailbox itself is the durable
 * raw store — so the checkpoint is device-local progress, not shared state, and
 * it has no place in the append-only log every device folds. It rides in the
 * SAME injectable {@link KeyStore} the sealed token uses (`mailboxToken.ts`), in
 * its own sibling row {@link MAILBOX_STATE_ROW}, so a disconnect that sweeps the
 * token row can sweep this one too and a device that never connected simply has
 * neither.
 *
 * # Nothing here is a secret, and nothing here is sealed
 *
 * A `historyId` is an opaque Gmail cursor, the backfill window is a number of
 * days, and the last-cycle time is a clock reading — none is content, none is a
 * credential, so this row is stored in the clear. That is the whole reason it is
 * a separate row from the token rather than more bytes under the same seal: the
 * seal exists for the refresh token, and widening it to cover a cursor would be
 * ceremony with no threat behind it.
 *
 * # A missing or unreadable row reads as "start from a backfill", never a throw
 *
 * {@link readMailboxState} always returns a usable state: an absent row (a
 * mailbox connected before this field existed, or a fresh connect that has not
 * run a cycle yet) and a row this build cannot parse both degrade to
 * `historyId: null`, which the fetch cycle answers with a full backfill within
 * the window — safe under ingest-id dedup (D5). It never throws, because a fetch
 * lane that crashed on its own bookkeeping would strand the holder device.
 */

import {
  browserMailboxTokenStore,
  type KeyStore,
} from "../mailboxToken";

/**
 * The row the checkpoint lives in — a sibling of the token's
 * {@link MAILBOX_TOKEN_ROW} in the same object store, never the account row.
 * A storage identity in its own right once shipped (see CLAUDE.md): renaming it
 * makes every connected device re-backfill on its next cycle.
 */
export const MAILBOX_STATE_ROW = "mailbox-state";

/**
 * The backfill windows the connect ceremony offers (spec D11: 30/90/365 days).
 * The fetch lane reads whichever the user chose; a state row that names another
 * number is honoured as-is (it is the user's own past choice), so this list is
 * the offer, not a validator.
 */
export const BACKFILL_WINDOWS = [30, 90, 365] as const;

/** The window used when no row records one — the smallest offered (spec D11). */
export const DEFAULT_BACKFILL_DAYS = 30;

/**
 * Why a message could not be read into an op. A small, closed set — never body
 * text, because this is persisted and surfaced.
 *   - `over_cap`     — larger than the SMTP size cap; usually a huge non-txn mail.
 *   - `undecodable`  — the strict base64url decoder refused the raw body.
 *   - `bad_date`     — Gmail's internalDate was out of range or unparseable.
 *   - `gone`         — Gmail refused to serve the message PERMANENTLY: a 404/410
 *                      (deleted or purged between the list and the download) or a
 *                      2xx that carried no `raw` body at all. Unlike the other
 *                      three this one is NOT still in the mailbox, so it is the
 *                      one reason the "they are still in your mailbox" copy on the
 *                      health surfaces does not cover; it is recorded here anyway
 *                      because the alternative is the defect this reason exists to
 *                      kill — a single undeliverable message wedging the lane and
 *                      re-failing the same page every 60 seconds, forever.
 */
export type UnreadableReason = "over_cap" | "undecodable" | "bad_date" | "gone";

/** One message the lane could not read, recorded durably for the health surface. */
export interface UnreadableRecord {
  message_id: string;
  reason: UnreadableReason;
  /** Gmail's internalDate (ms-epoch string) when it had one; `""` otherwise. */
  internalDate?: string;
}

/**
 * The durable tally of messages that couldn't be read (spec §2.2, plan-owner
 * ruling): a cumulative distinct `count` plus a bounded ring of the most recent
 * records. No op is authored for these — an undecodable body cannot be
 * re-derived and an over-cap one is usually huge non-transaction mail that would
 * flood the review deck — so this is what keeps "N messages couldn't be read"
 * visible ACROSS sessions while the burner mailbox stays the durable copy (D5).
 */
export interface UnreadableLog {
  /** Distinct messages that couldn't be read, cumulative. May exceed the ring. */
  count: number;
  /** The most recent {@link MAX_UNREADABLE_RECENT}, oldest first. */
  recent: UnreadableRecord[];
}

/** The ring bound: the record can never grow unbounded (plan-owner ruling). */
export const MAX_UNREADABLE_RECENT = 50;

/** The empty unreadable log. */
export function emptyUnreadableLog(): UnreadableLog {
  return { count: 0, recent: [] };
}

/**
 * Folds one unreadable record into the log, idempotently by `message_id`.
 *
 * A message already in the ring is not counted or added again — a backfill that
 * re-lists messages, or a budget-halted page re-processed on resume, must not
 * inflate the count. Pure: returns a new log.
 */
export function recordUnreadable(log: UnreadableLog, rec: UnreadableRecord): UnreadableLog {
  if (log.recent.some((r) => r.message_id === rec.message_id)) return log;
  const recent = [...log.recent, rec];
  return {
    count: log.count + 1,
    recent: recent.length > MAX_UNREADABLE_RECENT ? recent.slice(recent.length - MAX_UNREADABLE_RECENT) : recent,
  };
}

// ---------------------------------------------------------------------------
// Set-aside: mail that was NOT imported because it is not from a bank domain
// ---------------------------------------------------------------------------

/**
 * One message the lane set aside: not plausibly from a bank, so no op was
 * authored for it (see `bankDomains.ts` for why an op would be irreversible and
 * this is not). Device-local, never pushed anywhere — the server holds no part of
 * this and could not read it if it did.
 *
 * The subject IS carried, deliberately and only here: the user cannot judge "is
 * this my bank?" from a domain alone, and this row never leaves the device. It is
 * truncated to {@link MAX_SET_ASIDE_SUBJECT} so no single message can bloat the
 * row.
 */
export interface SetAsideRecord {
  message_id: string;
  /** The verified (or, failing that, claimed) sender domain; `""` when neither. */
  domain: string;
  /** The message subject, truncated. Device-local only. */
  subject: string;
  /** When it arrived in the mailbox, ISO-8601. */
  receivedAt: string;
}

/** The ring bound: this row can never grow unbounded (plan-owner ruling). */
export const MAX_SET_ASIDE_RECENT = 200;

/** The longest subject a set-aside record stores. */
export const MAX_SET_ASIDE_SUBJECT = 120;

/**
 * The durable record of set-aside mail. `count` is every distinct message set
 * aside; `recent` is the newest {@link MAX_SET_ASIDE_RECENT} of them; `dropped` is
 * how many fell off the ring — surfaced honestly rather than pretending the list
 * is complete.
 */
export interface SetAsideLog {
  count: number;
  dropped: number;
  /** The most recent {@link MAX_SET_ASIDE_RECENT}, oldest first. */
  recent: SetAsideRecord[];
}

/** The empty set-aside log. */
export function emptySetAsideLog(): SetAsideLog {
  return { count: 0, dropped: 0, recent: [] };
}

/**
 * Folds one set-aside record into the log, idempotently by `message_id` — a
 * backfill that re-lists a message, or a page re-processed after a halt, must not
 * inflate the count. Pure: returns a new log.
 */
export function recordSetAside(log: SetAsideLog, rec: SetAsideRecord): SetAsideLog {
  if (log.recent.some((r) => r.message_id === rec.message_id)) return log;
  const recent = [...log.recent, { ...rec, subject: rec.subject.slice(0, MAX_SET_ASIDE_SUBJECT) }];
  const over = Math.max(0, recent.length - MAX_SET_ASIDE_RECENT);
  return {
    count: log.count + 1,
    dropped: log.dropped + over,
    recent: over === 0 ? recent : recent.slice(over),
  };
}

/**
 * Drops a domain's entries after the user has said "this is my bank" and the
 * lane has re-fetched and authored them. The count comes down with the entries:
 * they are no longer set aside, they are imported. Subdomains go with their
 * parent, matching how the domain was trusted.
 */
export function forgetSetAsideDomain(log: SetAsideLog, domain: string): SetAsideLog {
  const keep = log.recent.filter((r) => !(r.domain === domain || r.domain.endsWith(`.${domain}`)));
  return { count: log.count - (log.recent.length - keep.length), dropped: log.dropped, recent: keep };
}

/** The fetch lane's device-local progress. */
export interface MailboxState {
  /**
   * The Gmail `historyId` this device has accounted every message up to, or
   * `null` for "never synced" — which the fetch cycle answers with a full
   * backfill within {@link backfillDays}. Advanced only after a page's every
   * message is accounted (spec §2.2).
   */
  historyId: string | null;
  /** How many days back the initial/gap-resync backfill reaches. */
  backfillDays: number;
  /** When the last cycle completed, ISO-8601, or `null`. For the health surface. */
  lastCycleAt: string | null;
  /** Messages that couldn't be read, durably recorded for the health surface. */
  unreadable: UnreadableLog;
  /**
   * Mail that was NOT imported because it did not come from a bank domain — no
   * op was authored for any of it. Absent on a row written before this existed,
   * which reads as an empty log.
   */
  setAside?: SetAsideLog;
  /**
   * The connected burner address, decoded CLIENT-side from the connect
   * ceremony's id_token (`mailboxConnect.emailFromIdToken`) and kept here so the
   * settings drill-in can show "Connected as …" without a server read — the
   * server never reads the email claim (spec §3, D6a) and holds no key to.
   *
   * Not a secret and not sealed, exactly like the rest of this row: it is the
   * user's own mailbox address, the same disclosure class as the cleartext
   * inbound address the forwarding lane caches in `LocalOnboardingRecord`. Absent
   * or `""` when the token carried no email claim — the label degrades to
   * "Mailbox connected" (`connectedLabel`), never "Connected as " with a blank.
   */
  connectedEmail?: string | null;
  /**
   * A backfill that has more pages to read, or `null` when none is in progress.
   *
   * A backfill over a real mailbox is thousands of messages, and reading them
   * all in one cycle is minutes of a spinner with nothing to show for it. So a
   * cycle reads ONE page and parks the rest here: `head` is the `historyId`
   * captured before the first page (adopted only once the last page is
   * accounted, so a message that lands mid-backfill is not skipped), and
   * `pageToken` is where the next cycle resumes. While this is set,
   * `historyId` stays as it was — the backfill is not finished, and nothing may
   * claim it is.
   */
  backfill?: BackfillCursor | null;
}

/** Where an unfinished backfill resumes, and the checkpoint it will adopt. */
export interface BackfillCursor {
  /** The `historyId` captured before the first page; adopted when the last lands. */
  head: string;
  /** Gmail's `pageToken` for the next page of the same query. */
  pageToken: string;
}

/** The default a fresh or unreadable row yields. */
function freshState(): MailboxState {
  return {
    historyId: null,
    backfillDays: DEFAULT_BACKFILL_DAYS,
    lastCycleAt: null,
    unreadable: emptyUnreadableLog(),
  };
}

/**
 * Refuses a row that is not a well-formed state rather than half-reading one.
 *
 * A partial row (or the account/token row, which share this store and have a
 * different shape) reads as "no state" — i.e. a backfill — instead of producing
 * a `historyId` of `undefined` much further away in the fetch cycle.
 */
function decodeState(v: unknown): MailboxState | null {
  if (typeof v !== "object" || v === null) return null;
  const r = v as Record<string, unknown>;
  const historyId = r["historyId"];
  if (historyId !== null && (typeof historyId !== "string" || historyId === "")) return null;
  const backfillDays = r["backfillDays"];
  if (typeof backfillDays !== "number" || !Number.isInteger(backfillDays) || backfillDays <= 0) return null;
  const lastCycleAt = r["lastCycleAt"];
  if (lastCycleAt !== null && typeof lastCycleAt !== "string") return null;
  // Absent or malformed reads as null: an older row predates the field, and a
  // blank email only degrades the label — it never refuses the whole state.
  const rawEmail = r["connectedEmail"];
  const connectedEmail = typeof rawEmail === "string" ? rawEmail : null;
  return {
    historyId,
    backfillDays,
    lastCycleAt,
    unreadable: decodeUnreadable(r["unreadable"]),
    setAside: decodeSetAside(r["setAside"]),
    connectedEmail,
    backfill: decodeBackfill(r["backfill"]),
  };
}

/**
 * The set-aside log from a stored row. Tolerant in the same direction as
 * {@link decodeUnreadable}: an absent field (a row written before this existed) or
 * a malformed one degrades to empty rather than discarding the whole state. The
 * cost of a lost set-aside log is that the next cycle re-records what it sees;
 * the cost of a discarded state is a full re-backfill.
 */
function decodeSetAside(v: unknown): SetAsideLog {
  if (typeof v !== "object" || v === null) return emptySetAsideLog();
  const r = v as Record<string, unknown>;
  const count = r["count"];
  if (typeof count !== "number" || !Number.isInteger(count) || count < 0) return emptySetAsideLog();
  const rawDropped = r["dropped"];
  const dropped = typeof rawDropped === "number" && Number.isInteger(rawDropped) && rawDropped >= 0 ? rawDropped : 0;
  const rawRecent = r["recent"];
  if (!Array.isArray(rawRecent)) return emptySetAsideLog();
  const recent: SetAsideRecord[] = [];
  for (const raw of rawRecent) {
    if (typeof raw !== "object" || raw === null) continue;
    const rec = raw as Record<string, unknown>;
    const id = rec["message_id"];
    if (typeof id !== "string" || id === "") continue;
    const domain = rec["domain"];
    const subject = rec["subject"];
    const receivedAt = rec["receivedAt"];
    recent.push({
      message_id: id,
      domain: typeof domain === "string" ? domain : "",
      subject: typeof subject === "string" ? subject.slice(0, MAX_SET_ASIDE_SUBJECT) : "",
      receivedAt: typeof receivedAt === "string" ? receivedAt : "",
    });
  }
  return { count, dropped, recent: recent.slice(-MAX_SET_ASIDE_RECENT) };
}

/**
 * Absent or malformed reads as "no backfill in progress" — an older row predates
 * the field, and a half-written cursor must restart the backfill rather than
 * resume from a page token nothing can vouch for. Restarting is safe: ingest-id
 * dedup means a re-read message authors no second op.
 */
function decodeBackfill(v: unknown): BackfillCursor | null {
  if (typeof v !== "object" || v === null) return null;
  const r = v as Record<string, unknown>;
  const head = r["head"];
  const pageToken = r["pageToken"];
  if (typeof head !== "string" || head === "") return null;
  if (typeof pageToken !== "string" || pageToken === "") return null;
  return { head, pageToken };
}

/**
 * The unreadable log from a stored row. Tolerant: an absent field (a row written
 * before this existed) or a malformed one degrades to empty rather than
 * discarding the whole state — a lost checkpoint is a re-backfill, a heavier
 * price than a reset unreadable tally.
 */
function decodeUnreadable(v: unknown): UnreadableLog {
  if (typeof v !== "object" || v === null) return emptyUnreadableLog();
  const r = v as Record<string, unknown>;
  const count = r["count"];
  if (typeof count !== "number" || !Number.isInteger(count) || count < 0) return emptyUnreadableLog();
  const rawRecent = r["recent"];
  if (!Array.isArray(rawRecent)) return emptyUnreadableLog();
  const recent: UnreadableRecord[] = [];
  for (const raw of rawRecent) {
    if (typeof raw !== "object" || raw === null) continue;
    const rec = raw as Record<string, unknown>;
    const id = rec["message_id"];
    const reason = rec["reason"];
    if (typeof id !== "string" || id === "") continue;
    if (reason !== "over_cap" && reason !== "undecodable" && reason !== "bad_date" && reason !== "gone") continue;
    const internalDate = rec["internalDate"];
    recent.push({
      message_id: id,
      reason,
      ...(typeof internalDate === "string" ? { internalDate } : {}),
    });
  }
  return { count, recent: recent.slice(-MAX_UNREADABLE_RECENT) };
}

/**
 * Reads the fetch lane's state, defaulting an absent or unreadable row to a
 * backfill. Never throws.
 */
export async function readMailboxState(store: KeyStore = browserMailboxTokenStore()): Promise<MailboxState> {
  let raw: unknown;
  try {
    raw = await store.get(MAILBOX_STATE_ROW);
  } catch {
    return freshState();
  }
  return decodeState(raw) ?? freshState();
}

/** Writes the fetch lane's state to its row. */
export async function writeMailboxState(
  state: MailboxState,
  store: KeyStore = browserMailboxTokenStore(),
): Promise<void> {
  // Every field the state carries, listed explicitly — including `backfill`,
  // which this write used to omit. `satisfies MailboxState` could not catch it
  // (the field is optional), so an unfinished backfill's resume cursor was thrown
  // away on every write and a multi-page backfill re-read page one forever,
  // never advancing the checkpoint. `setAside` is written here for the same
  // reason its accounting sits behind the same barrier: it advances with the
  // checkpoint, or not at all.
  await store.put(MAILBOX_STATE_ROW, {
    historyId: state.historyId,
    backfillDays: state.backfillDays,
    lastCycleAt: state.lastCycleAt,
    unreadable: state.unreadable,
    setAside: state.setAside ?? emptySetAsideLog(),
    connectedEmail: state.connectedEmail ?? null,
    backfill: state.backfill ?? null,
  } satisfies MailboxState);
}

/**
 * The durable unreadable tally, for Task 15's mailbox health surface. Reads the
 * persisted state, so it survives sessions and reflects what the last accounted
 * cycle recorded. Never throws.
 */
export async function readMailboxUnreadable(store: KeyStore = browserMailboxTokenStore()): Promise<UnreadableLog> {
  return (await readMailboxState(store)).unreadable;
}

/**
 * Sweeps the fetch lane's state row — the checkpoint, the backfill window, the
 * unreadable tally, and the client-held {@link MailboxState.connectedEmail}.
 *
 * The sibling sweep this module's header promised: a disconnect deletes
 * {@link MAILBOX_TOKEN_ROW} (via `deleteMailboxToken`) and MUST delete this row
 * too, or the connected address, historyId and unreadable count outlive the
 * connection they describe — a stale "Connected as …" the next connect would then
 * have to overwrite, and a checkpoint a re-connect would resume from wrongly.
 * Deletes {@link MAILBOX_STATE_ROW} by key only, never the token or account rows;
 * a device that never connected simply has neither. Task 17 (deletion) reuses the
 * same disconnect path, so this is where account-scoped mailbox state is cleared.
 */
export async function deleteMailboxState(store: KeyStore = browserMailboxTokenStore()): Promise<void> {
  await store.delete(MAILBOX_STATE_ROW);
}
