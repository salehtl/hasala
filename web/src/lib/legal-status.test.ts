import { describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { draftLegalPaths, legalStatus } from './legal-status.mjs';

const read = (path: string) => Bun.file(new URL(path, import.meta.url)).text();
const page = (status: string | null, body = 'Words.') => `---\ntitle: "T"\n${status === null ? '' : `status: ${status}\n`}---\n\n${body}\n`;

function folder(files: Record<string, string>) {
  const dir = mkdtempSync(join(tmpdir(), 'legal-status-'));
  for (const [name, text] of Object.entries(files)) writeFileSync(join(dir, name), text);
  return { url: pathToFileURL(`${dir}/`), done: () => rmSync(dir, { recursive: true }) };
}

describe('the status of a legal page', () => {
  for (const [written, status] of [
    ['"final"', 'final'],
    ["'final'", 'final'],
    ['final', 'final'],
    ['"draft"', 'draft'],
    ['draft', 'draft'],
  ]) {
    test(`${written} is ${status}`, () => {
      expect(legalStatus('p.md', page(written))).toBe(status);
    });
  }

  test('a page with no status is a draft', () => {
    expect(legalStatus('p.md', page(null))).toBe('draft');
  });

  for (const written of ['"Draft"', 'DRAFT', 'drafts', '"review"', 'finale', '"final-ish"', '""']) {
    test(`${written} stops the build and names the file`, () => {
      expect(() => legalStatus('privacy.md', page(written))).toThrow(/privacy\.md/);
    });
  }

  test('a final page with a note for the owner stops the build', () => {
    expect(() => legalStatus('terms.md', page('"final"', 'Text [[OWNER: confirm this]] more.'))).toThrow(/terms\.md.*draft/s);
  });

  test('a note that a link splits still counts', () => {
    expect(() => legalStatus('terms.md', page('final', '[[OWNER: ask a@b.example first]]'))).toThrow(/terms\.md/);
  });

  test('a draft may carry notes for the owner', () => {
    expect(legalStatus('terms.md', page('"draft"', '[[OWNER: confirm this]]'))).toBe('draft');
  });

  test('a note in draftNote does not count, because a final page does not show it', () => {
    expect(legalStatus('terms.md', '---\nstatus: final\ndraftNote: "no [[OWNER: x]] left"\n---\n\nWords.\n')).toBe('final');
  });

  for (const field of ['title', 'description', 'standfirst', 'plainWords', 'contact']) {
    test(`a final page with a note in ${field} stops the build`, () => {
      expect(() => legalStatus('terms.md', `---\nstatus: final\n${field}: "We keep it. [[OWNER: confirm the period]]"\n---\n\nWords.\n`)).toThrow(/terms\.md.*draft/s);
    });
  }

  test('a final page with a note in one section of plainWords stops the build', () => {
    expect(() => legalStatus('terms.md', '---\nstatus: final\nplainWords:\n  what-we-keep: "[[OWNER: confirm the period]]"\n---\n\nWords.\n')).toThrow(/terms\.md/);
  });

  test('draftNote does not excuse a note in another field', () => {
    expect(() => legalStatus('terms.md', '---\nstatus: final\ndraftNote: "fine"\nstandfirst: "[[OWNER: rewrite]]"\n---\n\nWords.\n')).toThrow(/terms\.md/);
  });

  test('a note in the page still counts after a rule in the text', () => {
    expect(() => legalStatus('terms.md', page('final', 'One.\n\n---\n\n[[OWNER: confirm this]]'))).toThrow(/terms\.md/);
  });

  test('a draft may carry notes in its front matter', () => {
    expect(legalStatus('terms.md', '---\nstatus: draft\nplainWords: "[[OWNER: confirm the period]]"\n---\n\nWords.\n')).toBe('draft');
  });

  test('the pages in the repository are valid', async () => {
    for (const name of ['privacy', 'terms', 'security', 'support']) {
      expect(['draft', 'final']).toContain(legalStatus(`${name}.md`, await read(`../../../docs/legal/${name}.md`)));
    }
  });
});

describe('the legal pages kept out of the sitemap', () => {
  test('are the drafts', () => {
    const f = folder({ 'a.md': page('final'), 'b.md': page('draft'), 'c.md': page(null), 'notes.txt': 'x' });
    expect(draftLegalPaths(f.url).sort()).toEqual(['/b', '/c']);
    f.done();
  });

  test('are all four when the folder is missing', () => {
    expect(draftLegalPaths(new URL('file:///nonexistent-legal-folder/')).sort()).toEqual(['/privacy', '/security', '/support', '/terms']);
  });

  test('a bad status is not taken for a missing folder', () => {
    const f = folder({ 'a.md': page('"Draft"') });
    expect(() => draftLegalPaths(f.url)).toThrow(/a\.md/);
    f.done();
  });
});

describe('the site build', () => {
  test('takes its sitemap list from the same check', async () => {
    const config = await read('../../astro.config.mjs');
    expect(config).toContain("draftLegalPaths(new URL('../docs/legal/', import.meta.url))");
    expect(config).not.toContain('readdirSync');
  });

  test('the content schema admits only the two statuses', async () => {
    expect(await read('../content.config.ts')).toContain("status: z.enum(LEGAL_STATUSES).default('draft')");
  });
});
