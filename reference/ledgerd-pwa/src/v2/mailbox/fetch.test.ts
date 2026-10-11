/**
 * The Gmail fetch lane, end to end over the REAL normalizer, template executor
 * and A-R parser (the three conformance-locked pieces) and the real replay fold.
 * Only the network (Gmail REST, the broker, the op push) is faked — a stub of
 * the parse or the fold would assert this file's idea of them, not their
 * behaviour.
 *
 * The load-bearing proofs, each with its mutation named in the task report:
 *   - the three-gate trust boundary (verdict + listed sender + template hit),
 *     with the SENDER gate proven to bite;
 *   - the checkpoint advances ONLY after a page is fully accounted;
 *   - a duplicate ingest id is skipped;
 *   - a mailbox op folds normally (compat, §4) and flows through the existing
 *     possible-duplicate machinery (D7).
 */
import { beforeAll, describe, expect, it, vi } from "vitest";

import { setPlatform } from "@ledger/client/platform.registry";
import { webPlatform } from "@ledger/client/platform.web";
import { fold, INGEST_WRITER_ID, type LogEntry } from "@ledger/client/replay/replay";
import type { OpSpec } from "@ledger/client/outbox/outbox";
import type { Definition } from "@ledger/client/tmpl/exec";
import { validateOp, type Op } from "@ledger/client/wire/op";
import { ApiError } from "@ledger/client/net/client";

import { MailboxError } from "../mailboxConnect";
import { memoryKeyStore, type KeyStore } from "../mailboxToken";
import type { Writer } from "../writer";
import {
  GmailApiError,
  GmailHistoryGapError,
  type GmailApi,
  type GmailHistoryPage,
  type GmailMessagesPage,
  type GmailProfile,
  type GmailRawMessage,
} from "./gmail";
import { readMailboxState, readMailboxUnreadable, writeMailboxState } from "./state";
import { importSetAsideDomain, runFetchCycle, startMailboxLiveness, type FetchCycleDeps } from "./fetch";

const GRANT = "acct-1";
const NOW = new Date("2026-08-09T12:00:00.000Z");

beforeAll(() => {
  setPlatform(webPlatform);
});

// ---------------------------------------------------------------------------
// Fixtures — synthetic only (spec §5: no real transaction mail may be committed)
// ---------------------------------------------------------------------------

/** A published template for `example.com`, shaped like a real one. */
const TEMPLATE: Definition = {
  id: "example.card.v1",
  version: 1,
  bank: "example",
  normalizer_version: 1,
  match: { sender_domain: ["example.com"], subject_contains: ["Transaction"] },
  default_currency: "AED",
  date_from: "email",
  extract: [
    { field: "amount", type: "amount", source: "body", patterns: ["AED (?P<amt>[0-9,]+\\.[0-9]{2})"] },
    { field: "merchant", type: "text", source: "body", patterns: ["at (?P<v>[A-Z ]+) on"] },
    { field: "direction", type: "const", source: "body", value: "debit" },
  ],
  required: ["amount", "merchant"],
};

interface MessageOpts {
  from?: string;
  subject?: string;
  body?: string;
  /** The Authentication-Results value (after the header name). Omit for none. */
  ar?: string;
}

/** A passing Gmail A-R: exactly one, topmost, dkim=pass with a d= domain (D4). */
const PASS_AR = "mx.google.com; dkim=pass header.d=example.com; dmarc=pass header.from=example.com";

function message(opts: MessageOpts = {}): Uint8Array {
  const from = opts.from ?? "alerts@example.com";
  const subject = opts.subject ?? "Transaction alert";
  const body = opts.body ?? "You spent AED 125.00 at CARREFOUR MALL on 03/08/2026.";
  const headers = [
    ...(opts.ar === undefined ? [] : [`Authentication-Results: ${opts.ar}`]),
    `From: ${from}`,
    `Subject: ${subject}`,
    `Date: Mon, 03 Aug 2026 10:00:00 +0000`,
    `Content-Type: text/plain; charset=utf-8`,
  ].join("\r\n");
  return new TextEncoder().encode(`${headers}\r\n\r\n${body}\r\n`);
}

/** The base64url Gmail hands back for `format=raw` (unpadded). */
function rawOf(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function ingestIdOf(bytes: Uint8Array): string {
  return webPlatform.toHex(webPlatform.sha256(bytes)).toLowerCase();
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

interface FakeGmailOpts {
  /** message id -> raw bytes, served by getRaw and listed by both list calls. */
  messages: Record<string, Uint8Array>;
  profileHistoryId?: string;
  historyId?: string;
  /** Throw a history gap instead of listing (forces backfill). */
  historyGap?: boolean;
  /** getRaw ids that should throw instead of returning. */
  throwOnGet?: Set<string>;
  /** Per-id getRaw failure, thrown EVERY attempt. Overrides `throwOnGet`. */
  failOnGet?: Record<string, () => unknown>;
  /**
   * Ids the list calls report but `getRaw` has no bytes for — i.e. a message
   * deleted between the list and the download, which the real Gmail answers 404.
   */
  missingIds?: string[];
  /** Per-id internalDate override (ms-epoch string), else a fixed 2026-08-03. */
  internalDates?: Record<string, string>;
}

/**
 * The fake honours `from:` terms in a `messages.list` query, because two of the
 * things under test here are queries: the backfill's bank narrowing and the
 * set-aside import's per-domain fallback. A fake that returned everything
 * regardless would make both of those tests pass with the query deleted.
 */
function matchesQuery(q: string, bytes: Uint8Array): boolean {
  const terms = [...q.matchAll(/from:([a-z0-9.-]+)/g)].map((m) => m[1]!);
  if (terms.length === 0) return true;
  const from = /^From:\s*(.*)$/m.exec(new TextDecoder().decode(bytes))?.[1] ?? "";
  const domain = from.slice(from.lastIndexOf("@") + 1).trim().toLowerCase();
  return terms.some((t) => domain === t || domain.endsWith(`.${t}`));
}

function fakeGmail(opts: FakeGmailOpts): GmailApi & { getCalls: string[]; listQueries: string[]; inFlight: number[] } {
  const getCalls: string[] = [];
  const listQueries: string[] = [];
  const inFlight: number[] = [];
  let live = 0;
  const ids = [...Object.keys(opts.messages), ...(opts.missingIds ?? [])];
  return {
    getCalls,
    listQueries,
    inFlight,
    async profile(): Promise<GmailProfile> {
      return { historyId: opts.profileHistoryId ?? "1000" };
    },
    async historyList(): Promise<GmailHistoryPage> {
      if (opts.historyGap) throw new GmailHistoryGapError("500");
      return { added: ids, historyId: opts.historyId ?? "1001" };
    },
    async messagesList(q: string): Promise<GmailMessagesPage> {
      listQueries.push(q);
      const hits = ids.filter((id) => {
        const bytes = opts.messages[id];
        return bytes === undefined || matchesQuery(q, bytes);
      });
      return { messages: hits.map((id) => ({ id })) };
    },
    async getRaw(id: string): Promise<GmailRawMessage> {
      getCalls.push(id);
      live += 1;
      inFlight.push(live);
      try {
        // Yield once so concurrent callers actually overlap and `inFlight` means
        // something; without it every call resolves before the next begins.
        await Promise.resolve();
        const fail = opts.failOnGet?.[id];
        if (fail !== undefined) throw fail();
        if (opts.throwOnGet?.has(id)) throw new GmailApiError(500, "mailbox message");
        const bytes = opts.messages[id];
        if (bytes === undefined) throw new GmailApiError(404, "mailbox message");
        // A fixed arrival day so a fixture's transaction date is deterministic.
        const internalDate = opts.internalDates?.[id] ?? String(Date.parse("2026-08-03T10:00:00Z"));
        return { id, rawBase64Url: rawOf(bytes), internalDate };
      } finally {
        live -= 1;
      }
    },
  };
}

interface FakeWriterOpts {
  flush?: () => Promise<void>;
  pending?: Op[];
}

function fakeWriter(opts: FakeWriterOpts = {}): Writer & { authored: OpSpec[] } {
  const authored: OpSpec[] = [];
  const pending = opts.pending ?? [];
  return {
    authored,
    get pending(): readonly Op[] {
      return pending;
    },
    enqueueMany(specs: readonly OpSpec[]): void {
      authored.push(...specs);
    },
    flush: opts.flush ?? (async (): Promise<void> => undefined),
  };
}

interface DepsOpts extends Partial<FetchCycleDeps> {
  gmail?: GmailApi;
}

function makeDeps(over: DepsOpts = {}): { deps: FetchCycleDeps; writer: Writer & { authored: OpSpec[] }; store: KeyStore } {
  const writer = (over.writer as Writer & { authored: OpSpec[] }) ?? fakeWriter();
  const store = over.store ?? memoryKeyStore();
  let n = 0;
  const deps: FetchCycleDeps = {
    syncToHead: over.syncToHead ?? (async (): Promise<void> => undefined),
    mintAccessToken: over.mintAccessToken ?? (async (): Promise<string> => "access-token"),
    loadSenders: over.loadSenders ?? (async (): Promise<readonly string[]> => ["example.com"]),
    loadTemplates: over.loadTemplates ?? (async (): Promise<readonly Definition[]> => [TEMPLATE]),
    alreadyIngested: over.alreadyIngested ?? ((): boolean => false),
    writer,
    newID: over.newID ?? ((): string => `txn-${++n}`),
    grantId: over.grantId ?? GRANT,
    makeGmail: over.makeGmail ?? ((): GmailApi => over.gmail ?? fakeGmail({ messages: {} })),
    store,
    now: over.now ?? ((): Date => NOW),
    // Retries are real in production; here they must cost no wall-clock time, or
    // the two "halts after its retries" tests would burn seconds apiece.
    sleep: over.sleep ?? (async (): Promise<void> => undefined),
    ...(over.maxMessageBytes === undefined ? {} : { maxMessageBytes: over.maxMessageBytes }),
  };
  return { deps, writer, store };
}

function payloadOf(spec: OpSpec): Record<string, unknown> {
  return spec.payload as Record<string, unknown>;
}

/**
 * A store already past its first backfill, so the cycle takes the INCREMENTAL
 * path (`users.history.list`, which takes no query and hands back everything).
 *
 * Set-aside is a client-side decision and the incremental path is where it does
 * all its work: a backfill narrows to the bank set server-side, so a newsletter
 * is not even listed there. Tests about what happens to non-bank mail therefore
 * belong on this path — asserting it from a backfill would only be asserting
 * that the fake ignores the query.
 */
async function caughtUpStore(historyId = "500"): Promise<KeyStore> {
  const store = memoryKeyStore();
  await writeMailboxState({ historyId, backfillDays: 30, lastCycleAt: null, unreadable: { count: 0, recent: [] } }, store);
  return store;
}

// ---------------------------------------------------------------------------
// Step 1/2: behaviour
// ---------------------------------------------------------------------------

describe("a message that passes all three gates", () => {
  it("becomes a no-review op carrying entry_method mailbox and provenance", async () => {
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) } });
    const { deps, writer, store } = makeDeps({ gmail });

    const report = await runFetchCycle(deps);

    expect(report).toEqual({ fetched: 1, ops: 1, review: 0, unreadable: 0, setAside: 0 });
    expect(writer.authored).toHaveLength(1);
    const spec = writer.authored[0]!;
    expect(spec.type).toBe("txn_ingested");
    const p = payloadOf(spec);
    expect(p["entry_method"]).toBe("mailbox");
    expect(p["needs_review"]).toBe(false);
    expect(p["amount_minor"]).toBe("12500");
    expect(p["currency"]).toBe("AED");
    expect(p["direction"]).toBe("debit");
    expect(p["merchant_raw"]).toBe("CARREFOUR MALL");
    expect(p["tier"]).toBe("template");
    expect(p["provenance"]).toEqual({ provider: "gmail", grant_id: GRANT, message_id: "m1" });
    // A client may never claim server-verified origin (D6a).
    expect(p).not.toHaveProperty("verified_origin_domain");
    // Checkpoint advanced to the head captured before the backfill.
    expect((await readMailboxState(store)).historyId).toBe("1000");
  });
});

describe("the three gates, each required", () => {
  it("needs review when the sender is not on the list (the sender gate bites)", async () => {
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) } });
    // Verdict passes and the template hits, but example.com is not listed.
    const { deps, writer } = makeDeps({ gmail, loadSenders: async () => ["other-bank.test"] });

    const report = await runFetchCycle(deps);

    expect(report).toMatchObject({ fetched: 1, ops: 1, review: 1 });
    const p = payloadOf(writer.authored[0]!);
    // The gate bites where it matters: this does NOT file itself.
    expect(p["needs_review"]).toBe(true);
    // …but the card is not empty. A template read the message, so its
    // extraction rides along as a prefill for the human to confirm. Throwing it
    // away made every first-backfill card blank, since a new account's sender
    // list is empty by construction and nothing could ever pass this gate.
    expect(p["unparsed"]).toBe(false);
    expect(p["amount_minor"]).toBeDefined();
    expect(p["entry_method"]).toBe("mailbox");
    expect(p["provenance"]).toMatchObject({ message_id: "m1" });
  });

  it("needs review when the Authentication-Results verdict does not pass, even when listed", async () => {
    // No mx.google.com A-R at all — the verdict is no_ar, never trusted.
    const gmail = fakeGmail({ messages: { m1: message({ ar: undefined }) } });
    const { deps, writer } = makeDeps({ gmail, loadSenders: async () => ["example.com"] });

    const report = await runFetchCycle(deps);

    expect(report).toMatchObject({ ops: 1, review: 1 });
    // Untrusted, so it never files itself — but the extraction is kept.
    expect(payloadOf(writer.authored[0]!)["needs_review"]).toBe(true);
    expect(payloadOf(writer.authored[0]!)["amount_minor"]).toBeDefined();
  });

  it("needs review on an explicit dkim=fail verdict, even from a listed sender", async () => {
    // A present-but-FAILING mx.google.com A-R (distinct from the absent case
    // above): neither dkim=pass nor dmarc=pass, so gmailVerdict reason is "fail".
    const failAr = "mx.google.com; dkim=fail header.d=example.com; dmarc=fail header.from=example.com";
    const gmail = fakeGmail({ messages: { m1: message({ ar: failAr }) } });
    const { deps, writer } = makeDeps({ gmail, loadSenders: async () => ["example.com"] });

    const report = await runFetchCycle(deps);

    expect(report).toMatchObject({ ops: 1, review: 1 });
    expect(payloadOf(writer.authored[0]!)["needs_review"]).toBe(true);
  });

  it("needs review when no template reads the message, even trusted and listed", async () => {
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR, body: "Your statement is ready." }) } });
    const { deps, writer } = makeDeps({ gmail });

    const report = await runFetchCycle(deps);

    expect(report).toMatchObject({ ops: 1, review: 1 });
    expect(payloadOf(writer.authored[0]!)["unparsed"]).toBe(true);
  });
});

describe("unreadable messages are accounted, never silently skipped", () => {
  it("counts an over-cap message as unreadable and still advances the checkpoint", async () => {
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) } });
    const { deps, writer, store } = makeDeps({ gmail, maxMessageBytes: 10 });

    const report = await runFetchCycle(deps);

    expect(report).toEqual({ fetched: 1, ops: 0, review: 0, unreadable: 1, setAside: 0 });
    expect(writer.authored).toHaveLength(0);
    expect((await readMailboxState(store)).historyId).toBe("1000");
  });

  it("records an over-cap message DURABLY, surviving into a fresh state read", async () => {
    const store = memoryKeyStore();
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) }, internalDates: { m1: "1754215200000" } });
    const { deps } = makeDeps({ gmail, store, maxMessageBytes: 10 });

    await runFetchCycle(deps);

    // A brand-new read of the persisted state (a later session) still sees it —
    // the count is durable, not a transient CycleReport field. Mutation that
    // makes it transient (drop the writeMailboxState unreadable field) fails here.
    const log = await readMailboxUnreadable(store);
    expect(log.count).toBe(1);
    expect(log.recent).toEqual([{ message_id: "m1", reason: "over_cap", internalDate: "1754215200000" }]);
    // Still accounted: the checkpoint advanced past it.
    expect((await readMailboxState(store)).historyId).toBe("1000");
  });

  it("does not double-count the same unreadable message across cycles", async () => {
    const store = memoryKeyStore();
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) } });
    const { deps } = makeDeps({ gmail, store, maxMessageBytes: 10 });

    await runFetchCycle(deps);
    await runFetchCycle(deps); // same message re-listed (backfill overlap)

    expect((await readMailboxUnreadable(store)).count).toBe(1);
  });

  it("routes a garbage internalDate to unreadable and completes the cycle (fail-soft)", async () => {
    const store = memoryKeyStore();
    // A value that overflows the Date range: new Date(ms).toISOString() throws.
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) }, internalDates: { m1: "999999999999999999999" } });
    const { deps, writer } = makeDeps({ gmail, store });

    const report = await runFetchCycle(deps);

    // The cycle did NOT throw; the one bad message is unreadable, no op authored.
    expect(report).toEqual({ fetched: 1, ops: 0, review: 0, unreadable: 1, setAside: 0 });
    expect(writer.authored).toHaveLength(0);
    expect((await readMailboxUnreadable(store)).recent[0]).toMatchObject({ message_id: "m1", reason: "bad_date" });
    expect((await readMailboxState(store)).historyId).toBe("1000");
  });
});

describe("the A-R ceiling bounds the HEADER BLOCK, not the whole message", () => {
  it("auto-files a 300 KB HTML bank message whose verdict passes", async () => {
    // `authres` answers parse_error above 256 KiB — a bound meant for a header
    // block. Handed the whole message, every mail between 256 KiB and the 1 MB
    // per-message cap failed gate 1 on SIZE alone and could never auto-file. An
    // HTML bank alert with embedded images is routinely that big.
    const filler = "<!-- " + "x".repeat(300 * 1024) + " -->";
    const big = message({
      ar: PASS_AR,
      body: `You spent AED 125.00 at CARREFOUR MALL on 03/08/2026.\r\n${filler}`,
    });
    expect(big.length).toBeGreaterThan(256 * 1024);
    const gmail = fakeGmail({ messages: { m1: big } });
    const { deps, writer } = makeDeps({ gmail });

    const report = await runFetchCycle(deps);

    expect(report).toMatchObject({ fetched: 1, ops: 1, review: 0, unreadable: 0 });
    // needs_review false is the proof: gate 1 (the A-R verdict) passed.
    expect(payloadOf(writer.authored[0]!)["needs_review"]).toBe(false);
    expect(payloadOf(writer.authored[0]!)["amount_minor"]).toBe("12500");
  });
});

describe("the checkpoint advances only after a page is fully accounted", () => {
  it("leaves the checkpoint unmoved when a message throws mid-page", async () => {
    const store = memoryKeyStore();
    await writeMailboxState({ historyId: "500", backfillDays: 30, lastCycleAt: null, unreadable: { count: 0, recent: [] } }, store);
    const gmail = fakeGmail({
      messages: { m1: message({ ar: PASS_AR }), m2: message({ ar: PASS_AR, body: "Second." }) },
      historyId: "600",
      throwOnGet: new Set(["m2"]),
    });
    const { deps } = makeDeps({ gmail, store });

    const report = await runFetchCycle(deps);

    expect(report.haltedOn).toBe("error");
    // The invariant: a thrown mid-page error MUST NOT advance the checkpoint.
    // Mutation that breaks this (write the checkpoint before the loop) fails here.
    expect((await readMailboxState(store)).historyId).toBe("500");
  });
});

// ---------------------------------------------------------------------------
// One unfetchable message must not wedge the lane (the reported ENBD symptom)
// ---------------------------------------------------------------------------

describe("a message Gmail will never serve is stepped over, not stared at forever", () => {
  /** Ten bank messages, with `gone` listed among them but never downloadable. */
  function tenWithAHole(): ReturnType<typeof fakeGmail> {
    const messages: Record<string, Uint8Array> = {};
    for (let i = 1; i <= 9; i += 1) {
      messages[`m${i}`] = message({ ar: PASS_AR, body: `You spent AED ${i}0.00 at SHOP ${i} on 03/08/2026.` });
    }
    return fakeGmail({ messages, missingIds: ["gone"], historyId: "600" });
  }

  it("processes the other nine and ADVANCES the checkpoint past a 404", async () => {
    const store = memoryKeyStore();
    await writeMailboxState({ historyId: "500", backfillDays: 30, lastCycleAt: null, unreadable: { count: 0, recent: [] } }, store);
    const gmail = tenWithAHole();
    const { deps, writer } = makeDeps({ gmail, store });

    const report = await runFetchCycle(deps);

    // This is the whole defect. Before the fix a single 404 rejected the entire
    // `Promise.all`, so ops was 0, haltedOn was "error", the checkpoint stayed
    // at 500 and the SAME page was re-read and re-failed every 60 seconds
    // forever — "0 emails read", permanently, with nine perfectly good bank
    // messages sitting behind it.
    expect(report.haltedOn).toBeUndefined();
    expect(report.ops).toBe(9);
    expect(writer.authored).toHaveLength(9);
    expect(report.unreadable).toBe(1);
    expect((await readMailboxState(store)).historyId).toBe("600");
  });

  it("records the dead message durably, so it is visible rather than forgotten", async () => {
    const store = memoryKeyStore();
    const { deps } = makeDeps({ gmail: tenWithAHole(), store });

    await runFetchCycle(deps);

    const log = await readMailboxUnreadable(store);
    expect(log.count).toBe(1);
    expect(log.recent).toEqual([{ message_id: "gone", reason: "gone" }]);
  });

  it("does not re-count the same dead message on the next cycle", async () => {
    const store = memoryKeyStore();
    const { deps } = makeDeps({ gmail: tenWithAHole(), store });

    await runFetchCycle(deps);
    await runFetchCycle(deps);

    expect((await readMailboxUnreadable(store)).count).toBe(1);
  });

  it("treats a 410 the same as a 404 — permanently gone is permanently gone", async () => {
    const gmail = fakeGmail({
      messages: { m1: message({ ar: PASS_AR }) },
      failOnGet: { m2: () => new GmailApiError(410, "mailbox message") },
      missingIds: ["m2"],
    });
    const { deps, writer } = makeDeps({ gmail });

    const report = await runFetchCycle(deps);

    expect(report.haltedOn).toBeUndefined();
    expect(writer.authored).toHaveLength(1);
    expect(report.unreadable).toBe(1);
  });

  it("treats a 200 with no raw body as gone, not as a reason to stall", async () => {
    // `gmail.ts` reports a body-less answer as a GmailApiError carrying the OK
    // status. Retrying that forever would be the same wedge in a new coat.
    const gmail = fakeGmail({
      messages: { m1: message({ ar: PASS_AR }) },
      failOnGet: { m2: () => new GmailApiError(200, "mailbox message returned no raw body") },
      missingIds: ["m2"],
    });
    const { deps, writer } = makeDeps({ gmail });

    const report = await runFetchCycle(deps);

    expect(report.haltedOn).toBeUndefined();
    expect(writer.authored).toHaveLength(1);
    expect(report.unreadable).toBe(1);
  });
});

describe("a transient download failure is retried, not turned into a permanent skip", () => {
  it("succeeds on a retry and completes the cycle normally", async () => {
    const inner = fakeGmail({
      messages: {
        m1: message({ ar: PASS_AR }),
        m2: message({ ar: PASS_AR, body: "You spent AED 9.00 at SHOP X on 03/08/2026." }),
      },
      historyId: "600",
    });
    let blipped = false;
    const flaky: GmailApi = {
      ...inner,
      async getRaw(id: string) {
        if (id === "m2" && !blipped) {
          blipped = true;
          throw new GmailApiError(429, "mailbox message");
        }
        return inner.getRaw(id);
      },
    };
    const store = memoryKeyStore();
    const { deps, writer } = makeDeps({ gmail: flaky, store });

    const report = await runFetchCycle(deps);

    expect(report.haltedOn).toBeUndefined();
    // Both messages became ops: the blip cost a retry, not a message — and it
    // certainly did not become a `gone` record, which would have lost m2.
    expect(writer.authored).toHaveLength(2);
    expect(report.unreadable).toBe(0);
    expect((await readMailboxState(store)).historyId).toBe("1000");
  });

  it("narrows the download pipe to one after Gmail says 429", async () => {
    const messages: Record<string, Uint8Array> = {};
    for (let i = 1; i <= 12; i += 1) {
      messages[`m${i}`] = message({ ar: PASS_AR, body: `You spent AED ${i}.00 at SHOP ${i} on 03/08/2026.` });
    }
    let first = true;
    const inner = fakeGmail({ messages });
    const limited: GmailApi & { inFlight: number[] } = {
      ...inner,
      async getRaw(id: string) {
        if (first) {
          first = false;
          throw new GmailApiError(429, "mailbox message");
        }
        return inner.getRaw(id);
      },
    };
    const { deps } = makeDeps({ gmail: limited });

    await runFetchCycle(deps);

    // The first chunk overlapped up to FETCH_CONCURRENCY requests; every chunk
    // after the 429 must be one at a time, or the retries are fighting the same
    // five siblings that provoked the refusal in the first place.
    expect(Math.max(...inner.inFlight)).toBeGreaterThan(1);
    const afterFirstChunk = inner.inFlight.slice(6);
    expect(afterFirstChunk.length).toBeGreaterThan(0);
    expect(Math.max(...afterFirstChunk)).toBe(1);
  });

  it("halts on a 401 immediately, without retrying every message on the page", async () => {
    const messages: Record<string, Uint8Array> = { m1: message({ ar: PASS_AR }), m2: message({ ar: PASS_AR }) };
    const gmail = fakeGmail({
      messages,
      failOnGet: {
        m1: () => new GmailApiError(401, "mailbox message"),
        m2: () => new GmailApiError(401, "mailbox message"),
      },
    });
    const { deps } = makeDeps({ gmail });

    const report = await runFetchCycle(deps);

    expect(report.haltedOn).toBe("error");
    expect(report.haltedDetail).toContain("401");
    // A dead token is an account fact, not a message fact: exactly one attempt
    // each, no backoff, no `gone` records invented for a page that is fine.
    expect(gmail.getCalls).toEqual(["m1", "m2"]);
    expect(report.unreadable).toBe(0);
  });

  it("still halts with the checkpoint unmoved when a transient failure outlives its retries", async () => {
    const store = memoryKeyStore();
    await writeMailboxState({ historyId: "500", backfillDays: 30, lastCycleAt: null, unreadable: { count: 0, recent: [] } }, store);
    const gmail = fakeGmail({
      messages: { m1: message({ ar: PASS_AR }), m2: message({ ar: PASS_AR, body: "Second." }) },
      historyId: "600",
      failOnGet: { m2: () => new GmailApiError(503, "mailbox message") },
    });
    const { deps } = makeDeps({ gmail, store });

    const report = await runFetchCycle(deps);

    expect(report.haltedOn).toBe("error");
    // Three attempts, then the halt — and NOT a `gone` record, because a 503 is
    // no evidence the message is gone. Recording it would lose a real message.
    expect(gmail.getCalls.filter((id) => id === "m2")).toHaveLength(3);
    expect(report.unreadable).toBe(0);
    expect((await readMailboxState(store)).historyId).toBe("500");
    expect((await readMailboxUnreadable(store)).count).toBe(0);
  });
});

describe("a duplicate ingest id is skipped, not re-ingested", () => {
  it("skips a message whose op has already folded", async () => {
    const bytes = message({ ar: PASS_AR });
    const gmail = fakeGmail({ messages: { m1: bytes } });
    const seen = ingestIdOf(bytes);
    const { deps, writer } = makeDeps({ gmail, alreadyIngested: (id) => id === seen });

    const report = await runFetchCycle(deps);

    expect(report).toEqual({ fetched: 1, ops: 0, review: 0, unreadable: 0, setAside: 0 });
    expect(writer.authored).toHaveLength(0);
  });

  it("skips a message already queued but not yet pushed (budget resume safety)", async () => {
    const bytes = message({ ar: PASS_AR });
    const gmail = fakeGmail({ messages: { m1: bytes } });
    const pendingOp = {
      v: 1,
      type: "txn_ingested",
      op_id: "queued-1",
      ingest_id: ingestIdOf(bytes),
    } as unknown as Op;
    const writer = fakeWriter({ pending: [pendingOp] });
    const { deps } = makeDeps({ gmail, writer });

    const report = await runFetchCycle(deps);

    expect(report.ops).toBe(0);
    expect(writer.authored).toHaveLength(0);
  });
});

describe("a full account halts the cycle without moving the checkpoint", () => {
  it("reports budget_full and keeps the checkpoint intact", async () => {
    const store = memoryKeyStore();
    await writeMailboxState({ historyId: "500", backfillDays: 30, lastCycleAt: null, unreadable: { count: 0, recent: [] } }, store);
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) }, historyId: "600" });
    const writer = fakeWriter({
      flush: async () => {
        throw new ApiError(413, "account_full", "", "POST /api/v1/sync: 413 account_full");
      },
    });
    const { deps } = makeDeps({ gmail, writer, store });

    const report = await runFetchCycle(deps);

    expect(report.haltedOn).toBe("budget_full");
    expect(report.ops).toBe(1); // the op was authored and stays durably queued
    expect((await readMailboxState(store)).historyId).toBe("500");
  });
});

describe("a history gap falls back to a full backfill", () => {
  it("resyncs via messages.list and checkpoints the profile head", async () => {
    const store = memoryKeyStore();
    await writeMailboxState({ historyId: "500", backfillDays: 90, lastCycleAt: null, unreadable: { count: 0, recent: [] } }, store);
    const gmail = fakeGmail({
      messages: { m1: message({ ar: PASS_AR }) },
      historyGap: true,
      profileHistoryId: "2000",
    });
    const { deps, writer } = makeDeps({ gmail, store });

    const report = await runFetchCycle(deps);

    expect(report.ops).toBe(1);
    expect(writer.authored).toHaveLength(1);
    expect((await readMailboxState(store)).historyId).toBe("2000");
  });
});

describe("no usable token", () => {
  it("halts on reconnect_required and fetches nothing", async () => {
    const { deps, writer } = makeDeps({
      mintAccessToken: async () => {
        throw new MailboxError("reconnect_required", "reconnect the mailbox");
      },
    });

    const report = await runFetchCycle(deps);

    expect(report).toEqual({ fetched: 0, ops: 0, review: 0, unreadable: 0, setAside: 0, haltedOn: "reconnect_required" });
    expect(writer.authored).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// Transaction mail vs everything else: only bank-domain mail becomes an op
// ---------------------------------------------------------------------------

/** A newsletter: no template names its domain, and it is on no sender list. */
function newsletter(): Uint8Array {
  return message({
    from: "digest@news.example.test",
    subject: "Your weekly digest",
    body: "Here is what happened this week.",
    ar: "mx.google.com; dkim=pass header.d=news.example.test; dmarc=pass header.from=news.example.test",
  });
}

describe("mail from a domain outside the bank set is set aside, never authored", () => {
  it("authors NO op for a newsletter and records it durably instead", async () => {
    const store = await caughtUpStore();
    const gmail = fakeGmail({ messages: { m1: newsletter() }, historyId: "600" });
    const { deps, writer } = makeDeps({ gmail, store });

    const report = await runFetchCycle(deps);

    // The harm this whole change exists to stop: an empty needs-review op that
    // the append-only log makes permanent on every device, forever.
    expect(writer.authored).toHaveLength(0);
    expect(report).toEqual({ fetched: 1, ops: 0, review: 0, unreadable: 0, setAside: 1 });

    const log = (await readMailboxState(store)).setAside!;
    expect(log.count).toBe(1);
    expect(log.recent[0]).toMatchObject({
      message_id: "m1",
      domain: "news.example.test",
      subject: "Your weekly digest",
    });
    // Accounted: the checkpoint still advanced past it.
    expect((await readMailboxState(store)).historyId).toBe("600");
  });

  it("still authors a needs-review op for a BANK domain that hits no template", async () => {
    // example.com is in the bank set (the template names it) but the body is
    // unreadable to every template. This is a real bank message we could not
    // parse — it must stay an op, and must NOT be set aside.
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR, body: "Your statement is ready." }) } });
    const store = memoryKeyStore();
    const { deps, writer } = makeDeps({ gmail, store });

    const report = await runFetchCycle(deps);

    expect(report).toMatchObject({ fetched: 1, ops: 1, review: 1, setAside: 0 });
    expect(payloadOf(writer.authored[0]!)["unparsed"]).toBe(true);
    expect((await readMailboxState(store)).setAside!.count).toBe(0);
  });

  it("counts a template's domain as a bank even when the account trusts no senders yet", async () => {
    // A new account's sender list is empty by construction, so the template set
    // is the only thing that can tell bank mail from a newsletter. On the
    // incremental path, where no query narrows anything, that decision is the
    // client's alone.
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }), m2: newsletter() } });
    const store = await caughtUpStore();
    const { deps, writer } = makeDeps({ gmail, store, loadSenders: async () => [] });

    const report = await runFetchCycle(deps);

    expect(report).toMatchObject({ fetched: 2, ops: 1, review: 1, setAside: 1 });
    expect(payloadOf(writer.authored[0]!)["provenance"]).toMatchObject({ message_id: "m1" });
  });

  it("counts a TRUSTED sender as a bank even when no template reads it", async () => {
    const gmail = fakeGmail({ messages: { m1: newsletter() } });
    const { deps, writer } = makeDeps({ gmail, loadSenders: async () => ["news.example.test"] });

    const report = await runFetchCycle(deps);

    expect(report).toMatchObject({ ops: 1, review: 1, setAside: 0 });
    expect(writer.authored).toHaveLength(1);
  });

  it("does not persist set-aside entries when the page throws mid-way", async () => {
    const store = memoryKeyStore();
    await writeMailboxState(
      { historyId: "500", backfillDays: 30, lastCycleAt: null, unreadable: { count: 0, recent: [] } },
      store,
    );
    const gmail = fakeGmail({
      messages: { m1: newsletter(), m2: message({ ar: PASS_AR }) },
      historyId: "600",
      throwOnGet: new Set(["m2"]),
    });
    const { deps } = makeDeps({ gmail, store });

    const report = await runFetchCycle(deps);

    expect(report.haltedOn).toBe("error");
    // Accounting and the checkpoint move together or not at all.
    expect((await readMailboxState(store)).historyId).toBe("500");
    expect((await readMailboxState(store)).setAside!.count).toBe(0);
  });
});

describe("the backfill query is narrowed to the bank set, and falls back safely", () => {
  it("asks Gmail only for the bank domains when the set is non-empty", async () => {
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) } });
    const { deps } = makeDeps({ gmail, loadSenders: async () => ["mashreq.test"] });

    await runFetchCycle(deps);

    expect(gmail.listQueries).toEqual(["newer_than:30d -in:trash {from:example.com OR from:mashreq.test}"]);
  });

  it("asks for the whole window when the bank set is EMPTY", async () => {
    // No templates and no trusted senders: filtering here would import nothing,
    // forever, because the first bank message is what creates the card that
    // trusts the domain.
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) } });
    const { deps } = makeDeps({ gmail, loadSenders: async () => [], loadTemplates: async () => [] });

    await runFetchCycle(deps);

    expect(gmail.listQueries).toEqual(["newer_than:30d -in:trash"]);
  });

  it("asks for the whole window rather than truncating an over-long sender list", async () => {
    const many = Array.from({ length: 40 }, (_, i) => `bank${i}.test`);
    const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR }) } });
    const { deps } = makeDeps({ gmail, loadSenders: async () => many });

    await runFetchCycle(deps);

    expect(gmail.listQueries).toEqual(["newer_than:30d -in:trash"]);
  });
});

describe("trust a domain, then import what was set aside", () => {
  it("re-fetches that domain's set-aside messages, authors them, and forgets them", async () => {
    const store = await caughtUpStore();
    const gmail = fakeGmail({ messages: { m1: newsletter(), m2: message({ ar: PASS_AR }) }, historyId: "600" });
    const { deps, writer } = makeDeps({ gmail, store });

    await runFetchCycle(deps);
    expect((await readMailboxState(store)).setAside!.count).toBe(1);
    expect(writer.authored).toHaveLength(1); // the bank message only

    // The user says "this is my bank": the domain joins the sender list (the
    // caller's `trustSender`) and the set-aside messages are re-fetched by id.
    const trusted = makeDeps({
      gmail,
      store,
      writer,
      loadSenders: async () => ["example.com", "news.example.test"],
    });
    const report = await importSetAsideDomain(trusted.deps, "news.example.test");

    expect(report).toMatchObject({ fetched: 1, ops: 1 });
    expect(writer.authored).toHaveLength(2);
    expect(payloadOf(writer.authored[1]!)["provenance"]).toMatchObject({ message_id: "m1" });
    // No longer set aside: it was imported.
    expect((await readMailboxState(store)).setAside!.count).toBe(0);
    // The checkpoint is untouched by an import — it is not a catch-up.
    expect((await readMailboxState(store)).historyId).toBe("600");
  });

  it("keeps the entries set aside when the push is refused, so a retry still finds them", async () => {
    const store = await caughtUpStore();
    const gmail = fakeGmail({ messages: { m1: newsletter() } });
    const { deps } = makeDeps({ gmail, store });
    await runFetchCycle(deps);

    const writer = fakeWriter({
      flush: async () => {
        throw new ApiError(413, "account_full", "", "POST /api/v1/sync: 413 account_full");
      },
    });
    const trusted = makeDeps({ gmail, store, writer, loadSenders: async () => ["news.example.test"] });
    const report = await importSetAsideDomain(trusted.deps, "news.example.test");

    expect(report.haltedOn).toBe("budget_full");
    expect((await readMailboxState(store)).setAside!.count).toBe(1);
  });

  // -------------------------------------------------------------------------
  // The set-aside ring is capped and GLOBAL, so unrelated mail evicts a bank's
  // entries. "This is my bank" must still import what it claims to.
  // -------------------------------------------------------------------------

  it("imports a message the set-aside ring evicted, by asking Gmail for the sender", async () => {
    const store = memoryKeyStore();
    const evicted = message({
      from: "alerts@news.example.test",
      subject: "Your card was used",
      body: "You spent AED 42.00 at OLD SHOP on 01/08/2026.",
      ar: "mx.google.com; dkim=pass header.d=news.example.test; dmarc=pass header.from=news.example.test",
    });
    const gmail = fakeGmail({ messages: { evicted, kept: newsletter() } });

    // The ring remembers only `kept` — `evicted` fell off it, exactly as it
    // would after 200 unrelated messages. It is still in the mailbox, and Gmail
    // still answers a `from:` query with it.
    await writeMailboxState(
      {
        historyId: "1000",
        backfillDays: 30,
        lastCycleAt: null,
        unreadable: { count: 0, recent: [] },
        setAside: {
          count: 1,
          dropped: 1,
          recent: [{ message_id: "kept", domain: "news.example.test", subject: "Your weekly digest", receivedAt: "2026-08-03T10:00:00.000Z" }],
        },
      },
      store,
    );

    const { deps, writer } = makeDeps({ gmail, store, loadSenders: async () => ["news.example.test"] });
    const report = await importSetAsideDomain(deps, "news.example.test");

    // Before the fix this imported ONE message — whatever survived the ring —
    // while the surface had counted the evicted one too. The user tapped a
    // button that said "import from here" and silently got less.
    expect(report.fetched).toBe(2);
    expect(report.ops).toBe(2);
    const imported = writer.authored.map((s) => (payloadOf(s)["provenance"] as { message_id: string }).message_id).sort();
    expect(imported).toEqual(["evicted", "kept"]);
    expect(gmail.listQueries).toEqual(["newer_than:30d -in:trash from:news.example.test"]);
  });

  it("asks only for that sender, never for the whole mailbox", async () => {
    const store = await caughtUpStore();
    const gmail = fakeGmail({ messages: { m1: newsletter(), m2: message({ ar: PASS_AR }) } });
    const { deps } = makeDeps({ gmail, store });
    await runFetchCycle(deps);

    const writer = fakeWriter();
    const trusted = makeDeps({ gmail, store, writer, loadSenders: async () => ["news.example.test"] });
    const report = await importSetAsideDomain(trusted.deps, "news.example.test");

    // m2 is example.com's and must NOT be dragged in by a trust decision about
    // news.example.test — the widened input set is still one sender wide.
    expect(report.fetched).toBe(1);
    expect(payloadOf(writer.authored[0]!)["provenance"]).toMatchObject({ message_id: "m1" });
  });

  it("still imports the retained ids when the domain is not query-safe", async () => {
    // A domain the query builder refuses must degrade to the ring, never to
    // nothing — the button has to do something.
    const store = await caughtUpStore();
    const odd = message({
      from: 'alerts@has space.test',
      subject: "Statement",
      body: "Nothing parseable here.",
    });
    const gmail = fakeGmail({ messages: { m1: odd } });
    const { deps } = makeDeps({ gmail, store });
    await runFetchCycle(deps);
    expect((await readMailboxState(store)).setAside!.count).toBe(1);

    const writer = fakeWriter();
    const trusted = makeDeps({ gmail, store, writer, loadSenders: async () => ["has space.test"] });
    const report = await importSetAsideDomain(trusted.deps, "has space.test");

    expect(report.ops).toBe(1);
    expect(gmail.listQueries).toEqual([]); // no query was built, and none was needed
  });

  it("steps over a set-aside message that has since been deleted", async () => {
    const store = memoryKeyStore();
    await writeMailboxState(
      {
        historyId: "1000",
        backfillDays: 30,
        lastCycleAt: null,
        unreadable: { count: 0, recent: [] },
        setAside: {
          count: 2,
          dropped: 0,
          recent: [
            { message_id: "deleted", domain: "news.example.test", subject: "Gone", receivedAt: "2026-08-01T00:00:00.000Z" },
            { message_id: "m1", domain: "news.example.test", subject: "Here", receivedAt: "2026-08-02T00:00:00.000Z" },
          ],
        },
      },
      store,
    );
    const gmail = fakeGmail({ messages: { m1: newsletter() } });
    const { deps, writer } = makeDeps({ gmail, store, loadSenders: async () => ["news.example.test"] });

    const report = await importSetAsideDomain(deps, "news.example.test");

    // The survivor is imported; the deleted one is recorded, not a thrown import.
    expect(report.haltedOn).toBeUndefined();
    expect(writer.authored).toHaveLength(1);
    expect(report.unreadable).toBe(1);
    expect((await readMailboxUnreadable(store)).recent).toEqual([{ message_id: "deleted", reason: "gone" }]);
  });
});

// ---------------------------------------------------------------------------
// Step 3: compat — a mailbox op folds normally on the current build (§4)
// ---------------------------------------------------------------------------

function opOf(spec: OpSpec, n: number, authoredAt = "2026-08-09T12:00:00.000Z"): Op {
  const op: Op = {
    v: 1,
    type: spec.type as Op["type"],
    op_id: `op-${n}`,
    authored_at: authoredAt,
    parent_version: spec.parentVersion ?? null,
    payload: spec.payload,
    ...(spec.entity === undefined ? {} : { entity: spec.entity }),
    ...(spec.ingestId === undefined ? {} : { ingest_id: spec.ingestId }),
  };
  validateOp(op);
  return op;
}

async function authorOne(over: DepsOpts = {}, body?: string): Promise<OpSpec> {
  const gmail = fakeGmail({ messages: { m1: message({ ar: PASS_AR, ...(body === undefined ? {} : { body }) }) } });
  const { deps, writer } = makeDeps({ gmail, ...over });
  await runFetchCycle(deps);
  return writer.authored[0]!;
}

describe("compat: a mailbox op folds normally (no set-aside, no hard-stop)", () => {
  it("folds a no-review op to a visible user transaction with real money", async () => {
    const spec = await authorOne();
    const state = fold([
      { op: opOf({ type: "home_currency_set", payload: { currency: "AED" }, parentVersion: null }, 0), seq: 1n, writer_id: INGEST_WRITER_ID },
      { op: opOf(spec, 1), seq: 2n, writer_id: "device-a" },
    ] as LogEntry[]);

    expect(state.anomalies).toHaveLength(0);
    expect(state.unreadable).toHaveLength(0);
    const txn = [...state.txns.values()][0]!;
    expect(txn.amount_minor).toBe(12500n);
    expect(txn.currency).toBe("AED");
    expect(txn.needs_review).toBe(false);
    expect(txn.unparsed).toBe(false);
    // Client authorship => user authority: money editable, no verified origin (D6a).
    expect(txn.provenance).toBe("user");
    expect(txn.verified_origin_domain).toBeNull();
  });

  it("folds an empty needs-review op as an unparsed review item", async () => {
    // The genuinely empty card: no template reads the message at all. (An
    // unlisted sender is NOT this case — a template hit is kept as a prefill.)
    const spec = await authorOne({}, "Your statement is ready.");
    const state = fold([
      { op: opOf({ type: "home_currency_set", payload: { currency: "AED" }, parentVersion: null }, 0), seq: 1n, writer_id: INGEST_WRITER_ID },
      { op: opOf(spec, 1), seq: 2n, writer_id: "device-a" },
    ] as LogEntry[]);

    expect(state.anomalies).toHaveLength(0);
    const txn = [...state.txns.values()][0]!;
    expect(txn.unparsed).toBe(true);
    expect(txn.needs_review).toBe(true);
    expect(txn.amount_minor).toBe(0n);
  });

  // The fix for the empty first backfill: a template hit from an untrusted
  // sender folds as a REVIEW item that already carries its money, so the user
  // confirms a filled card instead of retyping a blank one.
  it("folds a prefilled needs-review op with its extracted money intact", async () => {
    const spec = await authorOne({ loadSenders: async () => [] }); // unlisted => review, but parsed
    const state = fold([
      { op: opOf({ type: "home_currency_set", payload: { currency: "AED" }, parentVersion: null }, 0), seq: 1n, writer_id: INGEST_WRITER_ID },
      { op: opOf(spec, 1), seq: 2n, writer_id: "device-a" },
    ] as LogEntry[]);

    expect(state.anomalies).toHaveLength(0);
    const txn = [...state.txns.values()][0]!;
    expect(txn.needs_review).toBe(true);
    expect(txn.unparsed).toBe(false);
    expect(txn.amount_minor).not.toBe(0n);
  });
});

// ---------------------------------------------------------------------------
// Step 4: D7 backstop — cross-path duplicates surface via the existing fold
// ---------------------------------------------------------------------------

describe("D7: a mailbox op flows through the existing possible-duplicate machinery", () => {
  it("flags a same-fingerprint SMTP-shaped row and mailbox row as possible duplicates", async () => {
    const mailboxSpec = await authorOne();

    // A different-bytes, SMTP-shaped ingest of the same alert: same last4, amount,
    // direction, merchant and day => same fingerprint, different ingest id.
    const smtpSpec: OpSpec = {
      type: "txn_ingested",
      entity: { kind: "txn", id: "smtp-1" },
      parentVersion: null,
      ingestId: "b".repeat(64),
      payload: {
        amount_minor: "12500",
        currency: "AED",
        direction: "debit",
        posted_at: "2026-08-03T00:00:00.000Z",
        merchant_raw: "CARREFOUR MALL",
        last4: "",
        category: null,
        needs_review: false,
        unparsed: false,
        tier: "template",
      },
    };

    const state = fold([
      { op: opOf({ type: "home_currency_set", payload: { currency: "AED" }, parentVersion: null }, 0), seq: 1n, writer_id: INGEST_WRITER_ID },
      { op: opOf(smtpSpec, 1), seq: 2n, writer_id: INGEST_WRITER_ID },
      { op: opOf(mailboxSpec, 2), seq: 3n, writer_id: "device-a" },
    ] as LogEntry[]);

    const mailboxTxn = state.txns.get(mailboxSpec.entity!.id)!;
    // The mailbox op flows through the fold unchanged and is flagged against the
    // earlier row — no new dedup machinery (D7d). If this ever stops holding, STOP.
    expect(mailboxTxn.possible_duplicate_of).toBe("smtp-1");
  });
});

// ---------------------------------------------------------------------------
// Step 5: liveness — holder devices fetch on boot + interval; others never do
// ---------------------------------------------------------------------------

describe("liveness gates fetching on a sealed token", () => {
  it("runs a cycle on boot when a sealed token exists, and again on the interval", async () => {
    const runCycle = vi.fn(async () => ({ fetched: 0, ops: 0, review: 0, unreadable: 0, setAside: 0 }));
    let tick: (() => void) | null = null;
    const stop = startMailboxLiveness({
      hasSealedToken: async () => true,
      runCycle,
      intervalMs: 1000,
      setInterval: (fn) => {
        tick = fn;
        return 1 as unknown as ReturnType<typeof setInterval>;
      },
      clearInterval: () => undefined,
    });

    await Promise.resolve(); // let the boot tick settle
    await Promise.resolve();
    expect(runCycle).toHaveBeenCalledTimes(1);

    tick!();
    await Promise.resolve();
    await Promise.resolve();
    expect(runCycle).toHaveBeenCalledTimes(2);
    stop();
  });

  it("never fetches when no sealed token is present", async () => {
    const runCycle = vi.fn(async () => ({ fetched: 0, ops: 0, review: 0, unreadable: 0, setAside: 0 }));
    let tick: (() => void) | null = null;
    const stop = startMailboxLiveness({
      hasSealedToken: async () => false,
      runCycle,
      setInterval: (fn) => {
        tick = fn;
        return 1 as unknown as ReturnType<typeof setInterval>;
      },
      clearInterval: () => undefined,
    });

    await Promise.resolve();
    await Promise.resolve();
    tick!();
    await Promise.resolve();
    await Promise.resolve();
    expect(runCycle).not.toHaveBeenCalled();
    stop();
  });
});
