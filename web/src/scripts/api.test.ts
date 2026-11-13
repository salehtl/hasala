import { afterEach, beforeEach, describe, expect, test } from 'bun:test';

type Api = typeof import('./api');
type FakeScript = { dataset: Record<string, string>; src?: string; removed?: boolean; onerror?: () => void; remove: () => void };
type Callbacks = { callback: (t: string) => void; 'expired-callback': () => void };

const g = globalThis as unknown as Record<string, unknown>;
const saved = { window: g.window, document: g.document, fetch: g.fetch };
afterEach(() => {
  g.window = saved.window;
  g.document = saved.document;
  g.fetch = saved.fetch;
});

let fresh = 0;
const loadApi = async () => (await import(`./api.ts?turnstile=${fresh++}`)) as Api;

function fakeTurnstile() {
  const t = {
    opts: undefined as unknown as Callbacks,
    renders: 0,
    resets: [] as string[],
    removes: [] as string[],
    render(el: { childElementCount: number }, opts: Callbacks) {
      el.childElementCount = 1;
      t.opts = opts;
      t.renders++;
      return `widget-${t.renders}`;
    },
    reset: (id: string) => t.resets.push(id),
    remove: (id: string) => t.removes.push(id),
  };
  return t;
}

function page(turnstile?: ReturnType<typeof fakeTurnstile>) {
  const scripts: FakeScript[] = [];
  const win: Record<string, unknown> = { turnstile };
  g.window = win;
  g.document = {
    createElement: () => {
      const s: FakeScript = { dataset: {}, remove: () => (s.removed = true) };
      return s;
    },
    head: { append: (s: FakeScript) => scripts.push(s) },
    addEventListener: () => {},
  };
  const form = { querySelector: () => ({ dataset: { sitekey: 'synthetic-site-key' }, childElementCount: 0 }) } as unknown as HTMLFormElement;
  return { scripts, win, form };
}

const PENDING = 'pending';
const state = <T>(p: Promise<T>) => Promise.race([p, new Promise<typeof PENDING>((r) => setTimeout(() => r(PENDING), 5))]);

describe('renderTurnstile', () => {
  test('a form with no widget needs no token', async () => {
    const { renderTurnstile } = await loadApi();
    page();
    const form = { querySelector: () => null } as unknown as HTMLFormElement;
    const gate = renderTurnstile(form, 'waitlist', new AbortController().signal);
    expect(await gate.check()).toEqual({ state: 'off' });
    gate.reset();
  });

  test('a submit before the token waits for it', async () => {
    const { renderTurnstile } = await loadApi();
    const t = fakeTurnstile();
    const gate = renderTurnstile(page(t).form, 'waitlist', new AbortController().signal);
    const check = gate.check();
    expect(await state(check)).toBe(PENDING);
    t.opts.callback('token-1');
    expect(await check).toEqual({ state: 'ready', token: 'token-1' });
  });

  test('a retry right after a reset waits for a new token', async () => {
    const { renderTurnstile } = await loadApi();
    const t = fakeTurnstile();
    const gate = renderTurnstile(page(t).form, 'waitlist', new AbortController().signal);
    t.opts.callback('token-1');
    expect(await gate.check()).toEqual({ state: 'ready', token: 'token-1' });
    gate.reset();
    expect(t.resets).toEqual(['widget-1']);
    const retry = gate.check();
    expect(await state(retry)).toBe(PENDING);
    t.opts.callback('token-2');
    expect(await retry).toEqual({ state: 'ready', token: 'token-2' });
  });

  test('an expired token is not offered', async () => {
    const { renderTurnstile } = await loadApi();
    const t = fakeTurnstile();
    const gate = renderTurnstile(page(t).form, 'waitlist', new AbortController().signal);
    t.opts.callback('token-1');
    t.opts['expired-callback']();
    expect(await state(gate.check())).toBe(PENDING);
  });

  test('no token in time is reported as missing', async () => {
    const { renderTurnstile } = await loadApi();
    const gate = renderTurnstile(page(fakeTurnstile()).form, 'waitlist', new AbortController().signal, 1);
    expect(await gate.check()).toEqual({ state: 'missing' });
  });

  test('a script that cannot load is missing at once, and the next check loads it again', async () => {
    const { renderTurnstile } = await loadApi();
    const { scripts, win, form } = page();
    const gate = renderTurnstile(form, 'waitlist', new AbortController().signal);
    expect(scripts.length).toBe(1);
    const first = gate.check();
    expect(await state(first)).toBe(PENDING);
    scripts[0].onerror!();
    expect(await first).toEqual({ state: 'missing' });
    expect(scripts[0].removed).toBe(true);

    const second = gate.check();
    expect(scripts.length).toBe(2);
    const t = fakeTurnstile();
    win.turnstile = t;
    (win.hasalaTurnstileReady as () => void)();
    expect(t.renders).toBe(1);
    t.opts.callback('token-1');
    expect(await second).toEqual({ state: 'ready', token: 'token-1' });
  });

  test('a page swap removes the widget once and a late reset does not touch it', async () => {
    const { renderTurnstile } = await loadApi();
    const t = fakeTurnstile();
    const ctrl = new AbortController();
    const gate = renderTurnstile(page(t).form, 'waitlist', ctrl.signal);
    const pending = gate.check();
    ctrl.abort();
    expect(t.removes).toEqual(['widget-1']);
    expect(await pending).toEqual({ state: 'missing' });
    gate.reset();
    expect(t.resets).toEqual([]);
    expect(await gate.check()).toEqual({ state: 'missing' });
  });
});

describe('postJson', () => {
  const URL = 'https://api.example/api/v1/waitlist/confirm';
  const realTimeout = AbortSignal.timeout;
  let waited = 0;
  let expire = () => {};
  const noAnswer = (signal?: AbortSignal | null) =>
    new Promise<never>((_resolve, reject) => {
      signal?.addEventListener('abort', () => reject(signal.reason));
    });

  beforeEach(() => {
    const stop = new AbortController();
    waited = 0;
    expire = () => stop.abort(new DOMException('The operation timed out.', 'TimeoutError'));
    AbortSignal.timeout = (ms: number) => {
      waited = ms;
      return stop.signal;
    };
  });
  afterEach(() => {
    AbortSignal.timeout = realTimeout;
  });

  test('a request that gets no answer stops waiting and reads as a network failure', async () => {
    const { postJson } = await loadApi();
    g.fetch = ((_u: string, i: RequestInit) => noAnswer(i.signal)) as unknown as typeof fetch;
    const answer = postJson(URL, { token: 't' });
    expect(await state(answer)).toBe(PENDING);
    expire();
    expect(await state(answer)).toEqual({ status: 0, error: 'network', data: {}, retryAfter: 0 });
  });

  test('it waits for 20 seconds', async () => {
    const { postJson } = await loadApi();
    g.fetch = (async () => new Response('{}', { status: 200 })) as unknown as typeof fetch;
    await postJson(URL, { token: 't' });
    expect(waited).toBe(20_000);
  });

  test('an answer whose body never ends still counts by its status', async () => {
    const { postJson } = await loadApi();
    g.fetch = (async (_u: string, i: RequestInit) => ({ status: 200, headers: new Headers(), json: () => noAnswer(i.signal) })) as unknown as typeof fetch;
    const answer = postJson(URL, { token: 't' });
    await Bun.sleep(1);
    expire();
    expect(await state(answer)).toEqual({ status: 200, error: '', data: {}, retryAfter: 0 });
  });

  test('an answer inside the wait counts', async () => {
    const { postJson } = await loadApi();
    g.fetch = (async () => new Response('{"status":"confirmed"}', { status: 200 })) as unknown as typeof fetch;
    expect(await postJson(URL, { token: 't' })).toEqual({ status: 200, error: '', data: { status: 'confirmed' }, retryAfter: 0 });
  });

  test('a network failure inside the wait reads the same', async () => {
    const { postJson } = await loadApi();
    g.fetch = (async () => {
      throw new TypeError('failed to fetch');
    }) as unknown as typeof fetch;
    expect((await postJson(URL, { token: 't' })).status).toBe(0);
  });

  test('a browser with no timed signal still sends the request', async () => {
    const { postJson } = await loadApi();
    (AbortSignal as unknown as Record<string, unknown>).timeout = undefined;
    g.fetch = (async () => new Response('{}', { status: 200 })) as unknown as typeof fetch;
    expect((await postJson(URL, { token: 't' })).status).toBe(200);
  });
});

describe('postWithTurnstile', () => {
  const answering = (sent: unknown[]) =>
    (async (_url: string, init: RequestInit) => {
      sent.push(JSON.parse(String(init.body)));
      return new Response('{}', { status: 202 });
    }) as unknown as typeof fetch;

  test('with no token nothing is sent, and the answer is the refusal the form already shows', async () => {
    const { postWithTurnstile } = await loadApi();
    const sent: unknown[] = [];
    g.fetch = answering(sent);
    const answer = await postWithTurnstile('https://api.example/api/v1/waitlist', { email: 'a@example.com' }, { check: async () => ({ state: 'missing' }), reset: () => {} });
    expect(sent).toEqual([]);
    expect(answer).toEqual({ status: 403, error: 'turnstile_failed', data: {}, retryAfter: 0 });
  });

  test('a token travels with the body', async () => {
    const { postWithTurnstile } = await loadApi();
    const sent: unknown[] = [];
    g.fetch = answering(sent);
    await postWithTurnstile('https://api.example/api/v1/waitlist', { email: 'a@example.com' }, { check: async () => ({ state: 'ready', token: 'token-1' }), reset: () => {} });
    expect(sent).toEqual([{ email: 'a@example.com', turnstileToken: 'token-1' }]);
  });

  test('a form with no widget sends no token field', async () => {
    const { postWithTurnstile } = await loadApi();
    const sent: unknown[] = [];
    g.fetch = answering(sent);
    await postWithTurnstile('https://api.example/api/v1/waitlist', { email: 'a@example.com' }, { check: async () => ({ state: 'off' }), reset: () => {} });
    expect(sent).toEqual([{ email: 'a@example.com' }]);
  });
});
