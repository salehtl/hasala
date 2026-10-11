// realcorpus-summary.ts — reads the JUnit XML `bun test --reporter=junit` wrote
// for scripts/check.sh and counts the tests gated on the private real-mail
// fixtures (reference/ledgerd-client/test/private-fixtures.ts).
//
// A gated test carries "[real-corpus]" in its own name or in the name of a
// describe block around it. Bun writes a describe block as a nested
// <testsuite>, so the marker is looked for on the testcase and on every
// enclosing testsuite.
//
//   bun scripts/realcorpus-summary.ts JUNIT.xml [COUNTS_FILE]
//
// Prints one line; with COUNTS_FILE, also writes "<ran> <skipped>" there.

const REAL_CORPUS = "[real-corpus]";

const [file, countsFile] = process.argv.slice(2);
if (!file) {
  console.error("usage: bun scripts/realcorpus-summary.ts JUNIT.xml [COUNTS_FILE]");
  process.exit(2);
}
const xml = await Bun.file(file).text();

const unescape = (s: string): string =>
  s.replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
const nameOf = (tag: string): string => unescape(/\bname="([^"]*)"/.exec(tag)?.[1] ?? "");

const suites: string[] = [];
let ran = 0;
let skipped = 0;
let total = 0;
// <testsuite ...>, </testsuite>, and <testcase .../> or <testcase ...>...</testcase>.
const token = /<testsuite\b[^>]*>|<\/testsuite>|<testcase\b[^>]*\/>|<testcase\b[^>]*>[\s\S]*?<\/testcase>/g;
for (const m of xml.matchAll(token)) {
  const t = m[0];
  if (t.startsWith("</testsuite")) {
    suites.pop();
  } else if (t.startsWith("<testsuite")) {
    suites.push(nameOf(t));
  } else {
    total++;
    const open = /^<testcase\b[^>]*>/.exec(t)?.[0] ?? t;
    if (![nameOf(open), ...suites].some((n) => n.includes(REAL_CORPUS))) continue;
    if (/<skipped\b/.test(t)) skipped++;
    else ran++;
  }
}
if (total === 0) {
  console.error(`realcorpus-summary: ${file} holds no test cases; refusing to report on nothing`);
  process.exit(1);
}
console.log(`bun test: real corpus (HASALA_PRIVATE_FIXTURES): ${ran} tests ran against it, ${skipped} skipped without it`);
if (countsFile) await Bun.write(countsFile, `${ran} ${skipped}\n`);
