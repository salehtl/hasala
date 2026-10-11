/**
 * The client half of the Gmail mailbox connect ceremony (spec §2.1, Task 9).
 *
 * Three operations, each a thin, session-authenticated driver over the broker
 * routes `internal/api/mailbox.go` serves — this file holds NO credential of its
 * own beyond the session bearer the {@link V2Handle} already carries, and it
 * reaches Google only by opening a top-level consent popup, never with a fetch
 * (the CSP loosening in Task 5 is for Task 12's read lane, not for anything
 * here).
 *
 *   - {@link connectMailbox} runs the whole consent ceremony and lands a sealed
 *     refresh token.
 *   - {@link mintAccessToken} trades that sealed token for a short-lived access
 *     token, and turns the broker's one generic refusal into an honest,
 *     reconnect-or-not answer.
 *   - {@link disconnectMailbox} revokes at Google and forgets the token locally.
 *
 * # Why the claim code rides a BroadcastChannel, not window.opener
 *
 * The public listener serves `Cross-Origin-Opener-Policy: same-origin`, so a
 * consent popup that round-trips through accounts.google.com comes back with
 * `window.opener` severed (spec §2.1, and `cmd/ledgerd/main.go`'s COOP header).
 * `postMessage` to the opener is therefore impossible; the callback page
 * (`web/public/mailbox-callback.js`) broadcasts the claim code on an
 * origin-scoped {@link MAILBOX_CHANNEL} instead, which survives the
 * browsing-context-group switch. COOP is not weakened to make this work.
 *
 * The GET `/api/v1/mailbox/grant` poll is the popup-closed-early fallback the
 * same section names. Both of its answers are failures — it decides WHICH
 * failure, not whether to celebrate: no grant means the person closed the
 * window without consenting, a grant means the consent completed but the tokens
 * never reached this device. Neither leaves a refresh token here, so neither
 * can resolve. See {@link awaitClaim}.
 *
 * # The token custody contract this file must honour (Task 8, I-1)
 *
 * {@link openMailboxToken} returns `null` for NO row, but THROWS on a row that
 * is present and does not open — the shared-browser account-switch residual, or
 * corruption. {@link mintAccessToken} treats that throw exactly as its own
 * consumer contract prescribes: not an error banner and never "connected", but
 * "no usable token — reconnect", with {@link sweepMailboxLocal} sweeping the
 * residual first.
 *
 * # One sweep, not two deletes
 *
 * A mailbox connection is TWO rows: the sealed token, and the unsealed
 * `mailbox-state` row beside it (burner address, checkpoint, message-id ring).
 * Every path in this file that drops a connection goes through
 * {@link sweepMailboxLocal}, which drops both — a token swept without its state
 * row leaves another account's address in cleartext on a shared browser.
 */

import { webPlatform } from "@ledger/client/platform.web";

import { fromBase64Url, type V2Handle } from "./session";
import { deleteMailboxState } from "./mailbox/state";
import {
  deleteMailboxToken,
  type KeyStore,
  openMailboxToken,
  sealMailboxToken,
} from "./mailboxToken";

/**
 * The origin-scoped BroadcastChannel the callback page hands the claim code (or
 * a ceremony-over `error`) back on. Mirrored byte-for-byte in
 * `web/public/mailbox-callback.js`; a wire identity that is a protected string
 * once shipped (see CLAUDE.md) — renaming it strands every popup mid-ceremony.
 */
export const MAILBOX_CHANNEL = "ledger-v2-mailbox-connect";

// ---------------------------------------------------------------------------
// Typed failures (Tasks 12/14/15 consume these)
// ---------------------------------------------------------------------------

/**
 * Why a mailbox operation did not complete. A discriminated kind rather than a
 * boolean, and matched STRUCTURALLY ({@link isMailboxError}), for the reason
 * `session.ts`'s {@link PasskeyError} gives: a bundler that ends up with two
 * copies of this module makes `instanceof` fail silently.
 */
/**
 * Why a mailbox operation did not complete — and, for the three ways a connect
 * ceremony can end unfinished, exactly what the label is entitled to CLAIM.
 *
 * # Each kind's copy must be true every time that kind is returned
 *
 * These labels are what Tasks 14/15 write user-facing sentences from, so a kind
 * that is returned in a case its sentence does not describe is a lie the product
 * tells. The three unfinished-connect kinds are therefore separated by a fact
 * this module can PROVE, not by a story that sounds likely:
 *
 * The only `Grants.Upsert` in the server is inside the claim POST
 * (`internal/api/mailbox.go`), so a grant row can only have been created by a
 * claim that some client actually made. It follows that:
 *
 *   - a grant seen BEFORE the popup opens proves a mailbox was already connected
 *     to this account, and says nothing whatsoever about this ceremony;
 *   - a grant that is absent before and present after proves THIS ceremony's
 *     consent completed and its claim was spent somewhere other than here.
 *
 * That before/after snapshot is the whole reason {@link connectMailbox} reads
 * `GET /grant` before opening the window. Without it the two cases are
 * indistinguishable, and an earlier draft of this file had them inverted:
 * cancelling a RE-connect (a grant already there) was reported as "the mailbox
 * was authorised", which nothing in that flow had done.
 */
export type MailboxFailureKind =
  /**
   * This attempt did not finish, and it connected nothing.
   *
   * The floor of the three: it claims only that the ceremony ended incomplete.
   * Returned for an explicit user cancellation (the server's ceremony-over
   * `?error=`), for a window closed with no grant on either side of it, and
   * whenever the before/after snapshot could not be read — a kind that claims
   * nothing is the only safe answer to "we do not know".
   *
   * Copy may say: this did not finish, try again. It may NOT say anything about
   * a mailbox being authorised, connected, or still connected.
   */
  | "cancelled"
  /** The browser refused to open the consent window at all. Only the user's popup setting fixes this. */
  | "popup_blocked"
  /**
   * The consent completed and a grant appeared **during** this ceremony, but
   * THIS device never received the tokens: the claim rode a single-use,
   * in-memory entry that only the claim POST can spend, and this context never
   * heard the code (the popup died first, or another tab of this origin heard
   * the broadcast and spent it).
   *
   * Provable, and only claimed when it is: there was no grant before the window
   * opened and there is one now. NOT a success — nothing was sealed here, and
   * connecting again is what supersedes the grant this ceremony created.
   *
   * Copy may say: the mailbox was authorised but this device did not receive it.
   */
  | "claim_lost"
  /**
   * This attempt did not finish, and a mailbox was ALREADY connected to this
   * account before the window opened.
   *
   * The reconnect-flow counterpart of `cancelled`. It is deliberately silent on
   * whether the consent inside this window succeeded — a grant was there before,
   * so a grant being there afterwards proves nothing either way — and equally
   * silent on whether the pre-existing connection still works, which is
   * `reconnect_required`'s business and not observable from here.
   *
   * Copy may say: this did not finish; a mailbox was already connected before it
   * started, and this attempt has not replaced it. It may NOT say the existing
   * mailbox is healthy, nor that anything was authorised just now.
   */
  | "reconnect_incomplete"
  /**
   * There is no usable token on this device and the grant is dead or gone at the
   * broker: the user must run the connect ceremony again. The one kind the fetch
   * lane (Task 12) stops on and the settings screen (Task 15) renders as a
   * reconnect prompt.
   */
  | "reconnect_required"
  /** No HTTP answer reached the server. */
  | "offline"
  /** The broker answered 429. */
  | "rate_limited"
  /** 503, or an answer this ceremony did not expect. Retrying may help. */
  | "unavailable"
  /**
   * This DEVICE could not produce the keys the ceremony needs — the key vault
   * did not open, or held nothing. Nothing was sent anywhere and Google was
   * never involved.
   *
   * It exists because `unavailable` used to cover this case too, and
   * `unavailable`'s copy says "Something went wrong on the way to Google."
   * That is a sentence the code does not honour: the request never left the
   * device. Worse, the connect path is reached during or just after onboarding,
   * so the person most likely to see it is a new user on their first connect,
   * with no working state to compare against — sent to check Google for a fault
   * that is entirely local.
   *
   * Copy may say: this device could not unlock its keys, and nothing was sent.
   * It may NOT blame Google, the network, or the mailbox service.
   */
  | "device_keys_unavailable";

/**
 * A mailbox operation that did not complete.
 *
 * `status`/`code` carry the broker's own answer when there was one, for a log —
 * never for a user, and never varied on by control flow beyond {@link mailboxKind}.
 */
export class MailboxError extends Error {
  readonly mailboxKind: MailboxFailureKind;
  readonly status?: number;
  readonly code?: string;

  constructor(kind: MailboxFailureKind, message: string, opts: { status?: number; code?: string; cause?: unknown } = {}) {
    super(message);
    this.name = "MailboxError";
    this.mailboxKind = kind;
    if (opts.status !== undefined) this.status = opts.status;
    if (opts.code !== undefined) this.code = opts.code;
    if (opts.cause !== undefined) (this as { cause?: unknown }).cause = opts.cause;
  }
}

export function isMailboxError(err: unknown): err is MailboxError {
  return typeof err === "object" && err !== null && typeof (err as { mailboxKind?: unknown }).mailboxKind === "string";
}

/** The device must run the connect ceremony again — `MailboxError` with `mailboxKind === "reconnect_required"`. */
export function isMailboxReconnectRequired(err: unknown): err is MailboxError {
  return isMailboxError(err) && err.mailboxKind === "reconnect_required";
}

/** The consent popup was dismissed or closed early — `MailboxError` with `mailboxKind === "cancelled"`. */
export function isMailboxConnectCancelled(err: unknown): err is MailboxError {
  return isMailboxError(err) && err.mailboxKind === "cancelled";
}

/**
 * The connect attempt ended having changed nothing, and the UI may simply return
 * to the state it was in — `cancelled` or `reconnect_incomplete`.
 *
 * The predicate Tasks 14/15 want for "close the sheet, no alarm". Both kinds are
 * quiet outcomes; they differ only in whether the copy alongside may mention an
 * already-connected mailbox. `claim_lost` is deliberately NOT in this set: a
 * grant exists that no device can mint against, and the user has to act.
 */
export function isMailboxConnectAbandoned(err: unknown): err is MailboxError {
  return isMailboxError(err) && (err.mailboxKind === "cancelled" || err.mailboxKind === "reconnect_incomplete");
}

// ---------------------------------------------------------------------------
// Injectable seams (defaults are the real browser primitives; tests pass fakes)
// ---------------------------------------------------------------------------

/**
 * The narrow view of the consent popup this file needs.
 *
 * It is opened SYNCHRONOUSLY inside the user gesture (at `about:blank`) and
 * navigated to the consent URL once `/oauth/begin` returns — see
 * {@link connectMailbox}. So the handle carries more than "is it still open": it
 * can be pointed at a URL, and closed if begin fails before it ever gets one.
 */
export interface PopupHandle {
  readonly closed: boolean;
  /** Point the (initially `about:blank`) popup at the consent URL. */
  navigate(url: string): void;
  /** Close the popup — used when begin fails before it was ever navigated. */
  close(): void;
}

/** The narrow view of a BroadcastChannel this file needs. A real `BroadcastChannel` satisfies it. */
export interface MailboxBroadcast {
  onmessage: ((event: MessageEvent) => void) | null;
  close(): void;
}

export interface MailboxCeremonyDeps {
  /** Defaults to the global `fetch`. */
  fetch?: typeof fetch;
  /**
   * Opens the consent popup at the given URL (`about:blank` — it is navigated to
   * the consent URL afterward) and returns a handle, or `null` if the browser
   * blocked it. Defaults to `window.open`. Called SYNCHRONOUSLY inside the user
   * gesture; see {@link connectMailbox}.
   */
  open?: (url: string) => PopupHandle | null;
  /** Builds the claim channel. Defaults to `new BroadcastChannel(MAILBOX_CHANNEL)`. */
  channel?: () => MailboxBroadcast;
  /** The sealed-token store. Defaults to the browser IndexedDB store (`mailboxToken.ts`). */
  store?: KeyStore;
  /** Cadence of the popup-closed grant poll, in ms. */
  pollIntervalMs?: number;
  /** How many closed-popup polls without a grant end the wait as `cancelled`. */
  maxIdlePolls?: number;
  /**
   * How long the ceremony waits in total before giving up as `cancelled`.
   *
   * A window the user opens and then simply leaves alone never closes and never
   * broadcasts, so without this the promise never settles and whatever UI is
   * awaiting it spins forever. Comfortably longer than the state row's 5-minute
   * TTL, after which the callback itself answers ceremony-over.
   */
  deadlineMs?: number;
  /** Injected for tests; defaults to a real `setTimeout` sleep. */
  sleep?: (ms: number) => Promise<void>;
}

function defaultFetch(...args: Parameters<typeof fetch>): ReturnType<typeof fetch> {
  return fetch(...args);
}

function defaultOpen(url: string): PopupHandle | null {
  if (typeof window === "undefined") return null;
  const win = window.open(url, "ledger-mailbox-connect", "popup=yes,width=480,height=720");
  // Falsy, not `=== null`. A blocking browser returns `null`, but jsdom's
  // unimplemented `window.open` returns `undefined` — and the strict check let
  // that through, so the handle below closed over nothing and the ceremony died
  // later with `undefined is not an object (evaluating 'win.close')` instead of
  // the clean `popup_blocked` this function exists to report.
  if (!win) return null;
  return {
    get closed(): boolean {
      return win.closed;
    },
    // `location.replace`, not `location.href`: the blank placeholder must not
    // leave a history entry the user could "back" into mid-ceremony.
    navigate(next: string): void {
      win.location.replace(next);
    },
    close(): void {
      win.close();
    },
  };
}

// ---------------------------------------------------------------------------
// The broker transport
// ---------------------------------------------------------------------------

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * One session-authenticated request to the broker, shaped like `webpush.ts`'s
 * `authed`: the bearer is `handle.client`'s token, the URL is same-origin, and a
 * transport failure becomes an `offline` {@link MailboxError} rather than a raw
 * `TypeError`.
 */
async function authed(
  handle: V2Handle,
  doFetch: typeof fetch,
  method: string,
  path: string,
  body?: unknown,
): Promise<Response> {
  const token = handle.client.sessionToken;
  if (token === null || token === "") {
    throw new MailboxError("unavailable", `${method} ${path}: this device is not signed in`);
  }
  // `Client.server` is a GETTER that throws when the build has no server and no
  // ambient origin, and it is read OUTSIDE the try on purpose: read inside it, a
  // misconfiguration is caught by the branch that exists for "no HTTP answer
  // arrived" and re-thrown as `offline` — the exact mistake `client.ts`'s
  // ConfigError doc says cost a day, telling a perfectly connected user to try
  // again later. A misconfiguration never becomes correct by retrying.
  let base: string;
  try {
    base = handle.client.server;
  } catch (err) {
    throw new MailboxError("unavailable", `${method} ${path}: ${errMsg(err)}`, { cause: err });
  }
  try {
    return await doFetch(`${base}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  } catch (err) {
    throw new MailboxError("offline", `${method} ${path}: ${errMsg(err)}`, { cause: err });
  }
}

async function readJson<T>(res: Response): Promise<T> {
  return JSON.parse(await res.text()) as T;
}

/** The broker's `{error, detail}` body, best-effort. */
async function errorBody(res: Response): Promise<{ code: string; detail: string }> {
  try {
    const e = JSON.parse(await res.text()) as { error?: string; detail?: string };
    return { code: e.error ?? "", detail: e.detail ?? "" };
  } catch {
    return { code: "", detail: "" };
  }
}

/** Maps a non-ok broker answer to a typed failure. Never an oracle: control flow keys on status, not on the body. */
async function refusalToError(res: Response, what: string): Promise<MailboxError> {
  const { code } = await errorBody(res);
  if (res.status === 429) return new MailboxError("rate_limited", `${what}: too many mailbox requests`, { status: 429, code });
  if (res.status === 503) return new MailboxError("unavailable", `${what}: the mailbox service is unavailable`, { status: 503, code });
  return new MailboxError("unavailable", `${what}: ${String(res.status)} ${code}`, { status: res.status, code });
}

/**
 * The grant's status string, or `null` for `404 no_grant`. A 404 is not a
 * failure here — it is the very answer the popup-closed fallback and the
 * reconnect check need — so it does not throw; a 503 does.
 */
async function grantStatus(handle: V2Handle, doFetch: typeof fetch): Promise<string | null> {
  const res = await authed(handle, doFetch, "GET", "/api/v1/mailbox/grant");
  if (res.status === 404) return null;
  if (!res.ok) throw await refusalToError(res, "mailbox grant");
  const body = await readJson<{ status?: unknown }>(res);
  return typeof body.status === "string" ? body.status : "";
}

/**
 * Whether this account had a mailbox grant at a given moment — the observation
 * the unfinished-connect labels are proved from.
 *
 * `"unknown"` is a first-class third answer rather than an error or a guess: a
 * 503 on the snapshot must not become "no grant", because that would let a
 * cancelled reconnect be reported as `claim_lost`, which is the inversion this
 * whole mechanism exists to prevent.
 */
type GrantPresence = "none" | "present" | "unknown";

async function grantPresence(handle: V2Handle, doFetch: typeof fetch): Promise<GrantPresence> {
  try {
    return (await grantStatus(handle, doFetch)) === null ? "none" : "present";
  } catch {
    return "unknown";
  }
}

/**
 * Whether a mailbox grant exists for this account — the `mailbox_connected`
 * milestone fact (spec D11), read from its one authority, `GET /grant`.
 *
 * A grant in ANY state is "connected": a `reconnect_required` grant is still a
 * mailbox the user once connected, and onboarding must not re-walk the mail
 * stage over a repairable connection. Absent (`404`) or unreadable (`503`,
 * offline) reads as `false`, the safe direction — a device that could not read
 * the grant walks the mail stage rather than skipping it on a stale belief.
 *
 * Task 14 (boot resume) and Task 15 (Settings) share this so the fact has one
 * reader shape, not two that can disagree.
 */
export async function mailboxConnected(handle: V2Handle, deps: MailboxCeremonyDeps = {}): Promise<boolean> {
  const doFetch = deps.fetch ?? defaultFetch;
  try {
    return (await grantStatus(handle, doFetch)) !== null;
  } catch {
    return false;
  }
}

/**
 * Whether this deployment has a mailbox broker at all — the switch the
 * route-choice card is gated on (spec §2.3: an unconfigured build renders no
 * card).
 *
 * An unconfigured build mounts none of the `/api/v1/mailbox` routes (like
 * `Passkeys` and `Addresses`), so `GET /grant` falls through to the mux's own
 * bare `404` — which a client cannot tell from a real answer except by its body:
 * a mounted route answers `404` with `{"error":"no_grant"}`, the unmounted mux
 * answers with plain text that does not parse. So:
 *
 *   - any non-404, or a `404` whose body carries the `no_grant` code ⇒ mounted;
 *   - a `404` with no such code (the mux text page) ⇒ not configured;
 *   - a transport failure ⇒ not configured, fail-closed (no card offline).
 *
 * It is a diagnosis of the deployment, never of the account: a signed-in device
 * with no grant still reports `true` here, because the BROKER is present.
 */
export async function mailboxConfigured(handle: V2Handle, deps: MailboxCeremonyDeps = {}): Promise<boolean> {
  try {
    return await mailboxConfiguredStrict(handle, deps);
  } catch {
    return false;
  }
}

/**
 * {@link mailboxConfigured}, but it THROWS on a transient failure instead of
 * folding it to `false` — so a caller that can retry (react-query, a bounded
 * loop) retries the transient and treats ONLY a real HTTP answer as
 * authoritative.
 *
 * The line it draws is the one the onboarding route card depends on:
 *
 *   - an authoritative answer RESOLVES — a mounted route (non-404, or a `404`
 *     carrying `no_grant`) ⇒ `true`; the unmounted mux's bare `404` ⇒ `false`;
 *   - a transient failure — offline, an unsent request, no session token, a
 *     server-config read that threw — RETHROWS, because "this build has no
 *     mailbox broker" is a claim a dropped request has no standing to make. A
 *     single-shot probe that folds it to `false` shows no route card to a user
 *     whose only problem was a flaky first byte.
 *
 * `mailboxConfigured` keeps the fold-to-`false` contract for callers that do
 * their own fail-closed and want no throw; this is the same diagnosis with the
 * transient left visible.
 */
export async function mailboxConfiguredStrict(handle: V2Handle, deps: MailboxCeremonyDeps = {}): Promise<boolean> {
  const doFetch = deps.fetch ?? defaultFetch;
  // No catch: a throw here is `authed`'s transient (offline / no session /
  // config read failed), and the whole point is to let it propagate to a retry.
  const res = await authed(handle, doFetch, "GET", "/api/v1/mailbox/grant");
  if (res.status !== 404) return true;
  return (await errorBody(res)).code === "no_grant";
}

/**
 * The grant's status string, or `null` for no grant — the settings drill-in's
 * state authority (Task 15). It is `grantStatus` with the ceremony deps shape,
 * so Settings reads the grant the exact way the connect ceremony's snapshot does
 * rather than inventing a second reader. A 503/offline throws, so the caller can
 * render a read-error state distinct from "no grant"; a 404 is `null`.
 */
export async function readGrantStatus(handle: V2Handle, deps: MailboxCeremonyDeps = {}): Promise<string | null> {
  return grantStatus(handle, deps.fetch ?? defaultFetch);
}

/**
 * Deletes the account's grant row (`DELETE /api/v1/mailbox/grant`, Task 4).
 *
 * The last step of a Settings disconnect, after {@link disconnectMailbox} has
 * revoked at Google and swept the local token: the grant row is the account fact
 * every device reads to decide "connected", so removing it is what makes a second
 * device stop showing the mailbox as connected. `204` and `404` (already gone)
 * are both success; anything else is a typed failure the panel can retry.
 */
export async function deleteMailboxGrant(handle: V2Handle, deps: MailboxCeremonyDeps = {}): Promise<void> {
  const res = await authed(handle, deps.fetch ?? defaultFetch, "DELETE", "/api/v1/mailbox/grant");
  if (res.ok || res.status === 404) return;
  throw await refusalToError(res, "mailbox grant delete");
}

// ---------------------------------------------------------------------------
// connect
// ---------------------------------------------------------------------------

/**
 * Runs the consent ceremony and returns the burner address.
 *
 * `begin` → open the consent popup → await the claim over {@link MAILBOX_CHANNEL}
 * (with the GET /grant poll as the popup-closed fallback) → `claim` → seal the
 * refresh token under the account DEK → decode the burner address from the
 * id_token, CLIENT-side and without verifying its signature (it came from our
 * own server over the session, and the server holds no key to verify it with
 * anyway).
 *
 * Rejects with a {@link MailboxError} the UI can render: `popup_blocked` when
 * the window never opened, one of `cancelled` / `reconnect_incomplete` /
 * `claim_lost` when the ceremony ended unfinished (which one is decided by
 * evidence — see {@link MailboxFailureKind} and {@link awaitClaim}), and
 * `rate_limited` / `unavailable` / `offline` for the broker's own answers.
 *
 * It resolves ONLY after a refresh token is sealed on this device. There is no
 * path that returns "connected" without one — see {@link awaitClaim}.
 */
export async function connectMailbox(
  handle: V2Handle,
  dek: CryptoKey,
  accountId: string,
  deps: MailboxCeremonyDeps = {},
): Promise<{ email: string }> {
  const doFetch = deps.fetch ?? defaultFetch;

  // Open the consent popup SYNCHRONOUSLY, inside the user gesture, BEFORE any
  // await. WebKit — the primary PWA platform — drops the tap's user activation
  // across an await and blocks a popup opened after one, so the begin-then-open
  // order this once had failed on Safari's happy path. The window opens at
  // `about:blank` and is navigated to the consent URL once begin returns; a
  // begin failure closes the blank window rather than stranding it.
  const popup = (deps.open ?? defaultOpen)("about:blank");
  if (popup === null) {
    throw new MailboxError("popup_blocked", "this browser blocked the Google consent window");
  }

  let authUrl: string;
  let before: GrantPresence;
  try {
    const beginRes = await authed(handle, doFetch, "POST", "/api/v1/mailbox/oauth/begin", {});
    if (!beginRes.ok) throw await refusalToError(beginRes, "mailbox begin");
    const body = await readJson<{ auth_url?: unknown }>(beginRes);
    if (typeof body.auth_url !== "string" || body.auth_url === "") {
      throw new MailboxError("unavailable", "mailbox begin returned no auth_url");
    }
    authUrl = body.auth_url;

    // The BEFORE half of the snapshot the unfinished-connect labels are proved
    // from — read before the window is navigated to CONSENT, or it proves
    // nothing. The popup is still at `about:blank` here, so no consent can have
    // created a grant yet, which makes this equivalent to the pre-open read it
    // replaces. See MailboxFailureKind's doc. A failure to read it is carried as
    // "unknown" rather than thrown: it only ever downgrades a label.
    before = await grantPresence(handle, doFetch);
  } catch (err) {
    // Nothing was navigated, so nothing was connected; don't leave a blank
    // window open on a begin failure.
    popup.close();
    throw err;
  }

  popup.navigate(authUrl);

  const claimed = await pollForClaim(handle, doFetch, popup, before, deps);
  try {
    popup.close();
  } catch {
    /* already closed by the flow, or not closable — nothing to do */
  }

  await sealMailboxToken(dek, accountId, claimed.refresh_token, deps.store);

  return { email: emailFromIdToken(claimed.id_token) };
}

/**
 * Polls the server for THIS ceremony's tokens, collected by session.
 *
 * The opener no longer depends on the popup handing a claim code back: the
 * server's callback completes the code→token exchange and holds the result
 * keyed by the account that began the ceremony, and this poll collects it with
 * the same session. That makes the connect resilient to the two ways the old
 * cross-window handoff failed on real browsers — a BroadcastChannel severed by
 * COOP when the popup returns through accounts.google.com, and a stale service
 * worker that serves the app shell in place of the callback page so nothing is
 * broadcast at all.
 *
 * `204` = the callback has not finished yet (or nothing is in flight): poll on.
 * `200` = the tokens. A closed popup with nothing collected after a short grace,
 * or the deadline, ends the wait with the one label the before/after grant
 * snapshot can prove (see {@link MailboxFailureKind}).
 */
async function pollForClaim(
  handle: V2Handle,
  doFetch: typeof fetch,
  popup: PopupHandle,
  before: GrantPresence,
  deps: MailboxCeremonyDeps,
): Promise<{ refresh_token: string; id_token: string }> {
  const pollIntervalMs = deps.pollIntervalMs ?? 1500;
  const deadlineMs = deps.deadlineMs ?? 10 * 60 * 1000;
  const maxIdlePolls = deps.maxIdlePolls ?? 3;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));

  let waitedMs = 0;
  let pollsAfterClose = 0;
  for (;;) {
    const res = await authed(handle, doFetch, "POST", "/api/v1/mailbox/oauth/claim", {});
    if (res.status === 200) {
      const body = await readJson<{ refresh_token?: unknown; id_token?: unknown }>(res);
      if (typeof body.refresh_token !== "string" || body.refresh_token === "") {
        throw new MailboxError("unavailable", "mailbox claim returned no refresh token");
      }
      return {
        refresh_token: body.refresh_token,
        id_token: typeof body.id_token === "string" ? body.id_token : "",
      };
    }
    if (res.status !== 204) {
      // Anything that is not "here are the tokens" or "not ready yet" is a real
      // refusal (a dead session, a server error) — map and surface it.
      throw await refusalToError(res, "mailbox claim");
    }
    // 204: the callback has not completed the exchange yet. Bound the wait: once
    // the popup is closed and a short grace has passed with nothing collected,
    // the ceremony did not finish; and a window left open forever must not spin
    // the caller's spinner past the deadline.
    if (popup.closed) {
      pollsAfterClose += 1;
      if (pollsAfterClose >= maxIdlePolls) {
        const after = await grantPresence(handle, doFetch);
        throw unfinishedConnect(before, after);
      }
    }
    if (waitedMs >= deadlineMs) {
      throw unfinishedConnect(before, before === "present" ? "present" : "none");
    }
    await sleep(pollIntervalMs);
    waitedMs += pollIntervalMs;
  }
}

/**
 * Resolves with the claim code once the callback broadcasts it, and rejects
 * every other way the wait can end.
 *
 * # The grant poll is a diagnosis, not a second success path
 *
 * The popup-closed fallback the spec names (§2.1) polls GET /grant once the
 * window is gone. Every one of its answers is a failure — nothing was sealed
 * here, so nothing can resolve — and its only job is to pick which of the three
 * unfinished-connect labels is PROVABLY true, by comparing what it sees against
 * `before`, the snapshot taken before the window opened:
 *
 * | before  | after   | kind                   | because                                   |
 * | ------- | ------- | ---------------------- | ----------------------------------------- |
 * | none    | present | `claim_lost`           | only a claim POST creates a grant, so one |
 * |         |         |                        | was made during this ceremony — not here  |
 * | present | *       | `reconnect_incomplete` | a mailbox was already connected going in  |
 * | none    | none    | `cancelled`            | nothing was connected, before or after    |
 * | unknown | *       | `cancelled`            | prove nothing, claim nothing              |
 *
 * The `after` column is deliberately ignored once `before` is `present`: a grant
 * that was already there is no evidence about this window, and treating it as
 * evidence is exactly the inversion an earlier draft shipped — a cancelled
 * RE-connect reported as "the mailbox was authorised", which that flow had not
 * done. Resolving on any of them, which the draft before THAT one did, would
 * report a mailbox connected on a device holding nothing, so the very next
 * {@link mintAccessToken} throws `reconnect_required`.
 */
function awaitClaim(
  handle: V2Handle,
  doFetch: typeof fetch,
  popup: PopupHandle,
  before: GrantPresence,
  deps: MailboxCeremonyDeps,
): Promise<string> {
  const makeChannel = deps.channel ?? ((): MailboxBroadcast => new BroadcastChannel(MAILBOX_CHANNEL));
  const pollIntervalMs = deps.pollIntervalMs ?? 1200;
  const maxIdlePolls = deps.maxIdlePolls ?? 3;
  const deadlineMs = deps.deadlineMs ?? 10 * 60 * 1000;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));

  return new Promise<string>((resolve, reject) => {
    const channel = makeChannel();
    let settled = false;
    const finish = (): boolean => {
      if (settled) return false;
      settled = true;
      channel.onmessage = null;
      try {
        channel.close();
      } catch {
        /* a closed channel is fine */
      }
      return true;
    };

    channel.onmessage = (event: MessageEvent) => {
      const data = (event as { data?: unknown } | null | undefined)?.data as
        | { claim?: unknown; error?: unknown }
        | null
        | undefined;
      if (data && typeof data.claim === "string" && data.claim !== "") {
        if (finish()) resolve(data.claim);
        return;
      }
      if (data && typeof data.error === "string" && data.error !== "") {
        // The server's ceremony-over redirect: a cancelled consent, a dead code,
        // an expired state. Nothing was connected BY THIS WINDOW, whatever was
        // connected before it — so it goes through the same classifier, and a
        // cancelled reconnect gets the reconnect wording rather than copy that
        // reads as though the account now has no mailbox.
        if (finish()) reject(unfinishedConnect(before, before));
      }
    };

    /** Ends the wait with the one label the before/after pair can prove. */
    const giveUp = (after: GrantPresence): void => {
      if (!finish()) return;
      reject(unfinishedConnect(before, after));
    };

    let idlePolls = 0;
    let waitedMs = 0;
    const poll = async (): Promise<void> => {
      if (settled) return;
      if (popup.closed) {
        const after = await grantPresence(handle, doFetch);
        if (settled) return;
        // A grant that was NOT there before and is there now is the one thing
        // this poll can prove on its own, so it ends the wait immediately.
        // Everything else waits out the idle cap, in case the grant is still
        // being written.
        if (before === "none" && after === "present") {
          giveUp(after);
          return;
        }
        idlePolls += 1;
        if (idlePolls >= maxIdlePolls) {
          giveUp(after);
          return;
        }
      }
      if (waitedMs >= deadlineMs) {
        // A window opened and then left alone never closes and never
        // broadcasts. Ending the wait is the only thing that stops the caller's
        // spinner from being permanent. The window is still open, so nothing
        // new can have been claimed from here: the label rests on `before`.
        giveUp(before === "present" ? "present" : "none");
        return;
      }
      await sleep(pollIntervalMs);
      waitedMs += pollIntervalMs;
      void poll();
    };
    // The claim usually wins outright; the poll only matters once the popup is
    // gone, so it never runs until the first interval has elapsed.
    void sleep(pollIntervalMs).then(() => {
      waitedMs += pollIntervalMs;
      return poll();
    });
  });
}

/**
 * The one place a connect ceremony's unfinished outcome is turned into a label.
 *
 * Every terminal path in {@link awaitClaim} goes through here, so the mapping
 * from evidence to claim exists once and can be read — and tested — as a whole
 * (`mailboxConnect.test.ts` pins every row of the table in `awaitClaim`'s doc).
 * Each message states only what its row proves.
 */
function unfinishedConnect(before: GrantPresence, after: GrantPresence): MailboxError {
  if (before === "none" && after === "present") {
    return new MailboxError(
      "claim_lost",
      "the mailbox was authorised, but this window closed before this device received it; connect again",
    );
  }
  if (before === "present") {
    return new MailboxError(
      "reconnect_incomplete",
      "this attempt did not finish; a mailbox was already connected to this account before it started",
    );
  }
  return new MailboxError("cancelled", "the connect window closed before this attempt finished");
}

/**
 * The burner address from an OAuth id_token's payload, decoded locally.
 *
 * The signature is deliberately NOT verified: the token came from our own server
 * over the authenticated session, and the server holds no key to verify it with
 * either (it never reads the email claim — `internal/api/mailbox.go`). A
 * malformed or absent token yields `""` rather than throwing, because by the
 * time this runs the refresh token is already sealed and the grant recorded —
 * failing here would send a connected user to reconnect for a cosmetic label.
 */
function emailFromIdToken(idToken: string): string {
  try {
    const parts = idToken.split(".");
    if (parts.length < 2 || parts[1] === undefined || parts[1] === "") return "";
    const claims = JSON.parse(webPlatform.utf8Decode(fromBase64Url(parts[1]))) as { email?: unknown };
    return typeof claims.email === "string" ? claims.email : "";
  } catch {
    return "";
  }
}

// ---------------------------------------------------------------------------
// The local sweep
// ---------------------------------------------------------------------------

/**
 * Forgets EVERYTHING this device holds about a mailbox connection: the sealed
 * token row and its unsealed sibling, the `mailbox-state` row.
 *
 * The one helper every sweep goes through, and the reason it exists is that the
 * two rows kept being swept apart. `deleteMailboxToken` alone leaves
 * `mailbox-state` — which is NOT sealed: it holds the burner address
 * (`connectedEmail`), the `historyId` checkpoint and the fetched message-id
 * ring, in cleartext IndexedDB. On a shared browser that residue is another
 * account's mailbox address, readable by whoever signs in next; on a reconnect
 * it is a checkpoint the new connection would resume from wrongly. Every path
 * that drops the token — the two reconnect sweeps in {@link mintAccessToken},
 * {@link disconnectMailbox}, and `mailbox/runtime.ts`'s
 * `disconnectMailboxAccount` — calls this instead of the two deletes, so a
 * future path cannot remember one row and forget the other.
 *
 * Both deletes are by key and idempotent: a device that never connected has
 * neither row, and neither delete touches the account row that shares the store.
 */
export async function sweepMailboxLocal(store?: KeyStore): Promise<void> {
  await deleteMailboxToken(store);
  await deleteMailboxState(store);
}

// ---------------------------------------------------------------------------
// mint
// ---------------------------------------------------------------------------

/**
 * Trades the sealed refresh token for a short-lived Gmail access token.
 *
 * Opens the sealed token ({@link openMailboxToken}, throw-aware per Task 8 I-1),
 * then POSTs it to the broker. The broker's one generic refusal (403
 * `mailbox_refused`) says nothing on its own, so this asks GET /grant which case
 * it is; `reconnect_required`, a superseded digest and a deleted grant all mean
 * the same for THIS device — the local token is dead — so it sweeps the token
 * and throws {@link MailboxError} `reconnect_required`. A token row that threw on
 * open takes the same reconnect-and-sweep path.
 */
export async function mintAccessToken(
  handle: V2Handle,
  dek: CryptoKey,
  accountId: string,
  deps: MailboxCeremonyDeps = {},
): Promise<string> {
  const doFetch = deps.fetch ?? defaultFetch;

  let token: string | null;
  try {
    token = await openMailboxToken(dek, accountId, deps.store);
  } catch (err) {
    // Task 8 I-1: a present-but-unreadable row is the account-switch residual (or
    // corruption). Sweep it and route to reconnect — never a banner, never
    // "connected". The sweep is the whole connection ({@link sweepMailboxLocal}):
    // the unsealed state row beside it holds the OTHER account's burner address.
    await sweepMailboxLocal(deps.store).catch(() => undefined);
    throw new MailboxError(
      "reconnect_required",
      "the stored mailbox token could not be opened on this device; reconnect the mailbox",
      { cause: err },
    );
  }
  if (token === null) {
    throw new MailboxError("reconnect_required", "no mailbox token is stored on this device; connect a mailbox");
  }

  const res = await authed(handle, doFetch, "POST", "/api/v1/mailbox/token", { refresh_token: token });
  if (res.ok) {
    const { access_token } = await readJson<{ access_token?: unknown }>(res);
    if (typeof access_token !== "string" || access_token === "") {
      throw new MailboxError("unavailable", "the mailbox token endpoint returned no access token");
    }
    return access_token;
  }

  if (res.status === 403) {
    const { code } = await errorBody(res);
    if (code === "mailbox_refused") {
      let status: string | null;
      try {
        status = await grantStatus(handle, doFetch);
      } catch (err) {
        // The grant state could not be read: do NOT sweep on a maybe. A retry is
        // possible, so surface it as unavailable rather than reconnect.
        throw new MailboxError("unavailable", "the mailbox token was refused and the grant state could not be read", {
          cause: err,
        });
      }
      // reconnect_required, a superseded digest ("active" but not ours) and a
      // deleted grant (null) all mean the local token is dead. Sweep and reconnect
      // — the state row too, or the dead connection's address and checkpoint
      // outlive it and the next connect resumes from a stranger's checkpoint.
      await sweepMailboxLocal(deps.store).catch(() => undefined);
      throw new MailboxError("reconnect_required", reconnectMessage(status), { status: 403, code });
    }
  }

  throw await refusalToError(res, "mailbox token");
}

function reconnectMessage(status: string | null): string {
  if (status === "reconnect_required") return "Google no longer honours this mailbox token; reconnect the mailbox";
  if (status === null) return "this mailbox is no longer connected; reconnect it";
  return "this device's mailbox token has been superseded; reconnect the mailbox";
}

// ---------------------------------------------------------------------------
// disconnect
// ---------------------------------------------------------------------------

/**
 * Revokes the refresh token at Google and forgets the connection locally.
 *
 * On success — or on the broker's generic refusal, which means the token is
 * already dead or superseded and revoking it is moot — the local rows are swept
 * ({@link sweepMailboxLocal}: the sealed token AND the unsealed state row). On
 * infrastructure trouble (503) the grant may still be live at Google and this
 * token is the only thing that can reach it, so the token is KEPT here and the
 * failure is surfaced for a retry.
 *
 * That retention is this function's contract alone, and it is deliberately NOT
 * the last word on the residue: `disconnectMailboxAccount` deletes the grant
 * right after, which kills the token's only route back to Google, so it sweeps
 * unconditionally and reports the unrevoked grant with
 * {@link mailboxRevokeUnconfirmed}.
 */
export async function disconnectMailbox(
  handle: V2Handle,
  refreshToken: string,
  deps: MailboxCeremonyDeps = {},
): Promise<void> {
  const doFetch = deps.fetch ?? defaultFetch;
  const res = await authed(handle, doFetch, "POST", "/api/v1/mailbox/revoke", { refresh_token: refreshToken });
  if (res.ok || res.status === 403) {
    await sweepMailboxLocal(deps.store);
    return;
  }
  throw await refusalToError(res, "mailbox revoke");
}

/**
 * The disconnect finished HERE but could not be confirmed at Google.
 *
 * A distinct error rather than a flag on the result, because the two halves of a
 * disconnect have different owners and only one of them is ours: ledger forgets
 * the mailbox on this device and removes the grant from the account whatever
 * Google answers, but a refresh token whose revoke never landed leaves ledger's
 * access live in the user's Google Account. Nothing client-side can finish that
 * — `internal/api/mailbox.go`'s disconnect handler says the same about the grant
 * it leaves behind: it "is the user's to remove from their Google account page."
 *
 * `mailboxKind` stays `unavailable` on purpose. It is the honest kind for a 503,
 * and `MAILBOX_CONNECT_FAILURE_COPY` in `onboarding.ts` is a total record over
 * {@link MailboxFailureKind} — a new kind would be a copy obligation on a screen
 * this error never reaches. Callers that must tell it apart match structurally
 * with {@link isMailboxRevokeUnconfirmed}, the same bundler-safe shape test
 * {@link isMailboxError} uses.
 */
export class MailboxRevokeUnconfirmedError extends MailboxError {
  /** The structural marker {@link isMailboxRevokeUnconfirmed} matches on. */
  readonly revokeUnconfirmed = true;

  constructor(message: string, opts: { cause?: unknown } = {}) {
    super("unavailable", message, opts);
    this.name = "MailboxRevokeUnconfirmedError";
  }
}

/**
 * The one sentence for "we could not reach Google to revoke it".
 *
 * Written once, here, so it cannot drift from the copy already shipped for the
 * same fact: `DeleteAccountPanel`'s `delete-account-mailbox-failed` ("We
 * couldn't reach Google to disconnect it just now… revoke ledger's access from
 * your Google Account"). It states what DID happen locally rather than implying
 * nothing changed, and names the page that finishes the job. The refresh token
 * never appears in it — `cause` carries the broker's own answer for a log.
 */
export function mailboxRevokeUnconfirmed(cause: unknown): MailboxRevokeUnconfirmedError {
  return new MailboxRevokeUnconfirmedError(
    "we couldn't reach Google to disconnect the mailbox just now; ledger has forgotten it on this device and " +
      "removed it from your account, and you can revoke ledger's access from your Google Account at " +
      "myaccount.google.com/permissions",
    { cause },
  );
}

/**
 * The disconnect completed locally, but Google was never told — `MailboxError`
 * carrying {@link MailboxRevokeUnconfirmedError}'s marker. Matched structurally
 * for the reason {@link isMailboxError} gives.
 */
export function isMailboxRevokeUnconfirmed(err: unknown): err is MailboxRevokeUnconfirmedError {
  return isMailboxError(err) && (err as { revokeUnconfirmed?: unknown }).revokeUnconfirmed === true;
}
