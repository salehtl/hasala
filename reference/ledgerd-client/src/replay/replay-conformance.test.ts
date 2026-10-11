/**
 * The TypeScript half of `conformance/replay/`: the committed cases are what the
 * oracle writes today, and this executor — reading each case the way the README
 * tells any executor to, from the committed JSON alone — folds every log to the
 * committed state.
 */

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { CONFORMANCE_ROOT, sha256Hex } from "../../scripts/conformance-io";
import { assertReplayFresh, type LogItem, type ReplayCase } from "../../scripts/gen-replay-conformance";
import { UnknownNewerVersionError } from "../wire/op";
import { ReplayOrderError, foldBlobs } from "./replay";
import { emptyState, serializeState, type State } from "./state";

const dir = `${CONFORMANCE_ROOT}/replay`;
const manifest = JSON.parse(readFileSync(`${dir}/manifest.json`, "utf8")) as { cases: { file: string; group: string }[] };

/** The body a log item stands for: the exact bytes, or the ops wrapped in an ops blob. */
function bodyOf(item: LogItem): Uint8Array {
  if ("ops" in item) {
    const v = item.ops.reduce<number>((max, op) => Math.max(max, (op as { v: number }).v), 1);
    return new TextEncoder().encode(JSON.stringify({ v, kind: "ops", ops: item.ops }));
  }
  if (item.body !== undefined) return new TextEncoder().encode(item.body);
  return new Uint8Array(Buffer.from(item.body_base64!, "base64"));
}

type Run = { state: State } | { error: { kind: string; at_entry: number } };

function foldCase(c: ReplayCase): Run {
  const s = emptyState();
  for (let i = 0; i < c.log.length; i++) {
    const item = c.log[i]!;
    const pos = {
      writer_id: item.writer_id,
      stream: "ops" in item ? "hot" : item.stream,
      writer_counter: "ops" in item ? 0n : BigInt(item.writer_counter),
      seq: BigInt(item.seq),
    };
    try {
      foldBlobs([{ pos, body: bodyOf(item) }], s);
    } catch (err) {
      if (err instanceof ReplayOrderError) return { error: { kind: "replay_order", at_entry: i } };
      if (err instanceof UnknownNewerVersionError) return { error: { kind: "newer_version", at_entry: i } };
      throw err;
    }
  }
  return { state: s };
}

/** serializeState with the diagnostic text blanked: the compared bytes. */
function compared(s: State): string {
  const w = JSON.parse(serializeState(s)) as { anomalies: { detail: string }[]; unreadable: { reason: string }[] };
  for (const a of w.anomalies) a.detail = "";
  for (const u of w.unreadable) u.reason = "";
  return JSON.stringify(w);
}

test("conformance/replay is what the oracle writes", async () => {
  await assertReplayFresh();
});

test("conformance/replay covers every group, both hard stops and every anomaly kind it can reach", () => {
  const cases = manifest.cases.map((m) => JSON.parse(readFileSync(`${dir}/${m.file}`, "utf8")) as ReplayCase);
  expect(new Set(cases.map((c) => c.group))).toEqual(new Set(["canary", "fx", "fold", "config", "blobs", "hard_stops"]));
  expect(new Set(cases.flatMap((c) => (c.expect.error === null ? [] : [c.expect.error.kind])))).toEqual(new Set(["replay_order", "newer_version"]));
  const kinds = new Set(cases.flatMap((c) => c.expect.diagnostics?.anomalies.map((a) => a.kind) ?? []));
  // Every kind the v3 fold can raise from a well-formed sync. `invalid_op` and
  // `unhandled_op` are unreachable from the wire (decode refuses the op first,
  // and every op type has a handler), so no log can carry them.
  for (const k of [
    "duplicate_delivery",
    "invalid_payload",
    "home_currency_reset",
    "rate_set_before_home_currency",
    "rate_set_for_home_currency",
    "rate_unset_for_home_currency",
    "entity_kind_mismatch",
    "invalid_parent",
    "duplicate_create",
    "nonexistent_parent",
    "unknown_entity",
    "future_parent",
    "duplicate_ingest",
    "supersede_without_origin",
    "split_sum",
    "edit_of_superseded",
    "duplicate_disposition_mismatch",
    "unsupported_edit_field",
    "possible_duplicate",
  ]) {
    expect(kinds.has(k)).toBe(true);
  }
});

for (const m of manifest.cases) {
  const c = JSON.parse(readFileSync(`${dir}/${m.file}`, "utf8")) as ReplayCase;
  test(`replay conformance: ${m.file}`, () => {
    const got = foldCase(c);
    if (c.expect.error !== null) {
      expect("error" in got ? got.error : null).toEqual(c.expect.error);
      return;
    }
    if ("error" in got) throw new Error(`folding stopped at entry ${got.error.at_entry}: ${got.error.kind}`);
    const bytes = compared(got.state);
    expect(JSON.parse(bytes)).toEqual(c.expect.state);
    expect(sha256Hex(bytes)).toBe(c.expect.state_sha256!);
    expect(sha256Hex(serializeState(got.state))).toBe(c.expect.diagnostics!.full_state_sha256);
    expect({ banks: [...got.state.banks.keys()], categories: [...got.state.categories.keys()] }).toEqual(c.expect.order!);
  });
}
