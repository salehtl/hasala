import { describe, expect, test } from 'bun:test';

const read = (path: string) => Bun.file(new URL(path, import.meta.url)).text();

describe('the message for a page whose script never ran', () => {
  for (const [name, path] of [
    ['/freeze', '../pages/freeze.astro'],
    ['/waitlist links', '../components/WaitlistLink.astro'],
  ]) {
    test(`${name} shows it in the page, not in a noscript element`, async () => {
      const source = await read(path);
      expect(source).not.toContain('<noscript');
      expect(source).toMatch(/<p [^>]*data-no-script[^>]*>[^<]*This page needs JavaScript/);
    });
  }

  test('a running script hides it', async () => {
    expect(await read('../styles/global.css')).toMatch(/\.js \[data-no-script\]\s*\{\s*display: none;/);
  });
});
