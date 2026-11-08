import { afterEach, beforeAll, beforeEach, describe, expect, test } from 'bun:test';

type Fn = (e: Record<string, unknown>) => void;

const g = globalThis as unknown as Record<string, unknown>;
const saved = Object.fromEntries(['document', 'window', 'matchMedia', 'getComputedStyle', 'DOMMatrixReadOnly', 'IntersectionObserver'].map((k) => [k, g[k]]));
const reduce = { matches: false };
let initReview: () => void;
let pageLoad: Fn[] = [];

class FakeAnimation {
  done = false;
  finished: Promise<void>;
  private resolve!: () => void;
  private reject!: (e: unknown) => void;
  constructor(private owner: FakeElement) {
    this.finished = new Promise((res, rej) => {
      this.resolve = res;
      this.reject = rej;
    });
    this.finished.catch(() => {});
  }
  finish() {
    if (this.done) return;
    this.done = true;
    this.owner.running = this.owner.running.filter((a) => a !== this);
    this.resolve();
  }
  cancel() {
    if (this.done) return;
    this.done = true;
    this.owner.running = this.owner.running.filter((a) => a !== this);
    this.reject(new DOMException('Aborted', 'AbortError'));
  }
}

class FakeElement {
  style: Record<string, string> = {};
  hidden = false;
  textContent = '';
  clientWidth = 320;
  running: FakeAnimation[] = [];
  parent: FakeElement | null = null;
  private attrs = new Set<string>();
  private handlers = new Map<string, Fn[]>();
  constructor(
    private tag: string,
    private classes: string[],
    public dataset: Record<string, string>,
    public children: FakeElement[] = [],
  ) {
    children.forEach((c) => (c.parent = this));
  }
  private matches(selector: string): boolean {
    return selector.match(/^[a-z]+|\.[\w-]+|\[[^\]]+\]/g)!.every((part) => {
      if (part[0] === '.') return this.classes.includes(part.slice(1));
      if (part[0] !== '[') return this.tag === part;
      const [, name, value] = /^\[data-([\w-]+)(?:="(.*)")?\]$/.exec(part)!;
      const key = name.replace(/-(\w)/g, (_, c: string) => c.toUpperCase());
      return value === undefined ? key in this.dataset : this.dataset[key] === value;
    });
  }
  querySelectorAll(selector: string): FakeElement[] {
    return this.children.flatMap((c) => [...(c.matches(selector) ? [c] : []), ...c.querySelectorAll(selector)]);
  }
  querySelector(selector: string): FakeElement | null {
    return this.querySelectorAll(selector)[0] ?? null;
  }
  closest(selector: string): FakeElement | null {
    return this.matches(selector) ? this : (this.parent?.closest(selector) ?? null);
  }
  addEventListener(type: string, fn: Fn) {
    this.handlers.set(type, [...(this.handlers.get(type) ?? []), fn]);
  }
  fire(type: string, event: Record<string, unknown> = {}) {
    const full = { target: this, preventDefault: () => {}, ...event };
    for (let at: FakeElement | null = this; at; at = at.parent) at.handlers.get(type)?.forEach((f) => f(full));
  }
  hasAttribute(name: string) {
    return this.attrs.has(name);
  }
  setAttribute(name: string) {
    this.attrs.add(name);
  }
  removeAttribute(name: string) {
    this.attrs.delete(name);
  }
  toggleAttribute(name: string, on: boolean) {
    if (on) this.attrs.add(name);
    else this.attrs.delete(name);
    return on;
  }
  animate() {
    const a = new FakeAnimation(this);
    this.running.push(a);
    return a;
  }
  getAnimations() {
    return [...this.running];
  }
  setPointerCapture() {}
  focus() {}
}

const el = (classes: string, dataset: Record<string, string> = {}, children: FakeElement[] = []) => new FakeElement('div', classes.split(' ').filter(Boolean), dataset, children);

const DIRS = ['need', 'want', 'save', 'transfer'];

function mount(count = 3) {
  const cards = Array.from({ length: count }, (_, i) =>
    el('rcard', { to: DIRS[i % 4] }, [...DIRS.map((d) => el(`rcard__tint rcard__tint--${d}`)), el('rcard__merchant'), el('rcard__use', { use: '' })]),
  );
  const done = el('deck__done', { reviewDone: '' });
  const deck = el('deck', {}, [...cards, done]);
  const undo = el('toast__undo', { undo: '' });
  const toast = el('toast', {}, [el('', { toastText: '' }), undo]);
  const live = el('', { reviewLive: '' });
  const restart = el('', { reviewRestart: '' });
  const pills = DIRS.map((d) => el(`rpill rpill--${d}`, { sort: d }));
  const stage = el('', { review: '', total: String(count + 1) }, [deck, toast, live, restart, ...pills]);
  const legends = DIRS.map((d) => el(`dir dir--${d}`, { sort: d }));
  const section = new FakeElement('section', [], {}, [stage, ...legends]);
  g.document = {
    hidden: false,
    querySelector: (s: string) => (s === '[data-review]' ? stage : null),
    addEventListener: (type: string, fn: Fn) => type === 'astro:page-load' && pageLoad.push(fn),
  };
  initReview();

  const position = { x: 0, y: 0 };
  const point = (id: number, time: number) => ({ pointerId: id, clientX: position.x, clientY: position.y, timeStamp: time, pointerType: 'mouse' });
  const held = { card: cards[0], time: 0 };
  return {
    cards,
    deck,
    toast,
    live,
    undo,
    restart,
    left: () => deck.dataset.left,
    legend: (d: string) => legends[DIRS.indexOf(d)],
    pill: (d: string) => pills[DIRS.indexOf(d)],
    key: (key: string) => deck.fire('keydown', { key }),
    grab(card: FakeElement) {
      held.card = card;
      position.x = position.y = 0;
      card.fire('pointerdown', point(1, (held.time += 400)));
    },
    move(x: number, y = 0) {
      position.x = x;
      position.y = y;
      held.card.fire('pointermove', point(1, (held.time += 400)));
    },
    release() {
      held.card.fire('pointerup', point(1, (held.time += 400)));
    },
  };
}

const tick = () => Bun.sleep(1);
async function until(ok: () => boolean) {
  const deadline = Date.now() + 1000;
  while (!ok()) {
    if (Date.now() > deadline) throw new Error('the deck did not settle');
    await Bun.sleep(2);
  }
}
const finishCard = async (card: FakeElement) => {
  card.getAnimations().forEach((a) => a.finish());
  await tick();
};

beforeAll(async () => {
  g.matchMedia = () => reduce;
  ({ initReview } = await import('./review'));
});

beforeEach(() => {
  reduce.matches = false;
  pageLoad = [];
  g.window = { setTimeout: () => 1, clearTimeout: () => {} };
  g.getComputedStyle = () => ({ transform: 'none' });
  g.DOMMatrixReadOnly = class {
    e = 0;
    f = 0;
  };
});

afterEach(() => {
  for (const [k, v] of Object.entries(saved)) g[k] = v;
});

describe('the legend chip', () => {
  test('stays lit until a dragged card has gone', async () => {
    const d = mount();
    d.grab(d.cards[0]);
    d.move(200);
    d.release();
    expect(d.legend('need').hasAttribute('data-active')).toBe(true);
    await finishCard(d.cards[0]);
    await until(() => d.left() === '2');
    expect(d.legend('need').hasAttribute('data-active')).toBe(false);
  });

  test('goes out after a committed drag with reduced motion', async () => {
    reduce.matches = true;
    const d = mount();
    d.grab(d.cards[0]);
    d.move(200);
    d.release();
    expect(d.legend('need').hasAttribute('data-active')).toBe(true);
    await finishCard(d.cards[0]);
    await until(() => d.left() === '2');
    expect(d.legend('need').hasAttribute('data-active')).toBe(false);
  });
});

type Deck = ReturnType<typeof mount>;
const SETTLE_MS = 300;
const sortByKey = async (d: Deck, card: FakeElement, key = 'ArrowRight') => {
  d.key(key);
  await finishCard(card);
  await finishCard(card);
  await Bun.sleep(SETTLE_MS);
};

describe('while a card is held', () => {
  const presses: [string, (d: Deck) => void][] = [
    ['an arrow key', (d) => d.key('ArrowRight')],
    ['a pill', (d) => d.pill('want').fire('click')],
    ['a legend chip', (d) => d.legend('want').fire('click')],
    ['Use', (d) => d.cards[0].querySelector('[data-use]')!.fire('click')],
  ];

  for (const [name, press] of presses) {
    test(`${name} does not start a sort`, () => {
      const d = mount();
      d.grab(d.cards[0]);
      d.move(30);
      press(d);
      expect(d.cards[0].getAnimations()).toEqual([]);
      expect(d.toast.hasAttribute('data-show')).toBe(false);
    });
  }

  test('a key press leaves the finger on the same card', async () => {
    const d = mount();
    d.grab(d.cards[0]);
    d.move(30);
    await sortByKey(d, d.cards[0]);
    d.move(60);
    expect(d.left()).toBe('3');
    expect(d.cards[0].style.transform).toContain('translate(60px');
    expect(d.cards[1].style.transform).toBe('');
  });

  test('a key press on the last card cannot break the drag', async () => {
    const d = mount(1);
    d.grab(d.cards[0]);
    d.move(30);
    await sortByKey(d, d.cards[0]);
    expect(() => d.move(60)).not.toThrow();
    expect(() => d.move(0)).not.toThrow();
    expect(() => d.release()).not.toThrow();
    expect(d.left()).toBe('1');
  });

  test('Undo leaves the held card where it is', async () => {
    const d = mount();
    await sortByKey(d, d.cards[0]);
    expect(d.left()).toBe('2');
    d.grab(d.cards[1]);
    d.move(30);
    d.undo.fire('click');
    expect(d.left()).toBe('2');
    d.move(60);
    expect(d.cards[1].style.transform).toContain('translate(60px');
    expect(d.cards[0].style.transform).toBe('');
  });

  test('a second finger is ignored', () => {
    const d = mount();
    d.grab(d.cards[0]);
    d.move(30);
    d.cards[0].fire('pointerdown', { pointerId: 2, clientX: 200, clientY: 0, timeStamp: 1 });
    d.cards[0].fire('pointermove', { pointerId: 2, clientX: 200, clientY: 0, timeStamp: 2 });
    d.cards[0].fire('pointerup', { pointerId: 2, clientX: 200, clientY: 0, timeStamp: 3 });
    expect(d.cards[0].style.transform).toContain('translate(30px');
    expect(d.cards[0].getAnimations()).toEqual([]);
  });

  test('the drag still commits once after an ignored press', async () => {
    const d = mount();
    d.grab(d.cards[0]);
    d.move(200);
    d.key('ArrowLeft');
    d.release();
    expect(d.cards[0].getAnimations().length).toBe(1);
    await finishCard(d.cards[0]);
    await until(() => d.left() === '2');
    expect(d.cards[0].style.transform).toBe('');
  });

  test('a short release puts the card back and the keys work again', async () => {
    const d = mount();
    d.grab(d.cards[0]);
    d.move(30);
    d.move(30);
    d.release();
    await Bun.sleep(1);
    d.cards[0].getAnimations().forEach((a) => a.cancel());
    await sortByKey(d, d.cards[0]);
    expect(d.left()).toBe('2');
  });
});

describe('the toast', () => {
  for (const [key, word] of [
    ['ArrowRight', 'Need'],
    ['ArrowLeft', 'Want'],
    ['ArrowDown', 'Save'],
    ['ArrowUp', 'Transfer'],
  ]) {
    test(`names ${word} and announces it`, async () => {
      const d = mount();
      d.key(key);
      await finishCard(d.cards[0]);
      expect(d.toast.querySelector('[data-toast-text]')!.textContent).toBe(`Sorted as ${word}`);
      expect(d.live.textContent).toBe(`Sorted as ${word}. Undo is available.`);
    });
  }
});

describe('while a card is leaving', () => {
  test('a press does not start another sort', async () => {
    const d = mount();
    d.key('ArrowRight');
    d.key('ArrowLeft');
    d.pill('save').fire('click');
    await finishCard(d.cards[0]);
    await finishCard(d.cards[0]);
    await Bun.sleep(SETTLE_MS);
    expect(d.left()).toBe('2');
  });

  test('a card cannot be grabbed', async () => {
    const d = mount();
    d.key('ArrowRight');
    d.grab(d.cards[0]);
    d.move(60);
    expect(d.cards[0].style.transform ?? '').toBe('');
  });

  test('Undo during a dragged card\'s flight puts it back once it has gone', async () => {
    const d = mount();
    d.grab(d.cards[0]);
    d.move(200);
    d.release();
    expect(d.toast.hasAttribute('data-show')).toBe(true);
    d.undo.fire('click');
    await finishCard(d.cards[0]);
    await Bun.sleep(SETTLE_MS);
    expect(d.left()).toBe('3');
    expect(d.cards[0].dataset.pos).toBe('0');
    expect(d.toast.hasAttribute('data-show')).toBe(false);
    expect(d.live.textContent).toBe('Undone.');
  });

  test('Undo during a pressed card\'s flight puts it back once it has gone', async () => {
    const d = mount();
    d.key('ArrowRight');
    await finishCard(d.cards[0]);
    expect(d.toast.hasAttribute('data-show')).toBe(true);
    d.undo.fire('click');
    await finishCard(d.cards[0]);
    await Bun.sleep(SETTLE_MS);
    expect(d.left()).toBe('3');
    expect(d.cards[0].dataset.pos).toBe('0');
  });

  test('Undo during the fade with reduced motion puts the card back', async () => {
    reduce.matches = true;
    const d = mount();
    d.key('ArrowRight');
    d.undo.fire('click');
    await finishCard(d.cards[0]);
    await tick();
    expect(d.left()).toBe('3');
    expect(d.live.textContent).toBe('Undone.');
  });

  test('one Undo takes back one card, and the next sort stays sorted', async () => {
    const d = mount();
    d.key('ArrowRight');
    await finishCard(d.cards[0]);
    d.undo.fire('click');
    d.undo.fire('click');
    await finishCard(d.cards[0]);
    await Bun.sleep(SETTLE_MS);
    expect(d.left()).toBe('3');
    await sortByKey(d, d.cards[0], 'ArrowLeft');
    expect(d.left()).toBe('2');
  });

  test('Undo after the card has gone still works', async () => {
    const d = mount();
    await sortByKey(d, d.cards[0]);
    d.undo.fire('click');
    expect(d.left()).toBe('3');
  });

  test('Undo with nothing sorted does nothing', () => {
    const d = mount();
    d.undo.fire('click');
    expect(d.left()).toBe('3');
    expect(d.live.textContent).toBe('');
  });
});

describe('Start again', () => {
  test('goes back to the first card with the toast gone', async () => {
    const d = mount(1);
    await sortByKey(d, d.cards[0]);
    expect(d.left()).toBe('0');
    d.restart.fire('click');
    expect(d.left()).toBe('1');
    expect(d.cards[0].dataset.pos).toBe('0');
    expect(d.toast.hasAttribute('data-show')).toBe(false);
    expect(d.live.textContent).toStartWith('Back to the first card');
  });
});

describe('the demo', () => {
  test('hands the card over when it is grabbed mid-lean', async () => {
    let seen: (entries: { isIntersecting: boolean }[]) => void = () => {};
    class Observer {
      constructor(cb: typeof seen) {
        seen = cb;
      }
      observe() {}
      disconnect() {}
    }
    g.IntersectionObserver = Observer;
    g.window = {
      IntersectionObserver: Observer,
      setTimeout: (f: () => void, ms: number) => (ms === 300 && f(), 1),
      clearTimeout: () => {},
    };
    const d = mount();
    seen([{ isIntersecting: true }]);
    await until(() => d.cards[0].getAnimations().length > 0);
    d.grab(d.cards[0]);
    await tick();
    expect(d.cards[0].getAnimations()).toEqual([]);
    d.move(30);
    expect(d.cards[0].style.transform).toContain('translate(30px');
    d.move(0);
    d.release();
    await sortByKey(d, d.cards[0]);
    expect(d.left()).toBe('2');
  });
});
