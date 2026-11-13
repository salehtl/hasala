import { afterEach, describe, expect, test } from 'bun:test';
import { anchorNote } from './anchor-note';

const g = globalThis as unknown as Record<string, unknown>;
const savedWindow = g.window;
afterEach(() => {
  g.window = savedWindow;
});

const works = async () => {};
const refused = () => Promise.reject(new DOMException('Write permission denied', 'NotAllowedError'));

function button() {
  const timers = new Map<number, () => void>();
  let next = 1;
  g.window = {
    setTimeout: (fn: () => void) => {
      timers.set(next, fn);
      return next++;
    },
    clearTimeout: (id: number) => timers.delete(id),
  };
  const note = { textContent: '' as string | null };
  const page = new AbortController();
  const press = anchorNote(note, 'data', page.signal);
  const runTimers = () => [...timers.values()].forEach((fn) => fn());
  return { note, page, press, timers, runTimers };
}

describe('the note beside a legal heading', () => {
  test('says the link was copied, then empties', async () => {
    const b = button();
    await b.press(works);
    expect(b.note.textContent).toBe('#data · link copied');
    b.runTimers();
    expect(b.note.textContent).toBe('');
  });

  test('names the heading when the copy is refused, then empties', async () => {
    const b = button();
    await b.press(refused);
    expect(b.note.textContent).toBe('#data');
    b.runTimers();
    expect(b.note.textContent).toBe('');
  });

  test('a second press drops the first press timer, so the note stays its full time', async () => {
    const b = button();
    await b.press(works);
    const [first] = [...b.timers.keys()];
    await b.press(works);
    expect(b.timers.has(first)).toBe(false);
    expect(b.timers.size).toBe(1);
    expect(b.note.textContent).toBe('#data · link copied');
  });

  test('two presses waiting on the clipboard leave one timer', async () => {
    const b = button();
    await Promise.all([b.press(works), b.press(works)]);
    expect(b.timers.size).toBe(1);
  });

  test('a refused press after a copy that worked leaves one timer', async () => {
    const b = button();
    await b.press(works);
    await b.press(refused);
    expect(b.timers.size).toBe(1);
    expect(b.note.textContent).toBe('#data');
  });

  test('a page swap drops the waiting timer', async () => {
    const b = button();
    await b.press(works);
    b.page.abort();
    expect(b.timers.size).toBe(0);
  });
});

describe('the legal page', () => {
  test('keeps the heading note timer in the one place that clears it', async () => {
    const source = await Bun.file(new URL('../pages/[doc].astro', import.meta.url)).text();
    expect(source).toContain("from '../scripts/anchor-note'");
    expect(source).toContain('anchorNote(');
    expect(source).not.toContain('setTimeout(');
  });
});
