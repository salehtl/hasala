import {
  MAX_BODY_BYTES,
  MODEL,
  clefBody,
  mapAnswer,
  parseSuggestion,
  refusedClients,
  validClient,
} from "./contract";

export interface AiBinding {
  run(model: string, input: unknown): Promise<unknown>;
}

export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  AI: AiBinding;
  PER_IP: RateLimiter;
  GLOBAL: RateLimiter;
  REFUSED_CLIENTS?: string;
}

const PATH = "/v1/category";

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
      ...extra,
    },
  });
}

function error(status: number, code: string, extra: Record<string, string> = {}): Response {
  return json(status, { error: code }, extra);
}

function jsonContentType(value: string | null): boolean {
  if (value === null) return false;
  const [type, ...params] = value.split(";").map((s) => s.trim().toLowerCase());
  if (type !== "application/json") return false;
  return params.every((p) => p === "" || p === "charset=utf-8");
}

class TooLarge extends Error {}

async function readCapped(request: Request): Promise<Uint8Array> {
  const declared = request.headers.get("content-length");
  if (declared !== null && (!/^[0-9]+$/.test(declared) || Number(declared) > MAX_BODY_BYTES)) {
    throw new TooLarge();
  }
  if (request.body === null) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new TooLarge();
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

async function allowed(limiter: RateLimiter, key: string): Promise<boolean> {
  try {
    const { success } = await limiter.limit({ key });
    return success === true;
  } catch {
    return false;
  }
}

export async function handle(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname !== PATH) return error(404, "not_found");
  if (request.method !== "POST") return error(405, "method_not_allowed", { allow: "POST" });

  const client = request.headers.get("hasala-client");
  if (!validClient(client)) return error(400, "bad_request");
  if (refusedClients(env.REFUSED_CLIENTS).has(client)) return error(403, "client_refused");
  if (!jsonContentType(request.headers.get("content-type"))) return error(400, "bad_request");

  let bytes: Uint8Array;
  try {
    bytes = await readCapped(request);
  } catch (e) {
    if (e instanceof TooLarge) return error(413, "too_large");
    return error(400, "bad_request");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    return error(400, "bad_request");
  }
  const suggestion = parseSuggestion(parsed);
  if (suggestion === null) return error(400, "bad_request");

  if (!(await allowed(env.GLOBAL, "global"))) return error(429, "rate_limited");
  const ip = request.headers.get("cf-connecting-ip") ?? "";
  if (!(await allowed(env.PER_IP, ip === "" ? "none" : ip))) return error(429, "rate_limited");

  let result: unknown;
  try {
    result = await env.AI.run(MODEL, clefBody(suggestion));
  } catch {
    return error(503, "model_unavailable");
  }

  const answer = mapAnswer(result, suggestion);
  if (answer === null) return error(502, "bad_model_answer");
  return json(200, answer);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handle(request, env);
    } catch {
      return error(503, "model_unavailable");
    }
  },
};
