import { afterEach, describe, expect, test } from 'bun:test';
import { initWaitlist } from './waitlist';

type Handler = (e: Record<string, unknown>) => unknown;

const g = globalThis as unknown as Record<string, unknown>;
const saved = Object.fromEntries(['window', 'document', 'history', 'location', 'fetch', 'requestAnimationFrame'].map((k) => [k, g[k]]));
afterEach(() => {
  for (const [k, v] of Object.entries(saved)) g[k] = v;
});

class El {
  hidden = false;
  disabled = false;
  readOnly = false;
  noValidate = false;
  value = '';
  textContent = '';
  offsetWidth = 200;
  focused = 0;
  style: Record<string, string> = {};
  dataset: Record<string, string> = {};
  elements = { namedItem: (_: string): unknown => null };
  activeElement: unknown = null;
  private attrs = new Map<string, string>();
  private listeners = new Map<string, { fn: Handler; signal?: AbortSignal }[]>();
  private parts = new Map<string, unknown>();
  private lists = new Map<string, unknown[]>();

  with(selector: string, part: unknown) {
    this.parts.set(selector, part);
    return this;
  }
  withAll(selector: string, parts: unknown[]) {
    this.lists.set(selector, parts);
    return this;
  }
  querySelector(selector: string) {
    return this.parts.get(selector) ?? null;
  }
  querySelectorAll(selector: string) {
    return this.lists.get(selector) ?? [];
  }
  getElementById() {
    return new El();
  }
  createElement() {
    return new El();
  }
  addEventListener(type: string, fn: Handler, opts?: { signal?: AbortSignal }) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), { fn, signal: opts?.signal }]);
  }
  fire(type: string, e: Record<string, unknown> = {}) {
    const live = (this.listeners.get(type) ?? []).filter((l) => !l.signal?.aborted);
    return Promise.all(live.map((l) => l.fn({ preventDefault: () => {}, ...e })));
  }
  setAttribute(name: string, value: string) {
    this.attrs.set(name, value);
  }
  removeAttribute(name: string) {
    this.attrs.delete(name);
  }
  getAttribute(name: string) {
    return this.attrs.get(name) ?? null;
  }
  toggleAttribute(name: string, on: boolean) {
    if (on) this.attrs.set(name, '');
    else this.attrs.delete(name);
  }
  focus() {
    this.focused++;
  }
  scrollIntoView() {}
  contains() {
    return false;
  }
  append() {}
  requestSubmit() {}
}

function field() {
  return new El().with('.field__error', new El().with('span', new El()));
}

function start(arrival: { hash?: string; bank?: string } = {}) {
  const email = new El();
  const bank = new El();
  const other = new El();
  const honeypot = new El();
  bank.value = arrival.bank ?? '';
  const otherField = field();
  otherField.hidden = true;
  const status = new El();
  const label = new El();
  const submit = new El().with('.wl-submit__label', label).with('.spinner', new El());
  const named: Record<string, El> = { 'wl-email': email, 'wl-bank': bank, 'wl-other': other, 'wl-website': honeypot };
  const form = new El()
    .with('[data-field="email"]', field())
    .with('[data-field="bank"]', field())
    .with('[data-field="other"]', otherField)
    .with('.wl-submit', submit)
    .with('.wl-status', status);
  form.elements = { namedItem: (name: string) => named[name] };
  const done = new El().with('[data-done-bank]', new El()).with('#wl-done-title', new El());
  done.hidden = true;
  const root = new El().with('[data-waitlist-form]', form).with('.wl-done', done);
  root.dataset = { state: 'default', api: 'https://api.test' };
  const cta = new El();
  const copyText = new El();
  copyText.textContent = 'Copy link for a friend';
  const copy = new El().with('span', copyText);
  copy.dataset = { copy: 'https://hasala.test/#invite' };
  const document = new El()
    .with('[data-waitlist]', root)
    .withAll('[data-copy]', [copy])
    .withAll('a[href="#invite"], a[href="/#invite"]', [cta]);
  const timers = new Map<number, () => void>();
  let nextTimer = 1;
  const replaced: string[] = [];
  const location = { hash: arrival.hash ?? '', href: '' };
  g.document = document;
  g.location = location;
  g.history = {
    state: null,
    replaceState: (_: unknown, __: string, url: string) => {
      replaced.push(url);
      location.hash = url;
    },
  };
  g.requestAnimationFrame = () => 0;
  g.window = {
    location,
    setTimeout: (fn: () => void) => {
      timers.set(nextTimer, fn);
      return nextTimer++;
    },
    clearTimeout: (id: number) => timers.delete(id),
  };
  initWaitlist();
  const runTimers = () => [...timers.values()].forEach((fn) => fn());
  const send = () => {
    email.value = 'person@example.test';
    bank.value = 'dib';
    return form.fire('submit');
  };
  return { document, root, form, done, email, bank, other, otherField, status, submit, cta, copy, copyText, timers, runTimers, replaced, location, send };
}

function holdFetch() {
  let answer: (r: Response) => void = () => {};
  g.fetch = () => new Promise<Response>((resolve) => (answer = resolve));
  return (status: number, body = '{}') => answer(new Response(body, { status }));
}

const tick = () => Bun.sleep(1);

describe('work that ends with the page', () => {
  test('pressing a request button twice leaves one focus waiting', () => {
    const p = start();
    p.cta.fire('click');
    p.cta.fire('click');
    expect(p.timers.size).toBe(1);
    p.runTimers();
    expect(p.email.focused).toBe(1);
  });

  test('a page swap drops the focus a press left waiting', () => {
    const p = start();
    p.cta.fire('click');
    p.document.fire('astro:before-swap');
    expect(p.timers.size).toBe(0);
  });

  test('a page swap drops the focus an arrival left waiting', () => {
    const p = start({ hash: '#invite' });
    expect(p.timers.size).toBe(1);
    p.document.fire('astro:before-swap');
    expect(p.timers.size).toBe(0);
  });

  test('pressing copy twice leaves one restore waiting, and the label comes back', async () => {
    const p = start();
    await p.copy.fire('click');
    await p.copy.fire('click');
    expect(p.timers.size).toBe(1);
    p.runTimers();
    expect(p.copyText.textContent).toBe('Copy link for a friend');
  });

  test('a page swap drops the copy restore', async () => {
    const p = start();
    await p.copy.fire('click');
    p.document.fire('astro:before-swap');
    expect(p.timers.size).toBe(0);
  });

  test('a page swap during a send drops the still-trying note', async () => {
    const p = start();
    holdFetch();
    p.send();
    await tick();
    expect(p.timers.size).toBe(1);
    p.document.fire('astro:before-swap');
    expect(p.timers.size).toBe(0);
  });

  test('an accepted answer after a page swap leaves the old form alone', async () => {
    const p = start();
    const reply = holdFetch();
    const sending = p.send();
    await tick();
    p.document.fire('astro:before-swap');
    reply(202);
    await sending;
    expect(p.done.hidden).toBe(true);
    expect(p.form.hidden).toBe(false);
    expect(p.root.dataset.state).toBe('default');
  });

  test('a refused answer after a page swap leaves the old form alone', async () => {
    const p = start();
    const reply = holdFetch();
    const sending = p.send();
    await tick();
    p.document.fire('astro:before-swap');
    reply(400, '{"error":"bad_email"}');
    await sending;
    expect(p.root.dataset.state).toBe('default');
    expect(p.email.getAttribute('aria-invalid')).toBeNull();
  });

  test('an accepted answer on the same page shows the done card and clears the note', async () => {
    const p = start();
    const reply = holdFetch();
    const sending = p.send();
    await tick();
    reply(202);
    await sending;
    expect(p.done.hidden).toBe(false);
    expect(p.form.hidden).toBe(true);
    expect(p.root.dataset.state).toBe('success');
    expect(p.timers.size).toBe(0);
  });
});

describe('the invite hash', () => {
  test('a press on a request button leaves no hash for a later reload', () => {
    const p = start();
    p.cta.fire('click');
    expect(p.replaced).toEqual([]);
    expect(p.location.hash).toBe('');
    p.runTimers();
    expect(p.email.focused).toBe(1);
    const reloaded = start({ hash: p.location.hash });
    expect(reloaded.timers.size).toBe(0);
  });

  test('a link that arrives with the hash still focuses Email', () => {
    const p = start({ hash: '#invite' });
    p.runTimers();
    expect(p.email.focused).toBe(1);
  });
});
