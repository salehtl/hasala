/**
 * Writes `conformance/replay/` — whole logs folded by the TypeScript oracle
 * (`src/replay`), with the state each one folds to. This is the v3 fold
 * contract the Swift port (CoreReplay) is checked against.
 *
 * # What a case is
 *
 * A log of blobs in seq order, each either a list of wire ops or a raw
 * plaintext body, run through `foldBlobs` exactly as sync runs it (open, then
 * decode, then fold; an undecodable body is set aside). The expectation is the
 * oracle's `serializeState` with the diagnostic text blanked, its SHA-256, the
 * first-declaration order of banks and categories, and — for a log that must
 * stop the fold — which entry stopped it and why.
 *
 * # Groups
 *
 *   - `canary`: the snapshot fingerprint canary (`replay/snapshot.ts` CANARY),
 *     every v3 op type in one hostile log.
 *   - `fx`: the 18 logs of `conformance/fx`, now with their full state.
 *   - `fold`: causality, forks, supersede and dedup, duplicates, unparsed rows,
 *     splits, edits, provenance, checkpoints and money shapes — the scenarios of
 *     `replay.test.ts` and `errors.test.ts` that a JSON log can express.
 *   - `config`: the three schema-v3 configuration ops (`config.test.ts`).
 *   - `blobs`: the decode boundary — set-aside bodies, wire-invalid ops, the
 *     schema-version floors and ceilings.
 *   - `hard_stops`: the two conditions that stop a fold instead of recording.
 *
 * # Rules the generator enforces
 *
 *   - Every `ops` blob is what `encodeBlobOps` writes, so its ops are wire-
 *     canonical and pass `validateOp`; folding them with `applyOp` directly gives
 *     the same state as decoding the blob (checked here for every case).
 *   - Every integer in every state fits a signed 64-bit integer (A-21: money is
 *     `Int64` at rest), so no case asks the Swift fold to agree with an unbounded
 *     BigInt.
 *   - Anomaly `detail` and unreadable `reason` text is not part of the compared
 *     state (A-21: diagnostic text is Swift-canonical); the oracle's text is kept
 *     under `diagnostics` for reference.
 *
 *     cd reference/ledgerd-client && bun run gen-replay-conformance
 *     bun run gen-replay-conformance --check
 */

import "../src/platform";

import { ReplayOrderError, applyOp, foldBlobs } from "../src/replay/replay";
import { CANARY } from "../src/replay/snapshot";
import { emptyState, serializeState, type State } from "../src/replay/state";
import { UnknownNewerVersionError, encodeBlobOps, type Op, type OpType } from "../src/wire/op";
import { asciiJSON, assertFresh, sha256Hex, writeOrCheck, type FixtureFile } from "./conformance-io";
import { buildCases as buildFXCases } from "./gen-fx-conformance";

export const SUITE = "replay";
const REGENERATE = "bun run gen-replay-conformance";

const INT64_MAX = (1n << 63n) - 1n;

// ---------------------------------------------------------------------------
// The case shape
// ---------------------------------------------------------------------------

/** One blob whose body is `{"v": max op v, "kind": "ops", "ops": [...]}`. */
export interface OpsItem {
  seq: string;
  writer_id: string;
  ops: unknown[];
}

/** One blob given as its exact plaintext body: `body` (UTF-8 text) or `body_base64`. */
export interface RawItem {
  seq: string;
  writer_id: string;
  stream: string;
  writer_counter: string;
  body?: string;
  body_base64?: string;
}

export type LogItem = OpsItem | RawItem;

export interface Expect {
  error: null | { kind: "replay_order" | "newer_version"; at_entry: number };
  state?: unknown;
  state_sha256?: string;
  order?: { banks: string[]; categories: string[] };
  diagnostics?: {
    full_state_sha256: string;
    anomalies: { at_seq: string; kind: string; detail: string }[];
    unreadable: { seq: string; reason: string }[];
  };
}

export interface ReplayCase {
  name: string;
  group: string;
  note: string;
  schema_version: 1;
  log: LogItem[];
  expect: Expect;
}

/** The generator's own view of a log item: the fixture form plus the bytes it folds. */
interface Item {
  fixture: LogItem;
  seq: bigint;
  writer_id: string;
  stream: string;
  writer_counter: bigint;
  body: Uint8Array;
  ops: Op[] | null;
}

interface Spec {
  name: string;
  group: string;
  note: string;
  items: Item[];
}

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

/** A 64-hex ingest id from a readable name. */
const ingestID = (name: string): string => sha256Hex(name);

const T0 = "2026-06-05T10:00:00Z";
const utf8 = new TextEncoder();

interface OpOpts {
  at?: string;
  v?: number;
}

type Fields = Record<string, unknown>;

/** Drops keys whose override is `undefined`, so a case can remove a default field. */
function merge(base: Fields, over: Fields): Fields {
  const out: Fields = { ...base, ...over };
  for (const k of Object.keys(out)) if (out[k] === undefined) delete out[k];
  return out;
}

const txnDefaults = (): Fields => ({
  amount_minor: "25000",
  currency: "AED",
  direction: "debit",
  posted_at: "2026-06-05T09:00:00Z",
  merchant_raw: "CARREFOUR",
  last4: "8642",
});

/** What the ledgerd pipeline appended for a message no tier resolved. */
const unparsedDefaults = (): Fields => ({
  amount_minor: "0",
  currency: "",
  direction: "",
  posted_at: "2026-06-05T09:00:00Z",
  merchant_raw: "",
  last4: "",
  is_transfer: false,
  tier: "none",
  needs_review: true,
  unparsed: true,
  normalizer_version: 3,
});

class Case {
  private n = 0;
  private seq = 0n;
  private readonly counters = new Map<string, bigint>();
  readonly items: Item[] = [];

  constructor(private readonly prefix: string) {}

  private opID(): string {
    this.n += 1;
    return `${this.prefix}-${this.n}`;
  }

  op(type: OpType, rest: Partial<Op> & { payload: unknown }, o: OpOpts = {}): Op {
    return { v: o.v ?? 1, type, op_id: this.opID(), authored_at: o.at ?? T0, parent_version: null, ...rest };
  }

  ingest(txn: string, ingest: string, over: Fields = {}, o: OpOpts = {}): Op {
    return this.op("txn_ingested", { entity: { kind: "txn", id: txn }, ingest_id: ingestID(ingest), payload: merge(txnDefaults(), over) }, o);
  }

  unparsed(txn: string, ingest: string, over: Fields = {}, o: OpOpts = {}): Op {
    return this.op("txn_ingested", { entity: { kind: "txn", id: txn }, ingest_id: ingestID(ingest), payload: merge(unparsedDefaults(), over) }, o);
  }

  supersede(txn: string, ingest: string, over: Fields = {}, o: OpOpts = {}): Op {
    return this.op("txn_superseded", { entity: { kind: "txn", id: txn }, ingest_id: ingestID(ingest), payload: merge(txnDefaults(), over) }, o);
  }

  categorize(txn: string, parent: number, payload: Fields, o: OpOpts = {}): Op {
    return this.op("txn_categorized", { entity: { kind: "txn", id: txn }, parent_version: parent, payload }, o);
  }

  split(txn: string, parent: number, parts: readonly (readonly [string, unknown])[], o: OpOpts = {}): Op {
    const payload = { parts: parts.map(([category, amount_minor]) => ({ category, amount_minor })) };
    return this.op("txn_split", { entity: { kind: "txn", id: txn }, parent_version: parent, payload }, o);
  }

  edit(txn: string, parent: number, patch: Fields, o: OpOpts = {}): Op {
    return this.op("txn_edited", { entity: { kind: "txn", id: txn }, parent_version: parent, payload: patch }, o);
  }

  disposition(txn: string, parent: number, other: string, disposition: string | null, o: OpOpts = {}): Op {
    return this.op(
      "txn_duplicate_disposition",
      { entity: { kind: "txn", id: txn }, parent_version: parent, payload: { other_txn_id: other, disposition } },
      { v: 2, ...o },
    );
  }

  rule(id: string, parent: number | null, payload: Fields, o: OpOpts = {}): Op {
    return this.op("rule_added", { entity: { kind: "rule", id }, parent_version: parent, payload }, o);
  }

  home(currency: string, o: OpOpts = {}): Op {
    return this.op("home_currency_set", { payload: { currency } }, o);
  }

  rate(currency: string, rate_micro: unknown, o: OpOpts = {}): Op {
    return this.op("rate_set", { payload: { currency, rate_micro } }, o);
  }

  unrate(currency: string, o: OpOpts = {}): Op {
    return this.op("rate_unset", { payload: { currency } }, o);
  }

  bank(payload: Fields, o: OpOpts = {}): Op {
    return this.op("bank_declared", { payload }, { v: 3, ...o });
  }

  budget(payload: Fields, o: OpOpts = {}): Op {
    return this.op("budget_split_set", { payload }, { v: 3, ...o });
  }

  category(payload: Fields, o: OpOpts = {}): Op {
    return this.op("category_defined", { payload }, { v: 3, ...o });
  }

  checkpoint(heads: readonly (readonly [string, string, string, string])[], o: OpOpts = {}): Op {
    const payload = { heads: heads.map(([writer_id, stream, counter, h]) => ({ writer_id, stream, counter, hash: h.repeat(64) })) };
    return this.op("writer_checkpoint", { payload }, o);
  }

  private counter(writer: string): bigint {
    const c = (this.counters.get(writer) ?? 0n) + 1n;
    this.counters.set(writer, c);
    return c;
  }

  /** The next seq, one blob of `ops` from `writer`. */
  blob(writer: string, ...ops: Op[]): this {
    return this.blobAt(this.seq + 1n, writer, ...ops);
  }

  /** A blob at an explicit seq (gaps are legal; going backwards is a case of its own). */
  blobAt(seq: bigint, writer: string, ...ops: Op[]): this {
    this.seq = seq;
    const body = encodeBlobOps(ops);
    const wire = (JSON.parse(new TextDecoder().decode(body)) as { ops: unknown[] }).ops;
    this.items.push({
      fixture: { seq: `${seq}`, writer_id: writer, ops: wire },
      seq,
      writer_id: writer,
      stream: "hot",
      writer_counter: this.counter(writer),
      body,
      ops: wire as Op[],
    });
    return this;
  }

  /** A blob given as its exact body bytes, at the next seq unless one is named. */
  raw(writer: string, body: string | Uint8Array, opts: { seq?: bigint; stream?: string } = {}): this {
    const seq = opts.seq ?? this.seq + 1n;
    this.seq = seq;
    const stream = opts.stream ?? "hot";
    const counter = this.counter(writer);
    const bytes = typeof body === "string" ? utf8.encode(body) : body;
    const fixture: RawItem = { seq: `${seq}`, writer_id: writer, stream, writer_counter: `${counter}` };
    if (typeof body === "string") fixture.body = body;
    else fixture.body_base64 = Buffer.from(body).toString("base64");
    this.items.push({ fixture, seq, writer_id: writer, stream, writer_counter: counter, body: bytes, ops: null });
    return this;
  }
}

/** Builds one spec from a function over a fresh {@link Case}. */
function spec(group: string, name: string, note: string, build: (c: Case) => void): Spec {
  const c = new Case(name);
  build(c);
  return { name, group, note, items: c.items };
}

// ---------------------------------------------------------------------------
// The cases
// ---------------------------------------------------------------------------

const SAME = { last4: "8642", amount_minor: "25000", direction: "debit", merchant_raw: "CARREFOUR", posted_at: "2026-06-05T09:00:00Z" };

function foldSpecs(): Spec[] {
  const g = "fold";
  return [
    spec(g, "empty-log", "No ops: the empty state, every configuration field at its default.", () => {}),
    spec(g, "sequential-recategorization", "Each edit names the head it read, so the second is an ordinary edit, not a fork.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("dev-a", c.categorize("t1", 1, { category: "groceries" })).blob("dev-a", c.categorize("t1", 2, { category: "dining" })),
    ),
    spec(g, "future-parent", "An edit naming a version beyond the head is recorded, never guessed at.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("dev-a", c.categorize("t1", 5, { category: "groceries" })),
    ),
    spec(g, "unknown-entity", "An edit of an entity no create introduced.", (c) => c.blob("dev-a", c.categorize("ghost", 1, { category: "groceries" }))),
    spec(g, "duplicate-create", "A second create of the same entity is recorded and does not clobber the first.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("ingest", c.ingest("t1", "i2", { merchant_raw: "OTHER" })),
    ),
    spec(g, "entity-kind-mismatch", "An op may only address the entity kind its type owns.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.op("txn_categorized", { entity: { kind: "rule", id: "t1" }, parent_version: 1, payload: { category: "x" } }))
        .blob("dev-a", c.op("rule_added", { entity: { kind: "txn", id: "r1" }, payload: { pattern: "abcd", match: "contains", category: "x", priority: 1 } })),
    ),
    spec(g, "rule-and-txn-share-an-id", "Heads are keyed by (kind, id).", (c) =>
      c
        .blob("ingest", c.ingest("x", "i1"))
        .blob("dev-a", c.rule("x", null, { pattern: "carrefour", match: "contains", category: "groceries", priority: 10 }))
        .blob("dev-a", c.categorize("x", 1, { category: "dining" })),
    ),
    spec(g, "fork-later-authored-wins", "Two edits from one parent: the later authored_at wins and one fork notice is recorded.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.categorize("t1", 1, { category: "groceries" }, { at: "2026-06-05T10:00:00Z" }))
        .blob("dev-b", c.categorize("t1", 1, { category: "dining" }, { at: "2026-06-05T11:00:00Z" })),
    ),
    spec(g, "fork-incumbent-later-authored-keeps-head", "The later-authored op wins even when it already holds the head; the challenger only consumes a version.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.categorize("t1", 1, { category: "groceries" }, { at: "2026-06-05T11:00:00Z" }))
        .blob("dev-b", c.categorize("t1", 1, { category: "dining" }, { at: "2026-06-05T10:00:00Z" })),
    ),
    spec(g, "fork-tie-writer-id-a-then-b", "Equal instants: the greater writer_id (UTF-8 bytes) wins.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.categorize("t1", 1, { category: "from-a" }))
        .blob("dev-b", c.categorize("t1", 1, { category: "from-b" })),
    ),
    spec(g, "fork-tie-writer-id-b-then-a", "The same fork delivered in the other order resolves to the same winner.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-b", c.categorize("t1", 1, { category: "from-b" }))
        .blob("dev-a", c.categorize("t1", 1, { category: "from-a" })),
    ),
    spec(g, "fork-writer-id-only-on-equal-instants", "A smaller writer_id with a later instant still wins.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-z", c.categorize("t1", 1, { category: "from-z" }, { at: "2026-06-05T10:00:00Z" }))
        .blob("dev-a", c.categorize("t1", 1, { category: "from-a" }, { at: "2026-06-05T10:00:00.001Z" })),
    ),
    spec(g, "fork-sub-millisecond-is-a-tie", "authored_at is truncated to milliseconds on the wire, so these two instants tie and the writer decides.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-b", c.categorize("t1", 1, { category: "from-b" }, { at: "2026-06-05T10:00:00.0009Z" }))
        .blob("dev-a", c.categorize("t1", 1, { category: "from-a" }, { at: "2026-06-05T10:00:00.0001Z" })),
    ),
    spec(g, "fork-full-tie-keeps-incumbent", "Same instant and same writer: the incumbent stays, so the fork resolves by seq.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.categorize("t1", 1, { category: "first" }))
        .blob("dev-a", c.categorize("t1", 1, { category: "second" })),
    ),
    spec(g, "fork-three-way", "Three edits from one parent: two notices, the head moves twice.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.categorize("t1", 1, { category: "a" }, { at: "2026-06-05T10:00:00Z" }))
        .blob("dev-b", c.categorize("t1", 1, { category: "b" }, { at: "2026-06-05T12:00:00Z" }))
        .blob("dev-c", c.categorize("t1", 1, { category: "c" }, { at: "2026-06-05T11:00:00Z" })),
    ),
    spec(g, "parent-zero-never-existed", "parent_version 0 names a version that never existed.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("dev-a", c.categorize("t1", 0, { category: "x" })),
    ),
    spec(g, "refused-stale-edit-is-not-a-fork", "A stale-parent split that fails its sum is refused before fork resolution: no notice, no version.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.categorize("t1", 1, { category: "groceries" }))
        .blob("dev-b", c.split("t1", 1, [["a", "1"], ["b", "2"]])),
    ),
    spec(g, "fork-on-a-rule", "Fork resolution applies to any versioned entity.", (c) =>
      c
        .blob("dev-a", c.rule("r1", null, { pattern: "carrefour", match: "contains", category: "groceries", priority: 10 }))
        .blob("dev-a", c.rule("r1", 1, { pattern: "carrefour", match: "contains", category: "shopping", priority: 10 }, { at: "2026-06-05T09:00:00Z" }))
        .blob("dev-b", c.rule("r1", 1, { pattern: "carrefour", match: "exact", category: "dining", priority: 5 }, { at: "2026-06-05T12:00:00Z" })),
    ),
    spec(g, "fold-order-is-seq-not-authored-at", "The earlier-authored rate arrives later and is the head.", (c) =>
      c.blob("dev-a", c.home("AED")).blob("dev-a", c.rate("USD", "3672500", { at: "2026-06-05T12:00:00Z" })).blob("dev-b", c.rate("USD", "3600000", { at: "2026-06-01T00:00:00Z" })),
    ),
    spec(g, "duplicate-delivery-in-one-blob", "The same op twice at one seq: the second is a duplicate_delivery, not a self-fork.", (c) => {
      const op = c.categorize("t1", 1, { category: "groceries" });
      c.blob("ingest", c.ingest("t1", "i1")).blob("dev-a", op, op);
    }),
    spec(g, "ops-in-one-blob-apply-in-order", "Every op in a blob shares its seq and applies in array order.", (c) =>
      c.blob("dev-a", c.ingest("t1", "i1"), c.categorize("t1", 1, { category: "a" }), c.categorize("t1", 2, { category: "b" }), c.rule("r1", null, { pattern: "carr", match: "contains", category: "x", priority: 1 })),
    ),
    spec(g, "seq-gaps-are-legal", "A hot-only pull sees gaps where cold rows were skipped.", (c) =>
      c.blobAt(3n, "ingest", c.ingest("t1", "i1")).blobAt(10n, "dev-a", c.categorize("t1", 1, { category: "x" })).blobAt(11n, "ingest", c.ingest("t2", "i2", { merchant_raw: "B" })),
    ),
    // --- supersede and dedup ---
    spec(g, "supersede-keeps-one-live-row", "The supersede retires its predecessor and becomes the one live row for the ingest id.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("ingest", c.supersede("t2", "i1", { amount_minor: "26000" })),
    ),
    spec(g, "duplicate-ingest", "A repeated txn_ingested for one ingest id is an anomaly, never a second live row.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("ingest", c.ingest("t2", "i1", { merchant_raw: "OTHER" })),
    ),
    spec(g, "supersede-without-origin", "A supersede whose original was never seen still lands, and says so.", (c) => c.blob("ingest", c.supersede("t1", "i1"))),
    spec(g, "supersede-chain", "Three revisions of one message; exactly one live row throughout.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("ingest", c.supersede("t2", "i1", { amount_minor: "1" }))
        .blob("ingest", c.supersede("t3", "i1", { amount_minor: "2" }))
        .blob("dev-a", c.categorize("t1", 1, { category: "late" })),
    ),
    spec(g, "supersede-refreezes-at-its-own-position", "A supersede does not inherit the predecessor's frozen home amount.", (c) =>
      c
        .blob("dev-a", c.home("AED"), c.rate("USD", "3672500"))
        .blob("ingest", c.ingest("t1", "i1", { currency: "USD", amount_minor: "10000" }))
        .blob("dev-a", c.rate("USD", "3600000"))
        .blob("ingest", c.supersede("t2", "i1", { currency: "USD", amount_minor: "10000" })),
    ),
    spec(g, "currency-correcting-supersede-moves-pending", "The corrected row lands in its own currency's pending set.", (c) =>
      c.blob("dev-a", c.home("AED")).blob("ingest", c.ingest("t1", "i1", { currency: "USD" })).blob("ingest", c.supersede("t2", "i1", { currency: "EUR" })),
    ),
    spec(g, "fingerprint-collision-is-a-notice", "Same last4, amount, direction, merchant and UTC day: both rows stay, the later one is flagged.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1", SAME)).blob("ingest", c.ingest("t2", "i2", { ...SAME, posted_at: "2026-06-05T17:00:00Z" })),
    ),
    spec(g, "duplicate-dispositions", "Schema-v2 answers: same, different, undo; a disposition naming another row is a mismatch.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("ingest", c.ingest("t2", "i2"))
        .blob("dev-a", c.disposition("t2", 1, "t1", "same"))
        .blob("dev-a", c.disposition("t2", 2, "t1", "different"))
        .blob("dev-a", c.disposition("t2", 3, "t1", null))
        .blob("dev-a", c.disposition("t2", 4, "t9", "same")),
    ),
    spec(g, "three-way-collision-names-the-earliest", "Both later rows point at the earliest; retiring it hands the bucket on.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", SAME))
        .blob("ingest", c.ingest("t2", "i2", SAME))
        .blob("ingest", c.ingest("t3", "i3", SAME))
        .blob("ingest", c.supersede("t4", "i1", { ...SAME, merchant_raw: "OTHER" })),
    ),
    spec(g, "possible-duplicate-is-a-snapshot", "Editing the pointed-at row out of the bucket does not re-walk the rows pointing at it.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1", SAME)).blob("ingest", c.ingest("t2", "i2", SAME)).blob("dev-a", c.edit("t1", 1, { merchant_raw: "SOMEWHERE ELSE" })),
    ),
    spec(g, "superseded-row-stops-matching", "A supersede with identical fields is not its own predecessor's duplicate.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("ingest", c.supersede("t2", "i1")),
    ),
    spec(g, "fingerprint-day-from-the-instant", "22:00-04:00 is the next UTC day; the matching row is on that day.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", { posted_at: "2026-06-05T22:00:00-04:00" }))
        .blob("ingest", c.ingest("t2", "i2", { posted_at: "2026-06-05T09:00:00Z" }))
        .blob("ingest", c.ingest("t3", "i3", { posted_at: "2026-06-06T01:30:00Z" })),
    ),
    // --- unparsed rows ---
    spec(g, "unparsed-row-materializes", "An unparsed message is a row on the review surface with no money.", (c) => c.blob("ingest", c.unparsed("u1", "m1"))),
    spec(g, "unparsed-shape-is-held", "Each payload claims unparsed while breaking one rule of the shape; only the last is the real thing.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "z1", { amount_minor: "0" }))
        .blob("ingest", c.unparsed("t2", "z2", { amount_minor: "25000", currency: "AED", direction: "debit" }))
        .blob("ingest", c.unparsed("t3", "z3", { tier: "template" }))
        .blob("ingest", c.unparsed("t4", "z4", { currency: "AED" }))
        .blob("ingest", c.unparsed("t5", "z5", { direction: "credit" }))
        .blob("ingest", c.unparsed("t6", "z6", { needs_review: false }))
        .blob("ingest", c.unparsed("t7", "z7", { amount_minor: undefined, currency: undefined, direction: undefined, needs_review: undefined })),
    ),
    spec(g, "tier-is-a-closed-set", "template, heuristic, an absent tier (none) and an unknown one.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", { tier: "template" }))
        .blob("ingest", c.ingest("t2", "i2", { tier: "heuristic", merchant_raw: "B" }))
        .blob("ingest", c.ingest("t3", "i3", { merchant_raw: "C" }))
        .blob("ingest", c.ingest("t4", "i4", { tier: "magic", merchant_raw: "D" })),
    ),
    spec(g, "parse-error-is-a-code", "A lower-snake token on an unparsed row; free text, or any parse_error on a parsed row, is refused.", (c) =>
      c
        .blob("ingest", c.unparsed("u1", "m1", { parse_error: "no_template" }))
        .blob("ingest", c.unparsed("u2", "m2", { parse_error: "Has Spaces" }))
        .blob("ingest", c.unparsed("u3", "m3", { parse_error: "" }))
        .blob("ingest", c.ingest("t1", "i1", { parse_error: "no_template" })),
    ),
    spec(g, "unparsed-superseded-by-a-template-fix", "A later template fix supersedes the review item into a real transaction.", (c) =>
      c.blob("ingest", c.unparsed("u1", "m1")).blob("ingest", c.supersede("t1", "m1", { tier: "template", needs_review: false })),
    ),
    spec(g, "unparsed-fingerprints-are-their-own", "Two unparsed rows on one day do not collide, and an unparsed row cannot collide with a parsed one.", (c) =>
      c.blob("ingest", c.unparsed("u1", "m1")).blob("ingest", c.unparsed("u2", "m2")).blob("ingest", c.ingest("t1", "i1", { amount_minor: "1", merchant_raw: "", last4: "" })),
    ),
    spec(g, "edit-cannot-touch-parse-fields", "unparsed, tier and parse_error are refused on an edit; the rest of the edit applies.", (c) =>
      c
        .blob("ingest", c.unparsed("u1", "m1"))
        .blob("dev-a", c.edit("u1", 1, { unparsed: false, tier: "template", merchant_raw: "NOTE" }))
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.edit("t1", 1, { parse_error: "x", last4: "1111" })),
    ),
    spec(g, "unparsed-review-flag-cannot-be-cleared", "Neither txn_categorized nor txn_edited may clear needs_review on an unparsed row; setting it true, or clearing it on a parsed row, is fine.", (c) =>
      c
        .blob("ingest", c.unparsed("u1", "m1"))
        .blob("dev-a", c.categorize("u1", 1, { category: "groceries", needs_review: false }))
        .blob("dev-a", c.edit("u1", 2, { needs_review: false }))
        .blob("dev-a", c.edit("u1", 3, { needs_review: true }))
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.categorize("t1", 1, { category: "groceries", needs_review: false })),
    ),
    spec(g, "unparsed-money-and-home-amount-refused", "An edit may not give an unparsed row an amount, a currency or a home amount, whoever authored the row.", (c) =>
      c
        .blob("dev-a", c.unparsed("u1", "m1"))
        .blob("dev-a", c.edit("u1", 1, { amount_minor: "500", currency: "AED", direction: "debit" }))
        .blob("dev-a", c.edit("u1", 2, { amount_home_minor: "500" })),
    ),
    spec(g, "unparsed-merchant-edit-keeps-its-bucket", "An unparsed row's fingerprint is its ingest id, so a merchant edit does not move it.", (c) =>
      c.blob("ingest", c.unparsed("u1", "m1")).blob("dev-a", c.edit("u1", 1, { merchant_raw: "ADDED BY HAND" })),
    ),
    spec(g, "posted-at-canonical-form", "posted_at is canonicalised to UTC milliseconds; an offset that carries the canonical form out of the 4-digit-year range is refused.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", { posted_at: "2026-06-05T13:00:00.123456+04:00" }))
        .blob("ingest", c.ingest("t2", "i2", { posted_at: "9999-12-31T23:59:59-23:59", merchant_raw: "B" }))
        .blob("ingest", c.ingest("t3", "i3", { posted_at: "2026-02-30T10:00:00Z", merchant_raw: "C" }))
        .blob("ingest", c.ingest("t4", "i4", { posted_at: 1780650000, merchant_raw: "D" })),
    ),
    // --- splits ---
    spec(g, "split-sum-and-replacement", "A split that does not sum is refused without a version; the corrected one applies; a later split replaces it wholesale.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", { amount_minor: "1000" }))
        .blob("dev-a", c.split("t1", 1, [["food", "600"], ["home", "300"]]))
        .blob("dev-a", c.split("t1", 1, [["food", "600"], ["home", "400"]]))
        .blob("dev-a", c.split("t1", 2, [["food", "100"], ["home", "200"], ["fun", "700"]])),
    ),
    spec(g, "split-refused-on-unparsed", "An unparsed row has no amount to split, even an empty one.", (c) =>
      c.blob("ingest", c.unparsed("u1", "m1")).blob("dev-a", c.split("u1", 1, [["food", "1"]])).blob("dev-a", c.split("u1", 1, [])),
    ),
    spec(g, "split-part-shapes", "Parts are positive decimal strings with a category.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", { amount_minor: "1000" }))
        .blob("dev-a", c.split("t1", 1, [["food", 600], ["home", "400"]]))
        .blob("dev-a", c.split("t1", 1, [["food", "0"], ["home", "1000"]]))
        .blob("dev-a", c.split("t1", 1, [["", "500"], ["home", "500"]]))
        .blob("dev-a", c.op("txn_split", { entity: { kind: "txn", id: "t1" }, parent_version: 1, payload: { parts: "all" } })),
    ),
    // --- checkpoints ---
    spec(g, "latest-checkpoint-replaces", "The latest writer_checkpoint replaces the earlier one; counters are integers past 2^53.", (c) =>
      c
        .blob("dev-a", c.checkpoint([["dev-b", "hot", "2", "b"], ["ingest", "hot", "4", "a"]]))
        .blob("dev-a", c.checkpoint([["dev-a", "hot", "9007199254740993", "c"], ["ingest", "cold", "0", "0"]])),
    ),
    spec(g, "checkpoint-must-be-sorted", "An unsorted or duplicated roster is refused and the previous checkpoint stands.", (c) =>
      c
        .blob("dev-a", c.checkpoint([["dev-a", "hot", "1", "a"]]))
        .blob("dev-a", c.checkpoint([["ingest", "hot", "4", "a"], ["dev-b", "hot", "2", "b"]]))
        .blob("dev-a", c.checkpoint([["dev-b", "hot", "2", "b"], ["dev-b", "hot", "3", "c"]])),
    ),
    // --- parent-free FX heads ---
    spec(g, "home-currency-is-one-shot", "A second home_currency_set, a rate_set and a rate_unset for the home currency are all refused.", (c) =>
      c.blob("dev-a", c.home("AED")).blob("dev-b", c.home("USD")).blob("dev-a", c.rate("AED", "1000000")).blob("dev-a", c.unrate("AED")).blob("dev-a", c.unrate("USD")),
    ),
    spec(g, "rate-shapes", "Rates are positive decimal strings; currency codes are three letters, upper-cased.", (c) =>
      c
        .blob("dev-a", c.home("aed"))
        .blob("dev-a", c.rate("usd", "3672500"))
        .blob("dev-a", c.rate("EUR", 4010000))
        .blob("dev-a", c.rate("GBP", "0"))
        .blob("dev-a", c.rate("GB", "1"))
        .blob("dev-a", c.rate("GBP", "-1")),
    ),
    // --- edits ---
    spec(g, "edited-home-amount-is-verbatim", "txn_edited carries the home amount itself, never a recompute instruction; null re-opens the pending slot.", (c) =>
      c
        .blob("dev-a", c.home("AED"))
        .blob("ingest", c.ingest("t1", "i1", { currency: "USD" }))
        .blob("dev-a", c.edit("t1", 1, { amount_home_minor: "91000" }))
        .blob("dev-a", c.edit("t1", 2, { amount_home_minor: null })),
    ),
    spec(g, "edit-reindexes-the-fingerprint", "An edit that changes a fingerprint field moves the row to its new bucket and clears its notice.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", SAME))
        .blob("ingest", c.ingest("t2", "i2", SAME))
        .blob("dev-a", c.edit("t2", 1, { last4: "0000" }))
        .blob("ingest", c.ingest("t3", "i3", { ...SAME, last4: "0000" })),
    ),
    spec(g, "money-edit-only-on-user-rows", "The ingest writer's money changes only by supersede; a row the user authored may be restated, including past 2^53.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.edit("t1", 1, { amount_minor: "26000", currency: "USD", direction: "credit", entry_method: "manual" }))
        .blob("dev-a", c.ingest("t2", "i2", { merchant_raw: "MANUAL" }))
        .blob("dev-a", c.edit("t2", 1, { amount_minor: "9007199254740993", direction: "credit" })),
    ),
    spec(g, "money-edit-reconverts-at-its-position", "A corrected amount is converted at the edit's own position; a corrected currency moves the pending bucket.", (c) =>
      c
        .blob("dev-a", c.home("AED"), c.rate("USD", "3672500"))
        .blob("dev-a", c.ingest("t1", "i1", { currency: "USD", amount_minor: "10000" }))
        .blob("dev-a", c.rate("USD", "3700000"))
        .blob("dev-a", c.edit("t1", 1, { amount_minor: "20000" }))
        .blob("dev-a", c.edit("t1", 2, { currency: "EUR" })),
    ),
    spec(g, "amount-not-restated-under-a-split", "A split row's amount is frozen; its direction is not.", (c) =>
      c
        .blob("dev-a", c.ingest("t1", "i1", { amount_minor: "1000" }))
        .blob("dev-a", c.split("t1", 1, [["a", "500"], ["b", "500"]]))
        .blob("dev-a", c.edit("t1", 2, { amount_minor: "2000" }))
        .blob("dev-a", c.edit("t1", 3, { direction: "credit" })),
    ),
    spec(g, "edit-of-superseded-row-is-surfaced", "The edit applies to the retired row and an edit_of_superseded anomaly says so.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("ingest", c.supersede("t2", "i1")).blob("dev-a", c.categorize("t1", 1, { category: "groceries" })),
    ),
    spec(g, "edit-field-shapes", "Each malformed edit is one invalid_payload and consumes no version.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.edit("t1", 1, { merchant_raw: 5 }))
        .blob("dev-a", c.edit("t1", 1, { posted_at: "yesterday" }))
        .blob("dev-a", c.edit("t1", 1, { possible_duplicate_of: "" }))
        .blob("dev-a", c.edit("t1", 1, { needs_review: "yes" }))
        .blob("dev-a", c.edit("t1", 1, { category: 7 }))
        .blob("dev-a", c.edit("t1", 1, { possible_duplicate_of: "t9", category: "" })),
    ),
    spec(g, "money-shapes", "Money is a positive decimal-integer string; a JSON number, zero, a sign, a fraction or a bad direction is refused.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", { amount_minor: "9223372036854775807" }))
        .blob("ingest", c.ingest("t2", "i2", { amount_minor: 25000 }))
        .blob("ingest", c.ingest("t3", "i3", { amount_minor: "0" }))
        .blob("ingest", c.ingest("t4", "i4", { amount_minor: "-5" }))
        .blob("ingest", c.ingest("t5", "i5", { amount_minor: "+5" }))
        .blob("ingest", c.ingest("t6", "i6", { amount_minor: "1.50" }))
        .blob("ingest", c.ingest("t7", "i7", { amount_minor: "" }))
        .blob("ingest", c.ingest("t8", "i8", { direction: "refund" }))
        .blob("ingest", c.ingest("t9", "i9", { currency: "AE" }))
        .blob("ingest", c.ingest("t10", "i10", { amount_minor: "007", merchant_raw: "LEADING ZEROS" })),
    ),
    spec(g, "category-and-review-defaults", "No category means needs_review; an empty category is no category; an explicit needs_review wins.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("ingest", c.ingest("t2", "i2", { category: "groceries", merchant_raw: "B" }))
        .blob("ingest", c.ingest("t3", "i3", { category: "", merchant_raw: "C" }))
        .blob("ingest", c.ingest("t4", "i4", { category: "groceries", needs_review: true, merchant_raw: "D" }))
        .blob("ingest", c.ingest("t5", "i5", { needs_review: false, merchant_raw: "E" }))
        .blob("ingest", c.ingest("t6", "i6", { merchant_raw: undefined, last4: undefined })),
    ),
    spec(g, "provenance-comes-from-the-writer", "Only the reserved ingest writer yields provenance ingest; a payload cannot claim it.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).blob("dev-a", c.ingest("t2", "i2", { merchant_raw: "B", provenance: "ingest" })),
    ),
    spec(g, "mailbox-message-id", "A complete mailbox provenance keeps its message id; a malformed one folds to null without an anomaly; a supersede carries its own.", (c) =>
      c
        .blob("dev-a", c.unparsed("mb", "mb1", { provenance: { provider: "gmail", grant_id: "acct-1", message_id: "gmail-msg-abc123" } }))
        .blob("dev-a", c.unparsed("mb0", "mb0", { provenance: { provider: "gmail", grant_id: "acct-1", message_id: "" } }))
        .blob("dev-a", c.unparsed("mb1", "mb2", { provenance: { provider: "gmail", message_id: "m" } }))
        .blob("dev-a", c.unparsed("mb2", "mb3", { provenance: "gmail" }))
        .blob("dev-a", c.unparsed("mb3", "mb4", { provenance: null }))
        .blob("dev-a", c.supersede("mb4", "mb1", { tier: "template", needs_review: false }))
        .blob("dev-a", c.supersede("mb5", "mb0", { provenance: { provider: "gmail", grant_id: "acct-1", message_id: "gmail-msg-def456" }, merchant_raw: "B" })),
    ),
    spec(g, "verified-origin-domain", "A schema-v2 field: carried on a v2 row, refused on a v1 one.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1", { verified_origin_domain: "bank.example" }, { v: 2 }))
        .blob("ingest", c.ingest("t2", "i2", { verified_origin_domain: "bank.example", merchant_raw: "B" }))
        .blob("ingest", c.ingest("t3", "i3", { verified_origin_domain: 7, merchant_raw: "C" }, { v: 2 })),
    ),
    spec(g, "rule-payloads", "rule_added creates and edits; its match type is a closed set and its priority an integer.", (c) =>
      c
        .blob("dev-a", c.rule("r1", null, { pattern: "carrefour", match: "contains", category: "groceries", priority: 10 }))
        .blob("dev-a", c.rule("r1", 1, { pattern: "^carrefour", match: "regex", category: "groceries", priority: -3 }))
        .blob("dev-a", c.rule("r2", null, { pattern: "x", match: "starts_with", category: "y", priority: 1 }))
        .blob("dev-a", c.rule("r3", null, { pattern: "x", match: "exact", category: "y", priority: 1.5 }))
        .blob("dev-a", c.rule("r4", null, { pattern: "", match: "exact", category: "y", priority: 1 }))
        .blob("dev-a", c.rule("r5", null, { pattern: "abcd", match: "exact", category: "y", priority: 9007199254740991 })),
    ),
    spec(g, "create-and-parent-rules", "Only a create may name no parent, and a create may not name one.", (c) =>
      c
        .blob("ingest", c.ingest("t1", "i1"))
        .blob("dev-a", c.op("txn_categorized", { entity: { kind: "txn", id: "t1" }, parent_version: null, payload: { category: "x" } }))
        .blob("ingest", c.op("txn_ingested", { entity: { kind: "txn", id: "t2" }, parent_version: 1, ingest_id: ingestID("i2"), payload: merge(txnDefaults(), { merchant_raw: "B" }) })),
    ),
    spec(g, "payload-not-an-object", "A payload that is not a JSON object is an invalid_payload for every op type that reads one.", (c) =>
      c
        .blob("ingest", c.op("txn_ingested", { entity: { kind: "txn", id: "t1" }, ingest_id: ingestID("i1"), payload: ["not", "an", "object"] }))
        .blob("dev-a", c.op("rate_set", { payload: "USD" }))
        .blob("dev-a", c.op("home_currency_set", { payload: null })),
    ),
  ];
}

function configSpecs(): Spec[] {
  const g = "config";
  return [
    spec(g, "banks-last-write-per-bank", "bank_declared is last write per bank; active:false retires one; two devices adding different banks both survive.", (c) =>
      c
        .blob("dev-a", c.bank({ bank: "enbd", active: true }))
        .blob("dev-b", c.bank({ bank: "dib", active: true }))
        .blob("dev-a", c.bank({ bank: "enbd", active: false }))
        .blob("dev-b", c.bank({ bank: "adcb", active: true })),
    ),
    spec(g, "bank-payload-shapes", "A malformed bank_declared is an invalid_payload and leaves the set alone.", (c) =>
      c
        .blob("dev-a", c.bank({ bank: "enbd", active: true }))
        .blob("dev-a", c.bank({ bank: "", active: true }))
        .blob("dev-a", c.bank({ bank: "enbd", active: "no" }))
        .blob("dev-a", c.bank({ bank: 7, active: false }))
        .blob("dev-a", c.bank({ active: false })),
    ),
    spec(g, "budget-split-replaces", "Each budget_split_set replaces the whole plan, monthly total included.", (c) =>
      c
        .blob("dev-a", c.budget({ need: 50, want: 30, saving: 20 }))
        .blob("dev-a", c.budget({ need: 60, want: 20, saving: 20, monthly_total_minor: "1500000" }))
        .blob("dev-a", c.budget({ need: 70, want: 20, saving: 10 })),
    ),
    spec(g, "budget-split-shapes", "Whole percentages summing to exactly 100; an invalid split leaves the valid one standing.", (c) =>
      c
        .blob("dev-a", c.budget({ need: 50, want: 30, saving: 20, monthly_total_minor: "9007199254740993" }))
        .blob("dev-a", c.budget({ need: 50, want: 30, saving: 30 }))
        .blob("dev-a", c.budget({ need: 50.5, want: 29.5, saving: 20 }))
        .blob("dev-a", c.budget({ need: -10, want: 90, saving: 20 }))
        .blob("dev-a", c.budget({ need: 101, want: 0, saving: -1 }))
        .blob("dev-a", c.budget({ need: "50", want: 30, saving: 20 }))
        .blob("dev-a", c.budget({ need: 50, want: 30, saving: 20, monthly_total_minor: 1500000 }))
        .blob("dev-a", c.budget({ need: 50, want: 30, saving: 20, monthly_total_minor: "-1" })),
    ),
    spec(g, "budget-zero-total-is-a-total", "Zero is a total a user can state; null and absent both mean no total.", (c) =>
      c
        .blob("dev-a", c.budget({ need: 100, want: 0, saving: 0, monthly_total_minor: "0" }))
        .blob("dev-a", c.budget({ need: 0, want: 0, saving: 100, monthly_total_minor: null })),
    ),
    spec(g, "categories-last-write-per-id", "category_defined is last write per id; active:false retires without deleting; declaration order is kept.", (c) =>
      c
        .blob("dev-a", c.category({ id: "groceries", name: "Groceries", kind: "spending", bucket: "need", color: "#88aa66", active: true }))
        .blob("dev-b", c.category({ id: "salary", name: "Salary", kind: "income", bucket: null, active: true }))
        .blob("dev-a", c.category({ id: "dining", name: "Dining", kind: "spending", bucket: "want", active: true }))
        .blob("dev-a", c.category({ id: "groceries", name: "Food", kind: "spending", bucket: "want", color: "#88aa66", active: true }))
        .blob("dev-b", c.category({ id: "salary", name: "Salary", kind: "income", active: false }))
        .blob("dev-b", c.category({ id: "transfer", name: "Transfers", kind: "excluded", active: true })),
    ),
    spec(g, "category-payload-shapes", "A spending category needs a bucket and the other kinds must not carry one; id, name, kind and active are required; an invalid redefinition leaves the previous one.", (c) =>
      c
        .blob("dev-a", c.category({ id: "k1", name: "One", kind: "spending", bucket: "need", active: true }))
        .blob("dev-a", c.category({ id: "k1", name: "One", kind: "spending", active: true }))
        .blob("dev-a", c.category({ id: "k2", name: "Two", kind: "income", bucket: "need", active: true }))
        .blob("dev-a", c.category({ id: "k3", name: "Three", kind: "savings", active: true }))
        .blob("dev-a", c.category({ id: "", name: "Four", kind: "excluded", active: true }))
        .blob("dev-a", c.category({ id: "k5", kind: "excluded", active: true }))
        .blob("dev-a", c.category({ id: "k6", name: "Six", kind: "excluded" }))
        .blob("dev-a", c.category({ id: "k7", name: "Seven", kind: "excluded", active: true, color: "" }))
        .blob("dev-a", c.category({ id: "k1", name: "One", kind: "spending", bucket: "luxury", active: true })),
    ),
  ];
}

const opsBody = (ops: string, v = 1): string => `{"v":${v},"kind":"ops","ops":[${ops}]}`;
const wireIngest = (v: number, type = "txn_ingested", extra = ""): string =>
  `{"v":${v},"type":"${type}","op_id":"raw-${v}-${type}","authored_at":"2026-06-05T10:00:00.000Z","entity":{"kind":"txn","id":"r${v}"},"parent_version":null,"ingest_id":"${"a".repeat(64)}","payload":{"amount_minor":"100","currency":"AED","direction":"debit","posted_at":"2026-06-05T09:00:00Z","merchant_raw":"RAW","last4":"1"}${extra}}`;

function blobSpecs(): Spec[] {
  const g = "blobs";
  return [
    spec(g, "unopenable-body-is-set-aside", "A body that is not JSON is set aside with its position, and the rest of the log folds.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).raw("ingest", "{not json").blob("ingest", c.ingest("t3", "i3", { merchant_raw: "C" })),
    ),
    spec(g, "invalid-utf8-body", "Invalid UTF-8 is decoded with U+FFFD and then judged as JSON: here it is a valid blob whose merchant carries the replacement character.", (c) => {
      const [before, after] = opsBody(wireIngest(1)).split("RAW") as [string, string];
      c.raw("ingest", new Uint8Array([...utf8.encode(`${before}R`), 0xff, ...utf8.encode(`W${after}`)]));
    }),
    spec(g, "cold-raw-body-offered-to-the-fold", "A raw_body record is not an ops blob: it is set aside, never folded as state.", (c) =>
      c.raw("ingest", `{"v":1,"kind":"raw_body","ingest_id":"${"a".repeat(64)}","received_at":"2026-06-05T09:00:00Z","raw_base64":""}`, { stream: "cold" }),
    ),
    spec(g, "body-shapes", "Absent and null ops are zero ops; a body that is not an object, a missing kind, a non-array ops and an unknown kind are set aside.", (c) =>
      c
        .raw("dev-a", `{"v":1,"kind":"ops"}`)
        .raw("dev-a", `{"v":1,"kind":"ops","ops":null}`)
        .raw("dev-a", `[1,2,3]`)
        .raw("dev-a", `{"v":1,"ops":[]}`)
        .raw("dev-a", `{"v":1,"kind":"ops","ops":{}}`)
        .raw("dev-a", `{"v":1,"kind":"mystery","ops":[]}`)
        .raw("dev-a", `{"v":"1","kind":"ops","ops":[]}`)
        .raw("dev-a", `{"v":0,"kind":"ops","ops":[]}`)
        .raw("dev-a", `{"v":1.0,"kind":"ops","ops":[]}`),
    ),
    spec(g, "wire-invalid-op-sets-aside-the-blob", "One op that fails validateOp sets aside its whole blob, including the valid op beside it.", (c) =>
      c.raw("dev-a", opsBody(`${wireIngest(1)},{"v":1,"type":"rate_set","op_id":"bad","authored_at":"2026-06-05T10:00:00.000Z","parent_version":3,"payload":{"currency":"USD","rate_micro":"1"}}`)),
    ),
    spec(g, "op-structure-refusals", "Each blob carries one structurally invalid op: an unknown type, no op_id, a bad timestamp, a missing entity, an entity with no id, a negative or fractional or unsafe parent_version, a bad ingest id, a non-object op.", (c) =>
      c
        .raw("dev-a", opsBody(`{"v":1,"type":"txn_deleted","op_id":"o1","authored_at":"2026-06-05T10:00:00.000Z","entity":{"kind":"txn","id":"t"},"parent_version":1,"payload":{}}`))
        .raw("dev-a", opsBody(`{"v":1,"type":"rate_set","authored_at":"2026-06-05T10:00:00.000Z","parent_version":null,"payload":{"currency":"USD","rate_micro":"1"}}`))
        .raw("dev-a", opsBody(`{"v":1,"type":"rate_set","op_id":"o3","authored_at":"2026-06-05 10:00:00","parent_version":null,"payload":{"currency":"USD","rate_micro":"1"}}`))
        .raw("dev-a", opsBody(`{"v":1,"type":"txn_categorized","op_id":"o4","authored_at":"2026-06-05T10:00:00.000Z","parent_version":1,"payload":{}}`))
        .raw("dev-a", opsBody(`{"v":1,"type":"txn_categorized","op_id":"o5","authored_at":"2026-06-05T10:00:00.000Z","entity":{"kind":"txn","id":""},"parent_version":1,"payload":{}}`))
        .raw("dev-a", opsBody(`{"v":1,"type":"txn_categorized","op_id":"o6","authored_at":"2026-06-05T10:00:00.000Z","entity":{"kind":"txn","id":"t"},"parent_version":-1,"payload":{}}`))
        .raw("dev-a", opsBody(`{"v":1,"type":"txn_categorized","op_id":"o7","authored_at":"2026-06-05T10:00:00.000Z","entity":{"kind":"txn","id":"t"},"parent_version":1.5,"payload":{}}`))
        .raw("dev-a", opsBody(`{"v":1,"type":"txn_categorized","op_id":"o8","authored_at":"2026-06-05T10:00:00.000Z","entity":{"kind":"txn","id":"t"},"parent_version":9007199254740993,"payload":{}}`))
        .raw("dev-a", opsBody(wireIngest(1).replace(`"${"a".repeat(64)}"`, `"${"A".repeat(64)}"`)))
        .raw("dev-a", opsBody(`"not an op"`)),
    ),
    spec(g, "version-floors", "The configuration ops need schema v3 and the disposition v2; stamped lower, the blob is set aside rather than folded.", (c) =>
      c
        .raw("dev-a", opsBody(`{"v":2,"type":"bank_declared","op_id":"b2","authored_at":"2026-06-05T10:00:00.000Z","parent_version":null,"payload":{"bank":"enbd","active":true}}`, 2))
        .raw("dev-a", opsBody(`{"v":1,"type":"txn_duplicate_disposition","op_id":"d1","authored_at":"2026-06-05T10:00:00.000Z","entity":{"kind":"txn","id":"t"},"parent_version":1,"payload":{"other_txn_id":"u","disposition":"same"}}`))
        .raw("dev-a", opsBody(`{"v":3,"type":"bank_declared","op_id":"b3","authored_at":"2026-06-05T10:00:00.000Z","parent_version":null,"payload":{"bank":"enbd","active":true}}`, 3)),
    ),
    spec(g, "authored-at-canonicalised-on-decode", "A sub-millisecond authored_at is truncated on decode; the rate's updated-at is the canonical form.", (c) =>
      c.raw("dev-a", opsBody(`{"v":1,"type":"rate_set","op_id":"r1","authored_at":"2026-06-05T14:00:00.0015+04:00","parent_version":null,"payload":{"currency":"USD","rate_micro":"3672500"}}`)),
    ),
    spec(g, "parent-version-absent-reads-as-null", "An op with no parent_version key decodes as a create.", (c) =>
      c.raw("ingest", opsBody(wireIngest(1).replace(`"parent_version":null,`, ""))),
    ),
  ];
}

// "Newer" is stamped far in the future rather than SCHEMA_VERSION + 1, so a
// port that has moved on to v4 (or later) still meets an unknown version here
// and stops; the oracle's check is v > SCHEMA_VERSION either way.
const FAR_FUTURE_V = 99;

function hardStopSpecs(): Spec[] {
  const g = "hard_stops";
  return [
    spec(g, "newer-blob-version", "A blob from a newer schema stops the fold: it is never set aside.", (c) =>
      c.blob("ingest", c.ingest("t1", "i1")).raw("dev-a", opsBody("", FAR_FUTURE_V)),
    ),
    spec(g, "newer-op-inside-a-current-blob", "One op from a newer schema inside a v1 blob stops the fold, even though it is otherwise malformed.", (c) =>
      c.raw("dev-a", opsBody(`{"v":${FAR_FUTURE_V},"type":"txn_ingested"}`)),
    ),
    spec(g, "newer-configuration-op", "An op of a known type stamped with a newer schema still stops the fold.", (c) =>
      c.blob("dev-a", c.bank({ bank: "enbd", active: true })).raw("dev-a", opsBody(`{"v":${FAR_FUTURE_V},"type":"bank_declared","op_id":"b4","authored_at":"2026-06-05T10:00:00.000Z","parent_version":null,"payload":{"bank":"dib","active":true}}`, FAR_FUTURE_V)),
    ),
    spec(g, "seq-goes-backwards", "A blob behind the folded prefix is a caller error that stops the fold.", (c) =>
      c.blobAt(5n, "ingest", c.ingest("t1", "i1")).blobAt(4n, "ingest", c.ingest("t2", "i2", { merchant_raw: "B" })),
    ),
    spec(g, "seq-repeats", "One blob is one row is one seq: a second blob at the same seq stops the fold.", (c) =>
      c.blobAt(1n, "ingest", c.ingest("t1", "i1")).blobAt(1n, "dev-a", c.categorize("t1", 1, { category: "x" })),
    ),
    spec(g, "set-aside-blob-still-consumes-its-seq", "An undecodable blob advances the cursor, so its seq cannot be re-delivered with other content.", (c) =>
      c.raw("ingest", "garbage", { seq: 7n }).blobAt(7n, "ingest", c.ingest("t1", "i1")),
    ),
  ];
}

function canarySpec(): Spec {
  const c = new Case("canary");
  for (const e of CANARY()) c.blobAt(e.seq, e.writer_id, e.op);
  return {
    name: "canary-v3",
    group: "canary",
    note: "The fold-fingerprint canary of replay/snapshot.ts: every v3 op type, a real fork, a duplicate ingest, a supersede, a split, an unparsed row, frozen and pending FX and a rate_unset.",
    items: c.items,
  };
}

function fxSpecs(): Spec[] {
  return buildFXCases().map((fx) => {
    const c = new Case(fx.name);
    let i = 0;
    while (i < fx.entries.length) {
      const seq = fx.entries[i]!.seq;
      const writer = fx.entries[i]!.writer_id;
      const ops: Op[] = [];
      for (; i < fx.entries.length && fx.entries[i]!.seq === seq; i++) {
        if (fx.entries[i]!.writer_id !== writer) throw new Error(`fx ${fx.name}: two writers share seq ${seq}`);
        ops.push(fx.entries[i]!.op);
      }
      c.blobAt(BigInt(seq), writer, ...ops);
    }
    return { name: fx.name, group: "fx", note: `conformance/fx: ${fx.note}`, items: c.items };
  });
}

export function specs(): Spec[] {
  return [canarySpec(), ...fxSpecs(), ...foldSpecs(), ...configSpecs(), ...blobSpecs(), ...hardStopSpecs()];
}

// ---------------------------------------------------------------------------
// Running a case through the oracle
// ---------------------------------------------------------------------------

type Outcome = { state: State } | { error: { kind: "replay_order" | "newer_version"; at_entry: number } };

function run(items: readonly Item[], direct: boolean): Outcome {
  const s = emptyState();
  for (let i = 0; i < items.length; i++) {
    const it = items[i]!;
    try {
      if (direct && it.ops !== null) {
        for (const op of it.ops) applyOp(s, { op, seq: it.seq, writer_id: it.writer_id });
      } else {
        foldBlobs([{ pos: { writer_id: it.writer_id, stream: it.stream, writer_counter: it.writer_counter, seq: it.seq }, body: it.body }], s);
      }
    } catch (err) {
      if (err instanceof ReplayOrderError) return { error: { kind: "replay_order", at_entry: i } };
      if (err instanceof UnknownNewerVersionError) return { error: { kind: "newer_version", at_entry: i } };
      throw err;
    }
  }
  return { state: s };
}

/** Throws unless every bigint in the state fits a signed 64-bit integer. */
function assertInt64(v: unknown, path: string): void {
  if (typeof v === "bigint") {
    if (v > INT64_MAX || v < -INT64_MAX - 1n) throw new Error(`${path} = ${v} does not fit Int64`);
    return;
  }
  if (v instanceof Map) {
    for (const [k, x] of v) assertInt64(x, `${path}[${String(k)}]`);
    return;
  }
  if (v instanceof Set) return;
  if (Array.isArray(v)) {
    v.forEach((x, i) => assertInt64(x, `${path}[${i}]`));
    return;
  }
  if (v !== null && typeof v === "object") for (const [k, x] of Object.entries(v)) assertInt64(x, `${path}.${k}`);
}

function expectOf(name: string, items: readonly Item[]): Expect {
  const out = run(items, false);
  if ("error" in out) {
    // For a stopped fold the only claim is which entry stopped it and why: the
    // partially folded state is not a contract.
    return { error: out.error };
  }
  const s = out.state;
  assertInt64(s, `${name}: state`);

  const full = serializeState(s);
  // The applyOp path over the same ops must agree with the decode path; a case
  // where they differ would mean different things to different readers.
  const alt = run(items, true);
  if ("error" in alt || serializeState(alt.state) !== full) {
    throw new Error(`${name}: folding the ops directly does not reproduce the decoded fold`);
  }

  const witnessed = JSON.parse(full) as { anomalies: { detail: string }[]; unreadable: { reason: string }[] };
  if (JSON.stringify(witnessed) !== full) throw new Error(`${name}: serializeState does not round-trip through JSON`);
  for (const a of witnessed.anomalies) a.detail = "";
  for (const u of witnessed.unreadable) u.reason = "";
  const compared = JSON.stringify(witnessed);

  return {
    error: null,
    state: witnessed,
    state_sha256: sha256Hex(compared),
    order: { banks: [...s.banks.keys()], categories: [...s.categories.keys()] },
    diagnostics: {
      full_state_sha256: sha256Hex(full),
      anomalies: s.anomalies.map((a) => ({ at_seq: `${a.at_seq}`, kind: a.kind, detail: a.detail })),
      unreadable: s.unreadable.map((u) => ({ seq: `${u.seq}`, reason: u.reason })),
    },
  };
}

export function buildCases(): ReplayCase[] {
  return specs().map((sp) => ({
    name: sp.name,
    group: sp.group,
    note: sp.note,
    schema_version: 1,
    log: sp.items.map((i) => i.fixture),
    expect: expectOf(sp.name, sp.items),
  }));
}

export const fileOf = (c: { group: string; name: string }): string => `${c.group}-${c.name}.json`;

const NOTE =
  "Written by reference/ledgerd-client/scripts/gen-replay-conformance.ts from the TypeScript v3 fold oracle (src/replay); do not hand-edit. " +
  "Each case is a log of blobs in order. An `ops` item is one blob whose body is {\"v\": the largest op v, \"kind\": \"ops\", \"ops\": [...]} (its ops are wire-canonical and may be folded directly); " +
  "a `body`/`body_base64` item is a blob given as its exact plaintext body. Fold every item at its seq as sync does (decode, set aside what will not decode, fold). " +
  "`expect.error` names the entry that stops the fold; otherwise `expect.state` is serializeState with every anomalies[].detail and unreadable[].reason replaced by \"\", " +
  "and `expect.state_sha256` is the SHA-256 of that compact JSON. `expect.order` is the first-declaration order of banks and categories. `expect.diagnostics` is the oracle's own text, for reference only. See README.md.";

export function build(): FixtureFile[] {
  const cases = buildCases();
  const files = new Set<string>();
  for (const c of cases) {
    const f = fileOf(c);
    if (files.has(f)) throw new Error(`duplicate case ${f}`);
    files.add(f);
  }
  const manifest = {
    note: NOTE,
    schema_version: 1,
    fold_schema_version: 3,
    compared: "state with anomalies[].detail and unreadable[].reason blanked; order; error",
    groups: ["canary", "fx", "fold", "config", "blobs", "hard_stops"],
    cases: cases.map((c) => ({ file: fileOf(c), name: c.name, group: c.group, note: c.note })),
  };
  return [{ file: "manifest.json", text: asciiJSON(manifest) }, ...cases.map((c) => ({ file: fileOf(c), text: asciiJSON(c) }))];
}

export async function assertReplayFresh(): Promise<void> {
  await assertFresh(SUITE, build(), REGENERATE);
}

if (import.meta.main) {
  await writeOrCheck(SUITE, build(), REGENERATE);
}
