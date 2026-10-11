/**
 * fakegmail.mjs — the BROWSER-facing fake of Google's OAuth + Gmail REST surface,
 * for the harness's `--gmail-fixtures` stack (plan Task 16).
 *
 * # Why this exists next to internal/mailbox/fakegoogle
 *
 * `internal/mailbox/fakegoogle` (Task 3) is the Go test fake: it answers `/token`
 * and `/revoke` for the broker's own unit tests, mounted behind an httptest
 * server inside the Go process. It has no consent page and no Gmail content
 * surface, because Go tests never open a browser and never fetch a message.
 *
 * This file is the equivalent a REAL BROWSER talks to. The connect ceremony's
 * popup navigates here for the consent screen; the server-side broker calls here
 * for `/token` and `/revoke` (via the `LEDGER_GOOGLE_*_URL` overrides); and the
 * client's fetch lane calls the Gmail REST paths here (routed by the runner, since
 * `web/src/v2/mailbox/gmail.ts` hard-codes `gmail.googleapis.com`). One process
 * serves all three so a single `--gmail-fixtures` flag wires the whole feature.
 *
 * It reuses fakegoogle's token-shape decisions (a refresh token only on the code
 * grant, never echoed on a refresh; an `invalid_grant` knob for D10) and adds the
 * two things a browser needs that Go never did: an auto-approving consent page,
 * and an id_token that is a real JWT whose payload carries an `email` claim the UI
 * decodes and shows.
 *
 * # SYNTHETIC fixtures only
 *
 * Every message below is hand-authored and fictional. No real mail is ever served
 * — the repo's history was rewritten once because real mail was committed, and the
 * mailbox lane must never repeat it. The RFC822 fixtures carry a valid topmost
 * `Authentication-Results: mx.google.com` header (so the client A-R verdict
 * passes, spec D4), a HOSTILE-width merchant, and an UNLISTED sender — the
 * `HOSTILE_ROWS` spirit `v2nav.mjs` already applies to CSV fixtures.
 *
 * # Standalone
 *
 *   bun harness/fakegmail.mjs [port]     # default 8127; prints its endpoints
 *   curl -s localhost:8127/gmail/v1/users/me/profile
 *
 * Node stdlib only — no dependency the harness does not already have.
 */

import http from "node:http";
import { Buffer } from "node:buffer";

// ---------------------------------------------------------------------------
// Token-shape defaults, mirrored from internal/mailbox/fakegoogle
// ---------------------------------------------------------------------------

const DEFAULT_REFRESH_TOKEN = "fake-harness-refresh-token";
const DEFAULT_ACCESS_TOKEN = "fake-harness-access-token";
const DEFAULT_EXPIRES_IN = 3600;

/** The burner address the id_token vouches for — synthetic, and shown by the UI. */
const DEFAULT_EMAIL = "ledger.mailbox.harness@example.com";

/**
 * A JWT with an unsigned ("alg":"none") shape. The client decodes the payload
 * WITHOUT verifying the signature (mailboxConnect.ts's emailFromIdToken: the
 * token came from our own server over the session, and the server holds no key to
 * verify it with either), so a real signature would be verified by nobody. The
 * three parts are still present because the decoder splits on ".".
 */
function makeIdToken(email) {
  const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
  const header = b64url({ alg: "none", typ: "JWT" });
  const payload = b64url({
    iss: "https://accounts.google.com",
    aud: "fake-harness-client",
    sub: "fake-harness-subject-000",
    email,
    email_verified: true,
    iat: Math.floor(Date.now() / 1000),
  });
  return `${header}.${payload}.`;
}

// ---------------------------------------------------------------------------
// Synthetic RFC822 fixtures (Gmail messages.get?format=raw)
// ---------------------------------------------------------------------------

/**
 * The mailbox head historyId. A fresh connect has no checkpoint, so the fetch
 * lane takes the backfill path (messagesList) and advances to this; a later cycle
 * takes the incremental path (historyList) from its stored checkpoint.
 */
const HEAD_HISTORY_ID = "20260";

/**
 * One synthetic bank message. `crlf` joins the headers with a blank line before
 * the body, exactly as RFC822 requires — the A-R parser reads only up to that
 * blank line, and the topmost header MUST be the mx.google.com A-R for the verdict
 * to be trusted (spec D4: a foreign A-R prepended above it fails `not_topmost`).
 */
function rfc822({ authDomain, from, subject, body, internalDate }) {
  const headers = [
    // Topmost, and the only mx.google.com Authentication-Results: dkim=pass with a
    // d= domain is the trust primitive the client fetch lane keys on.
    `Authentication-Results: mx.google.com; dkim=pass header.d=${authDomain}; dmarc=pass header.from=${authDomain}; spf=pass`,
    `Delivered-To: ${DEFAULT_EMAIL}`,
    `Received: by 10.0.0.1 with SMTP id fake; ${new Date(Number(internalDate)).toUTCString()}`,
    `From: ${from}`,
    `To: ${DEFAULT_EMAIL}`,
    `Subject: ${subject}`,
    `Date: ${new Date(Number(internalDate)).toUTCString()}`,
    `Message-ID: <${internalDate}.fake@${authDomain}>`,
    `MIME-Version: 1.0`,
    `Content-Type: text/plain; charset="utf-8"`,
  ];
  return headers.join("\r\n") + "\r\n\r\n" + body + "\r\n";
}

/**
 * The fixture messages, keyed by Gmail message id. Two of them, on the same
 * `HOSTILE_ROWS` principle v2nav's CSV fixtures use:
 *
 *   - `msg-hostile-listed` — a valid, trusted bank message from a LISTED sender
 *     (dib.ae) whose merchant string is 73 characters, several times any phone's
 *     width, so every surface that shows it must wrap or truncate.
 *   - `msg-unlisted-sender` — a trusted message whose verified domain is NOT on
 *     the account's sender list, so gate 2 (D6) fails and it becomes an empty
 *     needs-review op rather than a filed transaction. This is the "someone
 *     mailed the burner" case the review lane exists for.
 */
const MESSAGES = {
  "msg-hostile-listed": rfc822({
    authDomain: "dib.ae",
    from: "Dubai Islamic Bank <alerts@dib.ae>",
    subject: "Card transaction alert",
    body:
      "Dear Customer,\r\n\r\n" +
      "A purchase of AED 1,250.75 was made on your card ending 4417 at\r\n" +
      "EMIRATES NBD DIRECT DEBIT COLLECTION SERVICES MIDDLE EAST FZ LLC DUBAI AE\r\n" +
      "on 01/08/2026.\r\n\r\n" +
      "If you did not authorise this, please contact us.\r\n",
    internalDate: "1785974400000", // 2026-08-06 UTC, synthetic
  }),
  "msg-unlisted-sender": rfc822({
    authDomain: "newsletter.example",
    from: "Some Newsletter <hello@newsletter.example>",
    subject: "Your weekly digest",
    body:
      "Hi there,\r\n\r\nHere is what you missed this week. This message reached the\r\n" +
      "burner mailbox but its sender is not a bank you listed, so ledger files it\r\n" +
      "as a review item rather than a transaction.\r\n",
    internalDate: "1785888000000", // 2026-08-05 UTC, synthetic
  }),
};

const MESSAGE_IDS = Object.keys(MESSAGES);

// ---------------------------------------------------------------------------
// The server
// ---------------------------------------------------------------------------

/**
 * Build the fake as an http.Server. Scriptable via the returned `state` and the
 * `POST /_control` endpoint:
 *
 *   - `invalidGrant` — makes /token AND /revoke answer 400 invalid_grant, D10's
 *     expired/revoked Testing-status token (the reconnect path the settings
 *     drill-in renders). Set `{"invalidGrant":true}`.
 */
export function makeFakeGmail({ email = DEFAULT_EMAIL } = {}) {
  const state = {
    email,
    invalidGrant: false,
    tokenRequests: [],
    revokeRequests: [],
  };

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const path = url.pathname;

    if (req.method === "GET" && path === "/healthz") {
      return send(res, 200, { ok: true });
    }
    // The consent page: auto-approve and redirect to the server's callback.
    if (req.method === "GET" && path === "/o/oauth2/v2/auth") {
      return serveConsent(res, url);
    }
    if (req.method === "POST" && path === "/token") {
      return readForm(req, (form) => serveToken(res, form, state));
    }
    if (req.method === "POST" && path === "/revoke") {
      return readForm(req, (form) => serveRevoke(res, form, state));
    }
    if (req.method === "POST" && path === "/_control") {
      return readJson(req, (body) => {
        if (typeof body.invalidGrant === "boolean") state.invalidGrant = body.invalidGrant;
        if (typeof body.email === "string" && body.email !== "") state.email = body.email;
        send(res, 200, { ok: true, invalidGrant: state.invalidGrant, email: state.email });
      });
    }
    // The Gmail REST surface the fetch lane calls (spec §2.2). Only the four paths
    // Task 5's CSP admits, matched against the flat `.../history` (no slash).
    if (req.method === "GET" && path.startsWith("/gmail/v1/users/me")) {
      return serveGmail(res, path, url);
    }
    send(res, 404, { error: "not_found", path });
  });

  return { server, state };
}

// --- OAuth ------------------------------------------------------------------

function serveConsent(res, url) {
  const redirectUri = url.searchParams.get("redirect_uri") ?? "";
  const stateTok = url.searchParams.get("state") ?? "";
  if (redirectUri === "") {
    res.writeHead(400, { "Content-Type": "text/plain" });
    res.end("fakegmail: consent called with no redirect_uri");
    return;
  }
  // A synthetic authorization code. The Go broker exchanges it at /token below,
  // which does not check it — the fakegoogle spirit: obedient, not a re-verifier.
  const code = "fake-auth-code-" + Math.random().toString(36).slice(2, 12);
  const back = `${redirectUri}?code=${encodeURIComponent(code)}&state=${encodeURIComponent(stateTok)}`;
  // Auto-approving: no button. The JS redirect fires immediately; the <noscript>
  // meta-refresh is the fallback. Served with its own headers — fakegmail is a
  // different origin from the app and carries no app CSP.
  const backJs = JSON.stringify(back);
  const backHtml = back.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
  const page =
    "<!doctype html><html lang=en><head><meta charset=utf-8>" +
    "<title>Fake Google — approving</title>" +
    `<noscript><meta http-equiv="refresh" content="0;url=${backHtml}"></noscript></head>` +
    "<body><p>Approving access to the fake mailbox…</p>" +
    `<script>location.replace(${backJs});</script></body></html>`;
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  res.end(page);
}

function serveToken(res, form, state) {
  state.tokenRequests.push(form);
  if (state.invalidGrant) {
    return send(res, 400, { error: "invalid_grant", error_description: "Token has been expired or revoked." });
  }
  const body = {
    access_token: DEFAULT_ACCESS_TOKEN,
    id_token: makeIdToken(state.email),
    expires_in: DEFAULT_EXPIRES_IN,
    token_type: "Bearer",
  };
  // Real Google's refresh grant never echoes a refresh_token back; only the
  // authorization_code grant returns one. Matching that keeps the broker's
  // "echo the input token" refresh behaviour honest (fakegoogle does the same).
  if (form.get("grant_type") !== "refresh_token") {
    body.refresh_token = DEFAULT_REFRESH_TOKEN;
  }
  send(res, 200, body);
}

function serveRevoke(res, form, state) {
  state.revokeRequests.push(form);
  if (state.invalidGrant) {
    return send(res, 400, { error: "invalid_grant" });
  }
  res.writeHead(200);
  res.end();
}

// --- Gmail REST -------------------------------------------------------------

function serveGmail(res, path, url) {
  // users.me.profile — the head historyId, captured before a backfill.
  if (path === "/gmail/v1/users/me/profile") {
    return send(res, 200, { emailAddress: DEFAULT_EMAIL, historyId: HEAD_HISTORY_ID, messagesTotal: MESSAGE_IDS.length });
  }
  // history.list — FLAT path (no trailing slash), the one CSP3 prefix-matching
  // bites on. Returns every fixture id as messagesAdded since startHistoryId.
  if (path === "/gmail/v1/users/me/history") {
    return send(res, 200, {
      historyId: HEAD_HISTORY_ID,
      history: MESSAGE_IDS.map((id) => ({ id: HEAD_HISTORY_ID, messagesAdded: [{ message: { id } }] })),
    });
  }
  // messages.list — the backfill path's id source (q=newer_than:Nd).
  if (path === "/gmail/v1/users/me/messages") {
    return send(res, 200, { messages: MESSAGE_IDS.map((id) => ({ id })), resultSizeEstimate: MESSAGE_IDS.length });
  }
  // messages.get?format=raw — the RFC822 body, base64url and UNPADDED, which the
  // fetch lane decodes with its strict decoder and hashes for the ingest id.
  const m = path.match(/^\/gmail\/v1\/users\/me\/messages\/([^/]+)$/);
  if (m) {
    const id = decodeURIComponent(m[1]);
    const raw = MESSAGES[id];
    if (raw === undefined) return send(res, 404, { error: { code: 404, message: "message not found" } });
    if (url.searchParams.get("format") !== "raw") {
      // The lane only ever asks for raw; anything else is a fixture/driver drift.
      return send(res, 400, { error: { code: 400, message: "fakegmail serves only format=raw" } });
    }
    return send(res, 200, {
      id,
      internalDate: internalDateOf(raw),
      raw: Buffer.from(raw, "utf8").toString("base64url"),
    });
  }
  send(res, 404, { error: { code: 404, message: "unknown gmail path", path } });
}

/** Pull the synthetic internalDate back out of a fixture's Message-ID stamp. */
function internalDateOf(raw) {
  const match = raw.match(/Message-ID: <(\d+)\./);
  return match ? match[1] : "";
}

// --- plumbing ---------------------------------------------------------------

function send(res, status, obj) {
  const payload = JSON.stringify(obj);
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(payload);
}

function readForm(req, then) {
  collect(req, (raw) => then(new URLSearchParams(raw)));
}

function readJson(req, then) {
  collect(req, (raw) => {
    try {
      then(raw === "" ? {} : JSON.parse(raw));
    } catch {
      then({});
    }
  });
}

function collect(req, then) {
  let data = "";
  req.on("data", (chunk) => {
    data += chunk;
    if (data.length > 1 << 20) req.destroy(); // bound the body
  });
  req.on("end", () => then(data));
}

// --- CLI --------------------------------------------------------------------

// Run directly (`bun harness/fakegmail.mjs [port]`) rather than imported.
if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.argv[2] ?? 8127);
  const { server } = makeFakeGmail();
  server.listen(port, "127.0.0.1", () => {
    const base = `http://127.0.0.1:${port}`;
    // The one line v2stack.sh greps for readiness; keep the prefix stable.
    console.log(`fakegmail listening ${base}`);
    console.log(`  auth   ${base}/o/oauth2/v2/auth`);
    console.log(`  token  ${base}/token`);
    console.log(`  revoke ${base}/revoke`);
    console.log(`  gmail  ${base}/gmail/v1/users/me/{profile,history,messages,messages/<id>?format=raw}`);
  });
  const shut = () => server.close(() => process.exit(0));
  process.on("SIGTERM", shut);
  process.on("SIGINT", shut);
}
