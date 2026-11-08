import { readdirSync, readFileSync } from 'node:fs';

export const LEGAL_STATUSES = ['draft', 'final'];

const ALL_LEGAL_PATHS = ['/privacy', '/terms', '/security', '/support'];

export function legalStatus(name, source) {
  const [, head = '', ...rest] = source.split(/^---$/m);
  const line = /^status:(.*)$/m.exec(head)?.[1];
  const status = line === undefined ? 'draft' : line.replace(/\s+#.*$/, '').trim().replace(/^(["'])(.*)\1$/, '$2');
  if (status !== 'draft' && status !== 'final') {
    throw new Error(`docs/legal/${name}: status must be "draft" or "final", not ${JSON.stringify(status)}`);
  }
  if (status === 'final' && rest.join('---').includes('[[OWNER:')) {
    throw new Error(`docs/legal/${name}: a final page cannot have an [[OWNER: ...]] note. Resolve the note, or set status to "draft".`);
  }
  return status;
}

export function draftLegalPaths(folder) {
  let files;
  try {
    files = readdirSync(folder);
  } catch {
    return [...ALL_LEGAL_PATHS];
  }
  return files
    .filter((f) => f.endsWith('.md') && legalStatus(f, readFileSync(new URL(f, folder), 'utf8')) === 'draft')
    .map((f) => `/${f.replace(/\.md$/, '')}`);
}
