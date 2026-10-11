/**
 * Shared plumbing for the oracle fixture generators: where `conformance/` is,
 * how a fixture file is written, and how a committed suite is checked for
 * freshness.
 *
 * The generators that use this (`gen-replay-conformance.ts`,
 * `gen-authres-conformance.ts`, `gen-categorize-conformance.ts`,
 * `gen-norm-dates-conformance.ts`) write the TypeScript-oracle suites the Swift
 * port is checked against. Each one is a pure function of the code in this
 * package: no clock, no randomness, no network, no environment. Running one
 * twice writes identical bytes, and each suite's bun test re-derives the files
 * in memory and fails when the committed bytes differ (see {@link assertFresh}),
 * so `scripts/check.sh` catches a fixture that was edited by hand or not
 * regenerated after a change to the oracle.
 */

import { mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

/** The repository's `conformance/` directory (this file is `reference/ledgerd-client/scripts/`). */
export const CONFORMANCE_ROOT = resolve(import.meta.dir, "../../../conformance");

/** One file a generator writes, relative to its suite directory. */
export interface FixtureFile {
  file: string;
  text: string;
}

/**
 * JSON with two-space indentation and a trailing newline, ASCII only.
 *
 * Every code point above U+007E is written as a `\uXXXX` escape (astral ones
 * as their surrogate pair, which is how JSON spells them). The fixtures are
 * full of characters an editor or a diff would hide or rewrite — U+00A0,
 * U+202F, U+FEFF, U+2028, combining marks, Arabic — and an ASCII file shows
 * every one of them and cannot be renormalized on the way to the reader. The
 * VALUES are unchanged: any JSON parser reads the escapes back to the same
 * strings.
 *
 * No generator emits a lone surrogate (the Swift reader could not hold one), and
 * {@link asciiJSON} refuses one rather than writing it. It also refuses a
 * string that STARTS with U+FEFF: Foundation's JSONSerialization, which the
 * Swift package's corpus test uses as the independent reference parser for
 * every conformance file, drops a leading U+FEFF from a string value, so such
 * a file would fail that cross-check for a reason that has nothing to do with
 * the suite. A vector that needs a BOM puts something before it.
 */
export function asciiJSON(value: unknown): string {
  assertNoLeadingBOM(value, "$");
  const text = JSON.stringify(value, null, 2);
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const d = text.charCodeAt(i + 1);
      if (!(d >= 0xdc00 && d <= 0xdfff)) throw new Error(`lone high surrogate at ${i}`);
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      const p = text.charCodeAt(i - 1);
      if (!(p >= 0xd800 && p <= 0xdbff)) throw new Error(`lone low surrogate at ${i}`);
    }
    out += c > 0x7e ? `\\u${c.toString(16).padStart(4, "0")}` : text[i];
  }
  return out + "\n";
}

function assertNoLeadingBOM(v: unknown, path: string): void {
  if (typeof v === "string") {
    if (v.startsWith("\ufeff")) throw new Error(`${path} starts with U+FEFF, which JSONSerialization drops; put something before it`);
    return;
  }
  if (Array.isArray(v)) {
    v.forEach((x, i) => assertNoLeadingBOM(x, `${path}[${i}]`));
    return;
  }
  if (v !== null && typeof v === "object") {
    for (const [k, x] of Object.entries(v)) {
      assertNoLeadingBOM(k, `${path} key`);
      assertNoLeadingBOM(x, `${path}.${k}`);
    }
  }
}

/** Lowercase hex SHA-256 of a string's UTF-8 bytes. */
export function sha256Hex(text: string): string {
  return new Bun.CryptoHasher("sha256").update(text).digest("hex");
}

/**
 * Fails unless `conformance/<suite>/` holds exactly `files` (plus `README.md`),
 * byte for byte.
 *
 * A stale fixture is worse than none: its runner still passes against the
 * committed bytes, and the other executor is then checked against an
 * expectation nothing generates any more. A file left behind by a removed case
 * is caught too.
 */
export async function assertFresh(suite: string, files: readonly FixtureFile[], regenerate: string): Promise<void> {
  const dir = join(CONFORMANCE_ROOT, suite);
  const fix = `regenerate with \`cd reference/ledgerd-client && ${regenerate}\``;
  for (const f of files) {
    const path = join(dir, f.file);
    const handle = Bun.file(path);
    if (!(await handle.exists())) throw new Error(`conformance/${suite}/${f.file} is missing: ${fix}`);
    if ((await handle.text()) !== f.text) {
      throw new Error(`conformance/${suite}/${f.file} is not what the oracle writes: ${fix}`);
    }
  }
  const present = (await readdir(dir)).filter((n) => n !== "README.md").sort();
  const want = files.map((f) => f.file).sort();
  if (present.join("\n") !== want.join("\n")) {
    throw new Error(`conformance/${suite} holds [${present.join(", ")}], the oracle writes [${want.join(", ")}]: ${fix}`);
  }
}

/**
 * The body of every generator's `import.meta.main`: write the suite, or with
 * `--check` compare it and exit 1 on a difference without touching the tree.
 */
export async function writeOrCheck(suite: string, files: readonly FixtureFile[], regenerate: string): Promise<void> {
  if (process.argv.includes("--check")) {
    try {
      await assertFresh(suite, files, regenerate);
    } catch (err) {
      console.error((err as Error).message);
      process.exit(1);
    }
    console.log(`conformance/${suite}: ${files.length} file(s) fresh`);
    return;
  }
  const dir = join(CONFORMANCE_ROOT, suite);
  await mkdir(dir, { recursive: true });
  // The directory has one writer (this generator), so a file it no longer
  // writes is a removed case and goes; README.md is hand-written and stays.
  const keep = new Set(files.map((f) => f.file));
  for (const name of await readdir(dir)) {
    if (name !== "README.md" && !keep.has(name)) {
      await rm(join(dir, name));
      console.log(`conformance/${suite}: removed ${name}`);
    }
  }
  for (const f of files) await writeFile(join(dir, f.file), f.text);
  console.log(`conformance/${suite}: wrote ${files.length} file(s)`);
}
