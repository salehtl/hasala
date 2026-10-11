// @ts-check
/**
 * One Content-Security-Policy for every page, for <ClientRouter />.
 *
 * Astro writes a CSP <meta> per page, hashing only that page's inline
 * <script>s and <style>s. On a client-side navigation the router puts the
 * next page's <head> into the same document, and a document enforces every
 * CSP it has ever been given: after / → /privacy, the styles of /privacy
 * would also have to pass the policy of /, and get blocked. Astro also does
 * not hash the <style> it writes for transition:name.
 *
 * So once the build is done this merges the script-src and style-src of
 * every page, adds the hash of every inline script and style found in the
 * output, writes that one policy into every page, and marks the <meta>
 * transition:persist so the router keeps the one it has rather than stacking
 * copies. scripts/router.ts reloads the page instead of swapping if a
 * fetched page ever carries a different policy (a deploy mid-visit).
 *
 * The build fails if two pages disagree on any other directive.
 */
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const META = /<meta http-equiv="content-security-policy" content="([^"]*)"\s*\/?>/i;
const INLINE_SCRIPT = /<script(?![^>]*\ssrc=)([^>]*)>([\s\S]*?)<\/script>/gi;
const INLINE_STYLE = /<style[^>]*>([\s\S]*?)<\/style>/gi;
/** Script types the browser runs, so CSP checks them; data blocks (JSON-LD) are not. */
const RUNS = /^(|text\/javascript|module|application\/javascript)$/i;

/** @param {string} text */
const sha256 = (text) => `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;

/** @param {string} dir @returns {Promise<string[]>} */
async function htmlFiles(dir) {
  const out = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...(await htmlFiles(p)));
    else if (e.name.endsWith('.html')) out.push(p);
  }
  return out;
}

/** "a b; c d" → [["a", ["b"]], ["c", ["d"]]], in order. @param {string} csp */
const parse = (csp) =>
  csp
    .split(';')
    .map((d) => d.trim().split(/\s+/))
    .filter((d) => d[0])
    .map(([name, ...values]) => /** @type {[string, string[]]} */ ([name, values]));

/** @returns {import('astro').AstroIntegration} */
export default function cspUnion() {
  return {
    name: 'hasala:csp-union',
    hooks: {
      'astro:build:done': async ({ dir, logger }) => {
        const root = fileURLToPath(dir);
        const pages = [];
        for (const file of await htmlFiles(root)) {
          const html = await readFile(file, 'utf8');
          const m = META.exec(html);
          if (m) pages.push({ file, html, directives: parse(m[1].replaceAll('&#39;', "'")) });
        }
        if (!pages.length) return;

        /** @type {Record<string, Set<string>>} */
        const merged = { 'script-src': new Set(), 'style-src': new Set() };
        const others = (/** @type {[string, string[]][]} */ d) =>
          JSON.stringify(d.filter(([n]) => !(n in merged)));
        const template = pages[0].directives;
        for (const page of pages) {
          if (others(page.directives) !== others(template)) {
            throw new Error(`CSP of ${page.file} differs from ${pages[0].file} outside script-src/style-src; one policy cannot serve both.`);
          }
          for (const [name, values] of page.directives) if (name in merged) values.forEach((v) => merged[name].add(v));
          for (const [, attrs, body] of page.html.matchAll(INLINE_SCRIPT)) {
            const type = /\stype="([^"]*)"/i.exec(attrs)?.[1] ?? '';
            if (RUNS.test(type)) merged['script-src'].add(sha256(body));
          }
          for (const [, body] of page.html.matchAll(INLINE_STYLE)) merged['style-src'].add(sha256(body));
        }

        // Sources first, as Astro writes them, then the hashes in a stable order.
        const values = (/** @type {Set<string>} */ set) => [...[...set].filter((v) => !v.startsWith("'sha")), ...[...set].filter((v) => v.startsWith("'sha")).sort()];
        const policy = template.map(([name, v]) => [name, ...(name in merged ? values(merged[name]) : v)].join(' ')).join('; ');
        const meta = `<meta http-equiv="content-security-policy" content="${policy}" data-astro-transition-persist="csp">`;
        await Promise.all(pages.map((p) => writeFile(p.file, p.html.replace(META, () => meta))));
        logger.info(
          `one CSP for ${pages.length} pages: ${merged['script-src'].size} script-src and ${merged['style-src'].size} style-src entries`,
        );
      },
    },
  };
}
