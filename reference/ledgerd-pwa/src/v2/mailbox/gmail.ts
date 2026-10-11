/**
 * The narrow Gmail REST surface the fetch lane needs, and its live driver
 * (spec §2.2, D2).
 *
 * # Only the three paths the CSP allows, and history is FLAT
 *
 * Task 5 loosened `connect-src` to exactly `messages`, `messages/`, `history`
 * and `profile` under `https://gmail.googleapis.com/gmail/v1/users/me` — the
 * `/upload/` tree and every other Google API stay refused. This driver reaches
 * only those paths. `history.list` is the one that bites: it is a FLAT
 * `GET .../users/me/history` with no trailing path segment, and CSP3 prefix
 * matching would never let `.../history/` match it — so the source (and this
 * URL) must be the bare `.../history`, no slash. Get that wrong and the one
 * fetch that drives catch-up is silently blocked.
 *
 * # The raw bytes are the whole point
 *
 * `messages.get?format=raw` returns the RFC822 message base64url-encoded and
 * UNPADDED. The fetch lane hashes the DECODED bytes for the ingest id, so this
 * driver hands back the base64url string untouched and lets the caller decode it
 * with the strict {@link Platform.fromBase64Url} — a lenient decode that skipped
 * a stray character would move the sha256 to a different message.
 *
 * # This driver never retries and never interprets
 *
 * A non-ok answer becomes a typed error and stops; the retry is the fetch lane's
 * next cycle (the pushv2 house style). The one answer it reads for meaning is a
 * `404` on `history.list`, which is Gmail saying the `startHistoryId` is older
 * than it retains — a {@link GmailHistoryGapError} the cycle answers with a full
 * backfill (spec §2.2).
 */

/** The one host and base path the CSP admits. */
const GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me";

/** A message reference — an id and nothing more; the body is a separate fetch. */
export interface GmailMessageRef {
  id: string;
}

/** One page of `history.list`: the message ids added, the cursor, the next page. */
export interface GmailHistoryPage {
  /** Message ids added since the requested `startHistoryId`, de-duplicated. */
  added: string[];
  /** The mailbox `historyId` as of this response — the checkpoint to advance to. */
  historyId: string;
  /** The token for the next page, or `undefined` when this was the last. */
  nextPageToken?: string;
}

/** One page of `messages.list`. */
export interface GmailMessagesPage {
  messages: GmailMessageRef[];
  nextPageToken?: string;
}

/** A message fetched raw: its id and the base64url RFC822 body, undecoded. */
export interface GmailRawMessage {
  id: string;
  /** base64url, unpadded — decode with the strict `fromBase64Url` seam. */
  rawBase64Url: string;
  /**
   * Gmail's `internalDate` — milliseconds since the epoch as a string, when the
   * message arrived in the mailbox. The normalizer reads no top-level `Date:`
   * header (only an inner forwarded one), so this is the received time a
   * backfilled message is dated by; `""` when Gmail omitted it.
   */
  internalDate: string;
}

/**
 * The mailbox's current `historyId`, read from `users.me.profile` — the head
 * captured BEFORE authoring so a backfill's checkpoint cannot skip a message
 * that arrives during it (spec §2.2, sync-to-head).
 */
export interface GmailProfile {
  historyId: string;
}

/** Gmail said the `startHistoryId` is too old to serve — trigger a full resync. */
export class GmailHistoryGapError extends Error {
  override readonly name = "GmailHistoryGapError";
  constructor(readonly startHistoryId: string) {
    super(`gmail no longer retains history since ${startHistoryId}; a full resync is required`);
  }
}

/** Any other non-ok Gmail answer. Generic on purpose — the cycle retries next time. */
export class GmailApiError extends Error {
  override readonly name = "GmailApiError";
  constructor(
    readonly status: number,
    what: string,
  ) {
    super(`${what}: gmail answered ${status}`);
  }
}

/** The Gmail operations the fetch lane calls. A fake satisfies it in tests. */
export interface GmailApi {
  /** The current mailbox `historyId` (`users.me.profile`). */
  profile(): Promise<GmailProfile>;
  /**
   * One page of message ids added since `startHistoryId`. Throws
   * {@link GmailHistoryGapError} on a 404 (the cursor aged out).
   */
  historyList(startHistoryId: string, pageToken?: string): Promise<GmailHistoryPage>;
  /**
   * One page of message ids matching `q` (e.g. `newer_than:30d`).
   *
   * The request always sets `includeSpamTrash=true`; the *query* is what narrows
   * it (see `bankDomains.ts`, which appends `-in:trash`). Spam is deliberately
   * IN: forwarded bank mail fails SPF at the forwarding hop, which is exactly the
   * signal Gmail spam-files on, and a probe run against this project's own burner
   * landed in Spam. Without the flag a spam-filed bank message is invisible to
   * backfill forever, while `users.history.list` — which surfaces spam with no
   * flag at all — sees it, so the two paths disagreed about what is in the
   * mailbox.
   */
  messagesList(q: string, pageToken?: string): Promise<GmailMessagesPage>;
  /** One message's raw RFC822 body, base64url-encoded. */
  getRaw(id: string): Promise<GmailRawMessage>;
}

function isNonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v !== "";
}

/**
 * The live driver over the global `fetch`, authorised by `accessToken`.
 *
 * `doFetch` is injected only so the harness can serve fixtures; production is
 * the browser's `fetch`, which the CSP fences to the allowed paths.
 */
export function gmailRest(accessToken: string, doFetch: typeof fetch = fetch): GmailApi {
  const get = async (url: string): Promise<Response> => {
    return doFetch(url, {
      method: "GET",
      headers: { Authorization: `Bearer ${accessToken}` },
    });
  };

  const readJson = async (res: Response): Promise<Record<string, unknown>> => {
    const parsed = JSON.parse(await res.text()) as unknown;
    return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : {};
  };

  return {
    async profile(): Promise<GmailProfile> {
      const res = await get(`${GMAIL_BASE}/profile`);
      if (!res.ok) throw new GmailApiError(res.status, "mailbox profile");
      const body = await readJson(res);
      const historyId = body["historyId"];
      if (!isNonEmptyString(historyId)) throw new GmailApiError(res.status, "mailbox profile returned no historyId");
      return { historyId };
    },

    async historyList(startHistoryId: string, pageToken?: string): Promise<GmailHistoryPage> {
      const params = new URLSearchParams({ startHistoryId, historyTypes: "messageAdded" });
      if (pageToken !== undefined) params.set("pageToken", pageToken);
      // FLAT path, no trailing slash — see the header. The query string does not
      // add a path segment, so the CSP source `.../history` still matches.
      const res = await get(`${GMAIL_BASE}/history?${params.toString()}`);
      if (res.status === 404) throw new GmailHistoryGapError(startHistoryId);
      if (!res.ok) throw new GmailApiError(res.status, "mailbox history");
      const body = await readJson(res);
      const historyId = body["historyId"];
      if (!isNonEmptyString(historyId)) throw new GmailApiError(res.status, "mailbox history returned no historyId");
      const seen = new Set<string>();
      const added: string[] = [];
      const history = Array.isArray(body["history"]) ? (body["history"] as unknown[]) : [];
      for (const entry of history) {
        if (typeof entry !== "object" || entry === null) continue;
        const messagesAdded = (entry as Record<string, unknown>)["messagesAdded"];
        if (!Array.isArray(messagesAdded)) continue;
        for (const m of messagesAdded) {
          if (typeof m !== "object" || m === null) continue;
          const msg = (m as Record<string, unknown>)["message"];
          if (typeof msg !== "object" || msg === null) continue;
          const id = (msg as Record<string, unknown>)["id"];
          if (isNonEmptyString(id) && !seen.has(id)) {
            seen.add(id);
            added.push(id);
          }
        }
      }
      const nextPageToken = body["nextPageToken"];
      return {
        added,
        historyId,
        ...(isNonEmptyString(nextPageToken) ? { nextPageToken } : {}),
      };
    },

    async messagesList(q: string, pageToken?: string): Promise<GmailMessagesPage> {
      // `includeSpamTrash` is ON and the exclusion lives in `q` — see the
      // interface doc. Trash is excluded there rather than here so the decision
      // is one string a reader can see, instead of a boolean here silently
      // undoing a query term there.
      const params = new URLSearchParams({ q, includeSpamTrash: "true" });
      if (pageToken !== undefined) params.set("pageToken", pageToken);
      const res = await get(`${GMAIL_BASE}/messages?${params.toString()}`);
      if (!res.ok) throw new GmailApiError(res.status, "mailbox messages");
      const body = await readJson(res);
      const messages: GmailMessageRef[] = [];
      const raw = Array.isArray(body["messages"]) ? (body["messages"] as unknown[]) : [];
      for (const m of raw) {
        if (typeof m !== "object" || m === null) continue;
        const id = (m as Record<string, unknown>)["id"];
        if (isNonEmptyString(id)) messages.push({ id });
      }
      const nextPageToken = body["nextPageToken"];
      return { messages, ...(isNonEmptyString(nextPageToken) ? { nextPageToken } : {}) };
    },

    async getRaw(id: string): Promise<GmailRawMessage> {
      const res = await get(`${GMAIL_BASE}/messages/${encodeURIComponent(id)}?format=raw`);
      if (!res.ok) throw new GmailApiError(res.status, "mailbox message");
      const body = await readJson(res);
      const raw = body["raw"];
      if (!isNonEmptyString(raw)) throw new GmailApiError(res.status, "mailbox message returned no raw body");
      const internalDate = body["internalDate"];
      return { id, rawBase64Url: raw, internalDate: isNonEmptyString(internalDate) ? internalDate : "" };
    },
  };
}
