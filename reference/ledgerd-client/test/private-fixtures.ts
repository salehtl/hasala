/**
 * Where the real bank mail lives, for the tests that need it.
 *
 * The conformance and e2e suites were written against the operator's own mail:
 * the 37 normalizer cases, the corpus-*.json template cases and the seven raw,
 * DKIM/ARC-signed `.eml` messages. That mail names real people, accounts and
 * transactions, so it is kept in the private `salehtl/hasala-fixtures`
 * repository under the same repo-relative paths it had here. This is the
 * TypeScript twin of `server/internal/privatefixtures`.
 *
 *   - `HASALA_PRIVATE_FIXTURES` unset: every test that needs a file is
 *     registered with `test.skipIf(...)` and SKIPS. Its name starts with
 *     {@link REAL_CORPUS}, which is how `scripts/check.sh` counts them.
 *   - set: those tests run. A file that is missing from the checkout THROWS
 *     ({@link privateFile}), so a broken checkout fails the run instead of
 *     passing as a quiet skip.
 *
 * The synthetic suites (`edge-cases.json`, `synthetic-*.json`, everything built
 * in code) never come through here and always run.
 */

import { existsSync } from "node:fs";
import { isAbsolute, join } from "node:path";

export const PRIVATE_FIXTURES_ENV = "HASALA_PRIVATE_FIXTURES";
export const PRIVATE_FIXTURES_REPO = "salehtl/hasala-fixtures";

/** Prefix of every gated test's name. scripts/check.sh counts on it. */
export const REAL_CORPUS = "[real-corpus]";

/** The configured checkout, or undefined when the variable is unset. */
export const privateRoot: string | undefined = (process.env[PRIVATE_FIXTURES_ENV] ?? "").trim() || undefined;

if (privateRoot !== undefined && !isAbsolute(privateRoot)) {
  // Bun resolves a relative path against each test process's cwd; the Go half
  // runs from every package directory. Only an absolute path means one place.
  throw new Error(`${REAL_CORPUS} ${PRIVATE_FIXTURES_ENV}=${JSON.stringify(privateRoot)} must be an absolute path`);
}

/** True when the real corpus is NOT available and gated tests must skip. */
export const noPrivateFixtures: boolean = privateRoot === undefined;

/**
 * The absolute path of `rel` (repo-relative, e.g.
 * `conformance/normalizer/manifest.json`) inside the private checkout.
 *
 * Call it only when {@link privateRoot} is set (guard with
 * {@link noPrivateFixtures}). It throws when the variable is unset — the caller
 * forgot the guard — and when the file is missing from a configured checkout.
 */
export function privateFile(rel: string): string {
  if (privateRoot === undefined) {
    throw new Error(`${REAL_CORPUS} ${rel} needs ${PRIVATE_FIXTURES_ENV}; guard the caller with noPrivateFixtures`);
  }
  const p = join(privateRoot, rel);
  if (!existsSync(p)) {
    throw new Error(
      `${REAL_CORPUS} ${PRIVATE_FIXTURES_ENV}=${privateRoot}, but ${rel} is not in that checkout: ` +
        `it is not a complete ${PRIVATE_FIXTURES_REPO} checkout, or the fixture was renamed on one side only`,
    );
  }
  return p;
}

/** A gated test's name: the marker, then the name it always had. */
export function realCorpus(name: string): string {
  return `${REAL_CORPUS} ${name}`;
}
