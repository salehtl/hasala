// gotest-summary.ts — reads `go test -json` on stdin for scripts/check.sh.
//
// Streams one line per package as it finishes, then prints the full output of
// every failing test, every skipped test with its reason, and the totals.
// Exits 1 if any test or package failed, or if no test ran at all: a run that
// collected nothing must never read as a pass.
//
// Skips are listed on every run rather than counted silently. A test that
// skips because its fixture moved looks exactly like a pass otherwise.
//
// Tests that need the private real-mail fixtures (internal/privatefixtures)
// write "[real-corpus]" into their output: a log line when they run against
// $HASALA_PRIVATE_FIXTURES, the skip reason when it is unset. Those are counted
// separately, printed, and — when REALCORPUS_COUNTS names a file — written there
// as "<ran> <skipped>" for scripts/check.sh's closing summary.

type Event = {
  Action: string;
  Package?: string;
  ImportPath?: string;
  Test?: string;
  Output?: string;
  Elapsed?: number;
};

const output = new Map<string, string[]>();
const failed: string[] = [];
const skipped: string[] = [];
const totals = { pass: 0, fail: 0, skip: 0 };
const packages = { ok: 0, fail: 0, noTests: 0 };
const key = (e: Event) => `${e.Package ?? ""} ${e.Test ?? ""}`;
const REAL_CORPUS = "[real-corpus]";
const realCorpus = { ran: 0, skipped: 0 };
const marked = (k: string): boolean => (output.get(k) ?? []).some((l) => l.includes(REAL_CORPUS));

for await (const line of console) {
  if (!line.startsWith("{")) {
    if (line.trim() !== "") console.log(line);
    continue;
  }
  const e = JSON.parse(line) as Event;
  if (e.Action === "build-output") {
    process.stdout.write(e.Output ?? "");
    continue;
  }
  if (e.Action === "output") {
    const k = key(e);
    const lines = output.get(k) ?? [];
    lines.push(e.Output ?? "");
    output.set(k, lines);
    continue;
  }
  if (e.Test === undefined) {
    // A package-level result.
    if (e.Action === "pass") {
      packages.ok++;
      console.log(`ok    ${e.Package} (${e.Elapsed ?? 0}s)`);
    } else if (e.Action === "fail") {
      packages.fail++;
      console.log(`FAIL  ${e.Package} (${e.Elapsed ?? 0}s)`);
      // A package that fails outside any test (TestMain, a panic between
      // tests, a build failure) has its reason only in package-level output.
      failed.push(key(e));
    } else if (e.Action === "skip") {
      packages.noTests++;
    }
    continue;
  }
  if (e.Action === "pass" || e.Action === "fail" || e.Action === "skip") {
    totals[e.Action]++;
    if (e.Action === "fail") failed.push(key(e));
    if (e.Action === "skip") skipped.push(key(e));
    if (marked(key(e))) {
      if (e.Action === "skip") realCorpus.skipped++;
      else realCorpus.ran++;
    }
  }
}

const reason = (k: string): string => {
  const lines = (output.get(k) ?? []).map((l) => l.trim()).filter((l) => l !== "" && !l.startsWith("--- SKIP") && !l.startsWith("=== "));
  return lines.at(-1) ?? "(no reason given)";
};

if (skipped.length > 0) {
  console.log(`\nskipped (${skipped.length}):`);
  for (const k of skipped) console.log(`  ${k}\n      ${reason(k)}`);
}
if (failed.length > 0) {
  console.log(`\nfailed (${failed.length}):`);
  for (const k of failed) {
    console.log(`\n=== ${k}`);
    process.stdout.write((output.get(k) ?? ["(no output)\n"]).join(""));
  }
}
console.log(
  `\ngo test: ${totals.pass} passed, ${totals.fail} failed, ${totals.skip} skipped (tests and subtests); ` +
    `${packages.ok} packages ok, ${packages.fail} failed, ${packages.noTests} without tests`,
);
console.log(
  `go test: real corpus (HASALA_PRIVATE_FIXTURES): ${realCorpus.ran} tests ran against it, ${realCorpus.skipped} skipped without it`,
);
const countsFile = process.env["REALCORPUS_COUNTS"];
if (countsFile) await Bun.write(countsFile, `${realCorpus.ran} ${realCorpus.skipped}\n`);
if (failed.length > 0 || packages.fail > 0) process.exit(1);
if (totals.pass === 0) {
  console.log("go test: nothing ran; refusing to call that a pass");
  process.exit(1);
}
