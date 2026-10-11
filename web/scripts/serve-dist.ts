/**
 * Serves the built site (dist/) on 127.0.0.1 roughly the way Workers Static
 * Assets does in production (wrangler.jsonc), so Lighthouse measures what
 * visitors get: drop-trailing-slash HTML (/privacy -> privacy.html), the
 * 200 rewrites in _redirects, the headers in _headers (including "! Name"
 * detach lines), 404.html for anything else, and gzip for text responses.
 * For local checks and CI only; it is not the production server.
 *
 *   bun scripts/serve-dist.ts [dist] [--port 4321]      (Node runs it too)
 */
import { existsSync, readFileSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize } from 'node:path';
import { gzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const portAt = args.indexOf('--port');
const port = portAt === -1 ? 4321 : Number(args.splice(portAt, 2)[1]);
const root = args[0] ?? fileURLToPath(new URL('../dist', import.meta.url));

const glob = (pattern: string) => new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*')}$`);

type Rule = { match: RegExp; detach: string[]; set: [string, string][] };
const rules: Rule[] = [];
for (const line of readFileSync(join(root, '_headers'), 'utf8').split('\n')) {
  if (!line.trim() || line.trim().startsWith('#')) continue;
  if (!/^\s/.test(line)) {
    rules.push({ match: glob(line.trim()), detach: [], set: [] });
    continue;
  }
  const rule = rules.at(-1)!;
  const t = line.trim();
  if (t.startsWith('!')) rule.detach.push(t.slice(1).trim());
  else rule.set.push([t.slice(0, t.indexOf(':')).trim(), t.slice(t.indexOf(':') + 1).trim()]);
}

const rewrites = readFileSync(join(root, '_redirects'), 'utf8')
  .split('\n')
  .filter((l) => l.trim() && !l.trim().startsWith('#'))
  .map((l) => l.trim().split(/\s+/))
  .filter(([, , code]) => code === '200')
  .map(([from, to]) => [glob(from), to] as const);

const isFile = (p: string) => existsSync(p) && statSync(p).isFile();
function resolve(path: string): string | null {
  const p = normalize(join(root, path));
  if (!p.startsWith(normalize(root))) return null;
  if (path === '/') return join(root, 'index.html');
  for (const c of [p, `${p}.html`, join(p, 'index.html')]) if (isFile(c)) return c;
  return null;
}

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.webmanifest': 'application/manifest+json',
  '.xml': 'application/xml',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.avif': 'image/avif',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
};
const TEXT = /^(text\/|application\/(json|xml|manifest\+json)|image\/svg\+xml)/;

createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`);
  let path: string;
  try {
    path = decodeURIComponent(url.pathname);
  } catch {
    res.writeHead(400).end();
    return;
  }
  if (path.length > 1 && path.endsWith('/')) {
    res.writeHead(307, { location: `${path.slice(0, -1)}${url.search}` }).end();
    return;
  }
  for (const [from, to] of rewrites) if (from.test(path)) path = to;
  let file = resolve(path);
  let status = 200;
  if (!file) {
    file = join(root, '404.html');
    status = 404;
  }
  const headers = new Headers({ 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' });
  for (const rule of rules) {
    if (!rule.match.test(url.pathname)) continue;
    for (const name of rule.detach) headers.delete(name);
    // Repeated names are joined, as Cloudflare does; Content-Type replaces the inferred one.
    for (const [name, value] of rule.set) headers[/^content-type$/i.test(name) ? 'set' : 'append'](name, value);
  }
  let body = readFileSync(file);
  if (TEXT.test(headers.get('content-type') ?? '') && /\bgzip\b/.test(req.headers['accept-encoding'] ?? '')) {
    body = gzipSync(body);
    headers.set('content-encoding', 'gzip');
    headers.set('vary', 'accept-encoding');
  }
  res.writeHead(status, Object.fromEntries(headers)).end(req.method === 'HEAD' ? undefined : body);
}).listen(port, '127.0.0.1', () => console.log(`serving ${root} on http://127.0.0.1:${port}/`));
