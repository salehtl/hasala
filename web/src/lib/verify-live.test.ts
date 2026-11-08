import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../../scripts/verify-live.sh', import.meta.url));
const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function run(curl: string) {
  const dir = mkdtempSync(join(tmpdir(), 'verify-live-'));
  dirs.push(dir);
  writeFileSync(join(dir, 'curl'), `#!/bin/sh\n${curl}\n`);
  chmodSync(join(dir, 'curl'), 0o755);
  return spawnSync('bash', [script, 'https://site.test'], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
  });
}

const CHECKED = ['/:', '/privacy:', '/privacy/:', '/testflight:', '/i/test:', '/freeze:', '/waitlist/confirm:', '/.well-known/apple-app-site-association:', '/no-such-page:'];

describe('verify-live.sh', () => {
  test('with no network it names every check and exits non-zero', () => {
    const r = run('echo "curl: (7) could not connect" >&2\nexit 7');
    expect(r.status).toBe(1);
    for (const name of CHECKED) expect(r.stderr).toContain(`FAIL ${name}`);
    expect(r.stderr).toContain('live checks failed for https://site.test');
  });

  test('a request that fails does not stop the checks after it', () => {
    const r = run('for a in "$@"; do last="$a"; done\ncase "$last" in\n  */no-such-page) printf "HTTP/2 404\\r\\n\\r\\n" ;;\n  *) exit 7 ;;\nesac');
    expect(r.status).toBe(1);
    expect(r.stderr).toContain('FAIL /: status none, want 200');
    expect(r.stdout).toContain('ok   /no-such-page: 404');
  });
});
