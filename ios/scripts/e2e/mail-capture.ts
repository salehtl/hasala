// mail-capture.ts: a stand-in for Cloudflare Email Service's send endpoint, for
// the local app end-to-end run (ios/scripts/e2e-app.sh). hasalad's mail worker
// sends to it when HASALA_EMAIL_API_BASE_URL is http://127.0.0.1:<port>/client/v4.
//
//   bun ios/scripts/e2e/mail-capture.ts --port 18454 --dir <dir> [--token e2e]
//
// It answers exactly the request internal/mail/cloudflare.go makes:
//
//   POST /client/v4/accounts/<32 hex>/email/sending/send
//   Authorization: Bearer <token>
//   {"to", "from", "subject", "text", "html"?}
//
// with the provider's success shape (`success`, `errors`, `result.delivered`,
// `result.permanent_bounces`, `result.queued`, `result.message_id`), and writes
// each message to <dir>/<n>.json as {to, from, subject, text, received_at}. The
// file appears whole (written beside, then renamed), so a reader polling the
// directory never sees half a message. A wrong path, method or token gets the
// provider's error shape and nothing is written.
//
// Listens on 127.0.0.1 only and never sends anything anywhere. GET /healthz
// answers 200 for the harness's readiness poll.

import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function arg(name: string, fallback?: string): string {
  const i = Bun.argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < Bun.argv.length) return Bun.argv[i + 1];
  if (fallback !== undefined) return fallback;
  console.error(`mail-capture: --${name} is required`);
  process.exit(2);
}

const port = Number(arg("port"));
const dir = arg("dir");
const token = arg("token", "e2e");
if (!Number.isInteger(port) || port <= 0 || port > 65535) {
  console.error("mail-capture: --port must be a TCP port");
  process.exit(2);
}
mkdirSync(dir, { recursive: true });

const SEND = /^\/client\/v4\/accounts\/[0-9a-f]{32}\/email\/sending\/send$/;
let count = 0;

function failure(status: number, code: number, message: string): Response {
  return Response.json({ success: false, errors: [{ code, message }], messages: [], result: null }, { status });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/healthz") return new Response("ok\n");
    if (!SEND.test(url.pathname)) return failure(404, 7003, "No route for that URI");
    if (req.method !== "POST") return failure(405, 7001, "Method not allowed");
    if (req.headers.get("authorization") !== `Bearer ${token}`) {
      return failure(401, 10000, "Authentication error");
    }
    let body: { to?: unknown; from?: unknown; subject?: unknown; text?: unknown };
    try {
      body = await req.json();
    } catch {
      return failure(400, 10001, "Invalid JSON");
    }
    const { to, from, subject, text } = body;
    if (typeof to !== "string" || typeof from !== "string" || typeof subject !== "string" || typeof text !== "string") {
      return failure(400, 10001, "to, from, subject and text are required");
    }
    count += 1;
    const id = `e2e-${count}`;
    const name = String(count).padStart(5, "0");
    const record = { to, from, subject, text, received_at: new Date().toISOString() };
    const tmp = join(dir, `.${name}.tmp`);
    writeFileSync(tmp, JSON.stringify(record, null, 2) + "\n");
    renameSync(tmp, join(dir, `${name}.json`));
    // One line per message: the subject and the recipient, never the body (it
    // carries the code).
    console.log(`mail-capture: ${name} to=${to} subject=${JSON.stringify(subject)}`);
    return Response.json({
      success: true,
      errors: [],
      messages: [],
      result: { delivered: [to], permanent_bounces: [], queued: [], message_id: id },
    });
  },
});

console.log(`mail-capture: listening on http://127.0.0.1:${server.port}, writing to ${dir}`);
