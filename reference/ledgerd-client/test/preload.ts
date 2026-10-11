/**
 * Installs the host `Platform` for every `bun test` process.
 *
 * # Why this file exists
 *
 * The registry moved out of `platform.ts` into `platform.registry.ts` so a
 * browser can call `setPlatform` without dragging `node:zlib`/`node:crypto`
 * into its bundle (see that module's doc). The cost is that `platform.ts` — and
 * therefore the guarded `setPlatform(bunPlatform)` at the bottom of it — is no
 * longer imported by `wire/op.ts`, `store/store.ts` and the seven other modules
 * that used to pull it in transitively. Host entrypoints now install it
 * themselves: `cli/main.ts`, `store/open.ts`, `store/file.ts`, `store/driver.ts`
 * and the child scripts the outbox and engine tests spawn.
 *
 * A test file is an entrypoint too, and there are 36 of them. Without this,
 * `bun test` as a whole still passed — some file in the run imports a store and
 * installs the platform for everybody, because every file shares one process —
 * while `bun test src/wire/op.test.ts` ON ITS OWN failed 22 of 35 tests with
 * "no Platform installed". A suite that is green in bulk and red one file at a
 * time is worse than one that is simply red: running a single file is what
 * anybody does while actually working on it.
 *
 * # `[test] preload`, deliberately not a top-level one
 *
 * `bunfig.toml` puts this under `[test]`, so it applies to `bun test` and NOT
 * to `bun run`. That matters: `outbox.test.ts` and `engine.test.ts` write child
 * programs and `Bun.spawn(["bun", "run", ...])` them, and those children are the
 * only thing in this repo that proves a fresh process can still start. A
 * top-level preload would install the platform for them too and hide exactly
 * the failure this whole change had to be checked against — the three
 * subprocess tests that caught the missing install in the first place.
 */

import "../src/platform";

// ---------------------------------------------------------------------------
// One scratch directory per `bun test` run, removed when the run exits
// ---------------------------------------------------------------------------
//
// The suites make dozens of temporary directories (stores, outboxes, audit
// databases, the e2e harness's binary and stacks), and most of them never
// removed theirs. With HASALA_PRIVATE_FIXTURES set, some of those hold data
// derived from real bank mail. So every run gets ONE directory, TMPDIR (and
// therefore os.tmpdir(), and every child process) points into it, and it is
// deleted on exit — pass, fail, or interrupt. A run killed outright (SIGKILL)
// cannot clean up; the next run removes such leftovers once they are old
// enough that no concurrent run can still be using them.
import { afterAll } from "bun:test";
import { mkdtempSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const RUN_PREFIX = "ledger-test-run-";
const root = process.env["LEDGER_TEST_TMP_ROOT"] ?? tmpdir();
process.env["LEDGER_TEST_TMP_ROOT"] = root;

const staleAfterMs = 6 * 60 * 60 * 1000;
for (const name of readdirSync(root)) {
  if (!name.startsWith(RUN_PREFIX)) continue;
  try {
    const dir = join(root, name);
    if (Date.now() - statSync(dir).mtimeMs > staleAfterMs) rmSync(dir, { recursive: true, force: true });
  } catch {
    /* another run removed it first */
  }
}

const runDir = mkdtempSync(join(root, RUN_PREFIX));
for (const v of ["TMPDIR", "TMP", "TEMP"]) process.env[v] = runDir;

const removeRunDir = (): void => {
  try {
    rmSync(runDir, { recursive: true, force: true });
  } catch {
    /* nothing left to do on the way out */
  }
};
// A hook in a preload file is GLOBAL in bun test: it runs once, after every test
// file of the run has finished. Bun's runner does not reliably emit "exit" to
// preload code, so the hook is the primary path and "exit" is the fallback.
afterAll(removeRunDir);
process.on("exit", removeRunDir);
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.on(signal, () => {
    removeRunDir();
    process.exit(128 + (signal === "SIGINT" ? 2 : signal === "SIGTERM" ? 15 : 1));
  });
}
