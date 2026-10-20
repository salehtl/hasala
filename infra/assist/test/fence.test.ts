import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..");

function stripJsonc(text: string): string {
  let out = "";
  let i = 0;
  let inString = false;
  while (i < text.length) {
    const ch = text[i]!;
    const next = text[i + 1];
    if (inString) {
      out += ch;
      if (ch === "\\") {
        out += next ?? "";
        i += 2;
        continue;
      }
      if (ch === '"') inString = false;
      i++;
      continue;
    }
    if (ch === '"') {
      inString = true;
      out += ch;
      i++;
      continue;
    }
    if (ch === "/" && next === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && next === "*") {
      i += 2;
      while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    out += ch;
    i++;
  }
  return out.replace(/,(\s*[}\]])/g, "$1");
}

function files(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...files(p));
    else out.push(p);
  }
  return out;
}

const rawConfig = readFileSync(join(ROOT, "wrangler.jsonc"), "utf8");
const config = JSON.parse(stripJsonc(rawConfig)) as Record<string, any>;

const FORBIDDEN = [
  "kv_namespaces",
  "d1_databases",
  "r2_buckets",
  "durable_objects",
  "queues",
  "vectorize",
  "analytics_engine_datasets",
  "services",
  "tail_consumers",
  "hyperdrive",
  "workflows",
  "dispatch_namespaces",
  "mtls_certificates",
  "browser",
  "send_email",
  "pipelines",
  "secrets_store_secrets",
  "unsafe",
  "migrations",
  "logfwdr",
  "streaming_tail_consumers",
];

function keysDeep(v: unknown, out: Set<string> = new Set()): Set<string> {
  if (Array.isArray(v)) for (const x of v) keysDeep(x, out);
  else if (typeof v === "object" && v !== null) {
    for (const [k, x] of Object.entries(v)) {
      out.add(k);
      keysDeep(x, out);
    }
  }
  return out;
}

describe("wrangler.jsonc fence", () => {
  test("the JSONC stripper keeps strings intact", () => {
    expect(JSON.parse(stripJsonc('{"a": "x // y", /* c */ "b": [1,], // z\n}'))).toEqual({ a: "x // y", b: [1] });
  });

  test("no storage, queue, service or tail binding at any level", () => {
    const keys = keysDeep(config);
    for (const k of FORBIDDEN) expect(keys.has(k)).toBe(false);
  });

  test("no env overrides", () => {
    expect(config.env).toBeUndefined();
  });

  test("logpush is off", () => {
    expect(config.logpush).toBe(false);
  });

  test("observability is off", () => {
    expect(config.observability?.enabled).toBe(false);
    expect(config.observability?.logs).toBeUndefined();
    expect(config.observability?.traces).toBeUndefined();
  });

  test("the only AI Gateway mention is the AI_GATEWAY var, and it names a dedicated gateway", () => {
    expect(rawConfig.match(/gateway/gi)).toEqual(["GATEWAY"]);
    expect(rawConfig).toContain('"AI_GATEWAY": "hasala-assist"');
    expect(config.vars.AI_GATEWAY).toBe("hasala-assist");
  });

  test("the bindings are exactly AI, PER_IP, GLOBAL and REFUSED_CLIENTS", () => {
    expect(config.name).toBe("hasala-assist");
    expect(config.ai).toEqual({ binding: "AI" });
    expect(config.ratelimits.map((r: any) => r.name).sort()).toEqual(["GLOBAL", "PER_IP"]);
    const byName = Object.fromEntries(config.ratelimits.map((r: any) => [r.name, r]));
    expect(byName.PER_IP.simple).toEqual({ limit: 30, period: 60 });
    expect(byName.GLOBAL.simple).toEqual({ limit: 600, period: 60 });
    expect(byName.PER_IP.namespace_id).not.toBe(byName.GLOBAL.namespace_id);
    expect(config.vars).toEqual({ REFUSED_CLIENTS: "", AI_GATEWAY: "hasala-assist" });
    const allowedTop = new Set([
      "$schema",
      "name",
      "main",
      "compatibility_date",
      "compatibility_flags",
      "routes",
      "workers_dev",
      "preview_urls",
      "observability",
      "logpush",
      "send_metrics",
      "ai",
      "ratelimits",
      "vars",
    ]);
    for (const k of Object.keys(config)) expect(allowedTop.has(k) ? k : `unexpected key ${k}`).toBe(k);
  });

  test("the route is the assist.hasala.app placeholder", () => {
    expect(config.routes).toEqual([{ pattern: "assist.hasala.app", custom_domain: true }]);
  });
});

const GATEWAY_ALLOWED = [
  "options: { gateway: { id: string; skipCache: true; collectLog: false } }",
  "AI_GATEWAY?: string;",
  'const gatewayId = (env.AI_GATEWAY ?? "").trim();',
  'if (gatewayId === "") return error(503, "model_unavailable");',
  "{ gateway: { id: gatewayId, skipCache: true, collectLog: false } }",
];

describe("source fence", () => {
  const sources = files(join(ROOT, "src")).map((p) => ({ p, text: readFileSync(p, "utf8") }));

  test("there is source to scan", () => {
    expect(sources.length).toBeGreaterThan(0);
  });

  test("no console calls", () => {
    for (const { p, text } of sources) expect(`${p}: ${/\bconsole\s*\./.test(text)}`).toBe(`${p}: false`);
  });

  test("no queueRequest or batch", () => {
    for (const { p, text } of sources) {
      expect(`${p}: ${/queueRequest/.test(text)}`).toBe(`${p}: false`);
      expect(`${p}: ${/\bbatch\b/i.test(text)}`).toBe(`${p}: false`);
    }
  });

  test("AI Gateway only in the allowed form: id from AI_GATEWAY, cache off, logging off", () => {
    const index = join(ROOT, "src", "index.ts");
    for (const { p, text } of sources) {
      let rest = text;
      if (p === index) {
        for (const allowed of GATEWAY_ALLOWED) {
          expect(`${allowed}: ${text.split(allowed).length - 1}`).toBe(`${allowed}: 1`);
          rest = rest.split(allowed).join("");
        }
      }
      expect(`${p}: ${/gateway/i.test(rest)}`).toBe(`${p}: false`);
      for (const re of [/\bcacheTtl\b/, /\bcacheKey\b/, /\bmetadata\b/, /\beventId\b/, /cf-aig-/i, /\bcollectLog\s*:\s*true\b/, /\bskipCache\s*:\s*false\b/, /\bdefault"/]) {
        expect(`${p}: ${re} ${re.test(text)}`).toBe(`${p}: ${re} false`);
      }
    }
    expect(sources.some(({ p }) => p === index)).toBe(true);
  });

  test("the AI_GATEWAY check rejects a gateway mention outside the allowed form", () => {
    const bad = [
      '{ gateway: { id: gatewayId, skipCache: true, collectLog: true } }',
      '{ gateway: { id: "default", skipCache: true, collectLog: false } }',
      '{ gateway: { id: gatewayId } }',
    ];
    for (const b of bad) {
      let rest = b;
      for (const allowed of GATEWAY_ALLOWED) rest = rest.split(allowed).join("");
      expect(/gateway/i.test(rest)).toBe(true);
    }
  });

  test("no storage or network APIs", () => {
    for (const { p, text } of sources) {
      for (const re of [/(?<!async\s)\bfetch\s*\(/,/\bcaches\b/, /\bwaitUntil\b/, /\blocalStorage\b/, /\bindexedDB\b/]) {
        expect(`${p}: ${re} ${re.test(text)}`).toBe(`${p}: ${re} false`);
      }
    }
  });
});
