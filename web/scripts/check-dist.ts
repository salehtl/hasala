/**
 * Checks the built site in dist/ (run after `astro build`; `bun run build`
 * runs it). Exits non-zero on any problem.
 *
 * CSP. <ClientRouter /> keeps the first page's policy for the whole visit, so
 * src/lib/csp-union.mjs writes one policy into every page. This verifies it
 * independently:
 *   - every page has exactly one CSP <meta>, marked transition:persist;
 *   - every page carries the same policy;
 *   - every inline <script> the browser runs (not JSON-LD) and every inline
 *     <style>, on any page, is allowed by that policy's hash list;
 *   - no element has a style="" attribute (blocked without 'unsafe-inline');
 *   - every <script src> is same-origin, or Cloudflare Turnstile.
 *
 * JS budget. The JavaScript a page loads up front: its module scripts, their
 * static imports (recursively; dynamic import() is not followed) and its
 * executable inline scripts, gzipped (level 9) file by file. / must stay at
 * or under JS_BUDGET; every page's figure is printed.
 *
 *   bun scripts/check-dist.ts [dist]      (V=1 lists each page's files)
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';

const JS_BUDGET = 15 * 1024;
const BUDGET_PAGES = ['index.html'];
const SCRIPT_ORIGINS = ['https://challenges.cloudflare.com'];

const dist = process.argv[2] ?? fileURLToPath(new URL('../dist', import.meta.url));

const META = /<meta http-equiv="content-security-policy"[^>]*>/gi;
const INLINE_SCRIPT = /<script(?![^>]*\ssrc=)([^>]*)>([\s\S]*?)<\/script>/gi;
const INLINE_STYLE = /<style[^>]*>([\s\S]*?)<\/style>/gi;
const STYLE_ATTR = /<[a-z][^>]*\sstyle=["']/gi;
const SCRIPT_SRC = /<script[^>]*\ssrc="([^"]*)"/gi;
const MODULE_SRC = /<script type="module" src="([^"]+)"/g;
const STATIC_IMPORT = /(?:from|import)\s*["'](\.\/[^"']+|\/_astro\/[^"']+)["']/g;
/** Script types the browser runs, so CSP checks them; data blocks (JSON-LD) are not. */
const RUNS = /^(|text\/javascript|module|application\/javascript)$/i;

const sha256 = (s: string) => `'sha256-${createHash('sha256').update(s, 'utf8').digest('base64')}'`;
const gz = (b: Uint8Array) => gzipSync(b, { level: 9 }).length;
const kb = (n: number) => (n / 1024).toFixed(2);
const preview = (s: string) => JSON.stringify(s.slice(0, 60));

function htmlFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return htmlFiles(p);
    return e.name.endsWith('.html') ? [p] : [];
  });
}

const problems: string[] = [];
const files = htmlFiles(dist).sort();
if (!files.length) problems.push(`no HTML in ${dist}: build first`);

const policies = new Map<string, string>();
const inline: { page: string; kind: 'script' | 'style'; hash: string; body: string }[] = [];
const pages = new Map<string, string>();

for (const file of files) {
  const page = relative(dist, file);
  const html = readFileSync(file, 'utf8');
  pages.set(page, html);

  const metas = html.match(META) ?? [];
  if (metas.length !== 1) {
    problems.push(`${page}: expected 1 CSP <meta>, found ${metas.length}`);
    continue;
  }
  if (!metas[0].includes('data-astro-transition-persist="csp"')) problems.push(`${page}: CSP <meta> is not transition:persist`);
  const content = /content="([^"]+)"/.exec(metas[0])?.[1];
  if (!content) {
    problems.push(`${page}: CSP <meta> has no content`);
    continue;
  }
  policies.set(page, content.replaceAll('&#39;', "'"));

  for (const [, attrs, body] of html.matchAll(INLINE_SCRIPT)) {
    if (RUNS.test(/\stype="([^"]*)"/i.exec(attrs)?.[1] ?? '')) inline.push({ page, kind: 'script', hash: sha256(body), body });
  }
  for (const [, body] of html.matchAll(INLINE_STYLE)) inline.push({ page, kind: 'style', hash: sha256(body), body });
  for (const [tag] of html.matchAll(STYLE_ATTR)) problems.push(`${page}: style="" attribute (blocked without 'unsafe-inline'): ${tag.slice(0, 80)}`);
  for (const [, src] of html.matchAll(SCRIPT_SRC)) {
    const self = src.startsWith('/') && !src.startsWith('//');
    if (!self && !SCRIPT_ORIGINS.some((o) => src.startsWith(`${o}/`))) problems.push(`${page}: <script src> from another origin: ${src}`);
  }
}

if (new Set(policies.values()).size > 1) problems.push(`pages carry ${new Set(policies.values()).size} different CSPs; they must share one`);
for (const [page, csp] of policies) {
  const directives = new Map(
    csp
      .split(';')
      .map((d) => d.trim().split(/\s+/))
      .filter((d) => d[0])
      .map(([name, ...values]) => [name, new Set(values)] as const),
  );
  for (const x of inline) {
    if (!directives.get(`${x.kind}-src`)?.has(x.hash)) problems.push(`${x.page}: inline ${x.kind} not allowed by the CSP of ${page}: ${preview(x.body)}`);
  }
}
console.log(`CSP: ${policies.size} pages, ${inline.length} inline scripts/styles checked against every page's policy`);

// JS budget.
for (const [page, html] of pages) {
  const todo = [...html.matchAll(MODULE_SRC)].map((m) => m[1]);
  const seen = new Set<string>();
  const loaded: { path: string; bytes: Uint8Array }[] = [];
  while (todo.length) {
    const src = todo.pop()!;
    if (seen.has(src)) continue;
    seen.add(src);
    let bytes: Uint8Array;
    try {
      bytes = readFileSync(join(dist, src.replace(/^\//, '')));
    } catch {
      problems.push(`${page}: module script ${src} is not in dist`);
      continue;
    }
    loaded.push({ path: src, bytes });
    for (const [, imp] of new TextDecoder().decode(bytes).matchAll(STATIC_IMPORT)) {
      todo.push(imp.startsWith('./') ? `/_astro/${imp.slice(2)}` : imp);
    }
  }
  const inl = new TextEncoder().encode(
    [...html.matchAll(INLINE_SCRIPT)]
      .filter(([, attrs]) => RUNS.test(/\stype="([^"]*)"/i.exec(attrs)?.[1] ?? ''))
      .map(([, , body]) => body)
      .join(''),
  );
  const raw = loaded.reduce((n, f) => n + f.bytes.length, 0) + inl.length;
  const gzip = loaded.reduce((n, f) => n + gz(f.bytes), 0) + (inl.length ? gz(inl) : 0);
  const budgeted = BUDGET_PAGES.includes(page);
  console.log(
    `JS ${page.padEnd(22)} raw ${kb(raw).padStart(6)} KB | gzip ${kb(gzip).padStart(5)} KB | ${loaded.length} files + ${inl.length} B inline${budgeted ? ` | budget ${kb(JS_BUDGET)} KB` : ''}`,
  );
  if (process.env.V) for (const f of loaded.sort((a, b) => a.path.localeCompare(b.path))) console.log(`    ${f.path.padEnd(60)} ${String(f.bytes.length).padStart(6)} B  gz ${String(gz(f.bytes)).padStart(5)} B`);
  if (budgeted && gzip > JS_BUDGET) problems.push(`${page}: ${kb(gzip)} KB of JS (gzip) is over the ${kb(JS_BUDGET)} KB budget`);
}

for (const p of problems) console.error(`✗ ${p}`);
console.log(problems.length ? `${problems.length} problem(s)` : 'dist checks passed');
process.exit(problems.length ? 1 : 0);
