import { describe, expect, test } from 'bun:test';
import { arriveAtLink, markLinkDone } from './link-page';

const token = 'A'.repeat(43);
const router = { index: 3, scrollX: 0, scrollY: 40 };
const read = (path: string) => Bun.file(new URL(path, import.meta.url)).text();

function tab(hash: string, state: Record<string, unknown> | null = router) {
  const place = { hash };
  const hist = {
    state,
    url: `/freeze${hash}`,
    replaceState(next: unknown, _title: string, url?: string | URL | null) {
      hist.state = next as Record<string, unknown> | null;
      if (url) hist.url = String(url);
      if (url) place.hash = '';
    },
  };
  return { place, hist };
}

const arrive = (page: 'freeze' | 'confirm' | 'leave', t: ReturnType<typeof tab>) => arriveAtLink(page, '/freeze', t.place, t.hist as unknown as History);
const reload = (t: ReturnType<typeof tab>, page: 'freeze' | 'confirm' | 'leave' = 'freeze') => arrive(page, t);

describe('arriving at a link page', () => {
  test('a whole token asks, and leaves the address bar', () => {
    const t = tab(`#${token}`);
    expect(arrive('freeze', t)).toEqual({ step: 'ask', token });
    expect(t.hist.url).toBe('/freeze');
    expect(t.hist.state).toEqual(router);
  });

  for (const hash of ['', '#', '#short', `#${token}A`, `#${'!'.repeat(43)}`]) {
    test(`the address ${JSON.stringify(hash.slice(0, 8))} is incomplete and leaves the address bar`, () => {
      const t = tab(hash);
      expect(arrive('freeze', t)).toEqual({ step: 'incomplete' });
      expect(t.hist.url).toBe('/freeze');
    });
  }

  test('a history entry with no state keeps none', () => {
    const t = tab('', null);
    expect(arrive('confirm', t)).toEqual({ step: 'incomplete' });
    expect(t.hist.state).toBeNull();
  });
});

describe('a finished link', () => {
  for (const page of ['freeze', 'confirm', 'leave'] as const) {
    test(`${page} is still done after a reload`, () => {
      const t = tab(`#${token}`);
      arrive(page, t);
      markLinkDone(page, t.hist as unknown as History);
      expect(reload(t, page)).toEqual({ step: 'done' });
      expect(reload(t, page)).toEqual({ step: 'done' });
    });
  }

  test('keeps the state the router needs and never the token', () => {
    const t = tab(`#${token}`);
    arrive('confirm', t);
    markLinkDone('confirm', t.hist as unknown as History);
    expect(t.hist.state).toMatchObject(router);
    expect(JSON.stringify(t.hist.state)).not.toContain(token);
  });

  test('a link that failed is not done after a reload', () => {
    const t = tab(`#${token}`);
    arrive('freeze', t);
    expect(reload(t)).toEqual({ step: 'incomplete' });
  });

  test('does not carry to another kind of link', () => {
    const t = tab(`#${token}`);
    arrive('confirm', t);
    markLinkDone('confirm', t.hist as unknown as History);
    expect(reload(t, 'leave')).toEqual({ step: 'incomplete' });
  });

  test('gives way to a new token, and the new one starts unfinished', () => {
    const t = tab(`#${token}`);
    arrive('confirm', t);
    markLinkDone('confirm', t.hist as unknown as History);
    const other = 'B'.repeat(43);
    t.place.hash = `#${other}`;
    expect(arrive('confirm', t)).toEqual({ step: 'ask', token: other });
    expect(t.hist.state).toEqual(router);
    expect(reload(t, 'confirm')).toEqual({ step: 'incomplete' });
  });

  test('does not answer for a broken link opened in the same tab', () => {
    const t = tab(`#${token}`);
    arrive('confirm', t);
    markLinkDone('confirm', t.hist as unknown as History);
    t.place.hash = '#short';
    expect(arrive('confirm', t)).toEqual({ step: 'incomplete' });
  });
});

describe('the link pages', () => {
  test('/freeze reads the link once and records a finished freeze', async () => {
    const source = await read('../pages/freeze.astro');
    expect(source).toContain("arriveAtLink('freeze', '/freeze')");
    expect(source).toContain("markLinkDone('freeze')");
    expect(source).not.toContain('location.hash.slice(1)');
  });

  test('the waitlist links read the link once and record a finished press', async () => {
    const source = await read('../components/WaitlistLink.astro');
    expect(source).toContain('arriveAtLink(kind, location.pathname)');
    expect(source).toContain('markLinkDone(kind)');
    expect(source).not.toContain('location.hash.slice(1)');
  });
});
