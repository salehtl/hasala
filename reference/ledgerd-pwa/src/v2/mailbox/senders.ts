/**
 * The account's mailbox sender allowlist — the per-user, server-side list of
 * verified signing domains a message must be on to auto-import (spec D6).
 *
 * Task 4 built the two routes; nothing on the client POSTed to them until here.
 * The fetch lane reads the list at fetch time ({@link listSenders}), and the
 * mailbox review card's "Trust <domain> for automatic import" writes to it
 * ({@link trustSender}). Both are thin, session-authenticated drivers over
 * `internal/api/mailbox.go`, shaped exactly like `mailboxConnect.ts`'s broker
 * transport: the bearer is the {@link V2Handle}'s session token, the URL is
 * same-origin, and a transport failure becomes an `offline` {@link MailboxError}
 * rather than a raw `TypeError`.
 *
 * # This list is a SEPARATE scope from the SMTP allowlist, and this file only
 * touches the mailbox one
 *
 * D6: a bank you receive directly (SMTP `sender_allowlist`) is not the same
 * evidence as a bank behind your Gmail grant; confirmations do not cross lanes.
 * These routes are `/api/v1/mailbox/senders`, never the SMTP allowlist — the two
 * lists converge per-device only through the server, exactly as D6 describes.
 *
 * # A domain, never a verdict
 *
 * Trusting a domain says "auto-import future mail this domain signs"; it makes no
 * claim that any message already seen is genuine. That honesty is the review
 * card's (D6a) — this file only carries the domain to the server.
 */

import { MailboxError } from "../mailboxConnect";
import type { V2Handle } from "../session";

/** Injectable transport seam. Defaults to the global `fetch`. */
export interface SendersDeps {
  fetch?: typeof fetch;
}

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * One session-authenticated request to the mailbox sender routes. The same
 * shape as `mailboxConnect.ts`'s `authed`, kept local rather than imported so
 * this file has no reach into the connect ceremony's internals: the bearer is
 * read outside the try (a getter that throws is a misconfiguration, not an
 * `offline`), and a real transport failure is the one thing turned into
 * `offline`.
 */
async function authed(
  handle: V2Handle,
  doFetch: typeof fetch,
  method: string,
  body?: unknown,
): Promise<Response> {
  const token = handle.client.sessionToken;
  if (token === null || token === "") {
    throw new MailboxError("unavailable", `${method} /api/v1/mailbox/senders: this device is not signed in`);
  }
  let base: string;
  try {
    base = handle.client.server;
  } catch (err) {
    throw new MailboxError("unavailable", `${method} /api/v1/mailbox/senders: ${errMsg(err)}`, { cause: err });
  }
  try {
    return await doFetch(`${base}/api/v1/mailbox/senders`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  } catch (err) {
    throw new MailboxError("offline", `${method} /api/v1/mailbox/senders: ${errMsg(err)}`, { cause: err });
  }
}

/** Maps a non-ok answer to a typed failure, keying on status and never the body. */
function refusal(res: Response, what: string): MailboxError {
  if (res.status === 429) return new MailboxError("rate_limited", `${what}: too many mailbox requests`, { status: 429 });
  if (res.status === 503) return new MailboxError("unavailable", `${what}: the mailbox service is unavailable`, { status: 503 });
  return new MailboxError("unavailable", `${what}: ${String(res.status)}`, { status: res.status });
}

/**
 * The account's trusted mailbox sender domains (`GET /api/v1/mailbox/senders`).
 *
 * Returns the domains the server holds, already lower-cased bare domains (the
 * server validates the list). The fetch lane's `loadSenders` is this. A malformed
 * body reads as an empty list rather than a throw — a missing allowlist means no
 * message auto-imports, the safe direction, never a crashed cycle.
 */
export async function listSenders(handle: V2Handle, deps: SendersDeps = {}): Promise<readonly string[]> {
  const doFetch = deps.fetch ?? ((...a: Parameters<typeof fetch>) => fetch(...a));
  const res = await authed(handle, doFetch, "GET");
  if (!res.ok) throw refusal(res, "mailbox senders");
  let body: { domains?: unknown };
  try {
    body = JSON.parse(await res.text()) as { domains?: unknown };
  } catch {
    return [];
  }
  if (!Array.isArray(body.domains)) return [];
  return body.domains.filter((d): d is string => typeof d === "string" && d !== "");
}

/**
 * The mail providers a message may pass THROUGH. None of them can ever be a
 * trusted sender, and the server refuses every one of them at
 * `POST /api/v1/mailbox/senders` with `409 forwarder_domain`.
 *
 * # Why the client holds a copy at all
 *
 * The server is the boundary — this list decides nothing that matters. It
 * exists so the product never OFFERS an action it knows will be refused: for a
 * message a human forwarded by hand, the domain Gmail's own
 * Authentication-Results verified is `gmail.com`, so "Trust gmail.com for
 * automatic import" is the button the review card would otherwise draw. Both
 * ends are honest about the same fact; only one of them enforces it.
 *
 * It mirrors `origin.ForwarderDomains` in `internal/origin/trust.go`, byte for
 * byte, and matching is PERMISSIVE the same way (a subdomain counts). Nothing
 * cross-checks the two lists, so a name added there belongs here too — but a
 * drift can only cost a refused button and never a trusted forwarder, because
 * the server's copy is the one that answers.
 */
export const FORWARDER_DOMAINS: readonly string[] = [
  "apple.com",
  "fastmail.com",
  "gmail.com",
  "google.com",
  "googlemail.com",
  "hotmail.com",
  "icloud.com",
  "live.com",
  "mac.com",
  "me.com",
  "messagingengine.com",
  "microsoft.com",
  "outlook.com",
  "proton.me",
  "protonmail.ch",
  "protonmail.com",
  "yahoo.com",
  "zoho.com",
];

/** Whether a domain is, or is under, a known forwarder. See {@link FORWARDER_DOMAINS}. */
export function isForwarderDomain(domain: string): boolean {
  const d = domain.trim().toLowerCase().replace(/\.$/, "");
  if (d === "") return false;
  return FORWARDER_DOMAINS.some((f) => d === f || d.endsWith(`.${f}`));
}

/**
 * Trusts a signing domain for automatic import (`POST /api/v1/mailbox/senders`).
 *
 * The review card's "Trust <domain> for automatic import" action. `204` on
 * success. `409 too_many_senders` (the per-account cap) surfaces as an
 * `unavailable` MailboxError the card can report, and so does the server's
 * `409 forwarder_domain`.
 *
 * A forwarder never reaches the network: it is refused here, with the same
 * `forwarder_domain` code the server answers with, so a caller that somehow
 * asks for one gets one failure shape whichever end catches it. That is a
 * courtesy, not the boundary — `handleMailboxAddSender` is the boundary, and it
 * refuses the same set on its own.
 */
export async function trustSender(handle: V2Handle, domain: string, deps: SendersDeps = {}): Promise<void> {
  if (isForwarderDomain(domain)) {
    throw new MailboxError(
      "unavailable",
      `trust mailbox sender: ${domain} is a mail provider, not a bank; trusting it would import everything that passes through your mailbox`,
      { status: 409, code: "forwarder_domain" },
    );
  }
  const doFetch = deps.fetch ?? ((...a: Parameters<typeof fetch>) => fetch(...a));
  const res = await authed(handle, doFetch, "POST", { domain });
  if (res.ok) return;
  throw refusal(res, "trust mailbox sender");
}
