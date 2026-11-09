import { describe, expect, test } from 'bun:test';
import { inviteCopy } from './invite-copy';

const read = (path: string) => Bun.file(new URL(path, import.meta.url)).text();

function page(answers: boolean[]) {
  const seen = { writes: 0, manual: 0, went: 0, held: 0 };
  const clipboard = inviteCopy(
    async () => {
      seen.writes++;
      if (!(answers.shift() ?? true)) throw new DOMException('Write permission denied', 'NotAllowedError');
    },
    () => seen.manual++,
  );
  const press = () => clipboard.leave({ preventDefault: () => seen.held++ }, () => seen.went++);
  return { seen, clipboard, press };
}

describe('leaving for TestFlight', () => {
  test('a copy that works goes on', async () => {
    const { seen, press } = page([true]);
    await press();
    expect(seen).toEqual({ writes: 1, manual: 0, went: 1, held: 1 });
  });

  test('a refused copy stays on the page and shows the field', async () => {
    const { seen, press } = page([false]);
    await press();
    expect(seen).toEqual({ writes: 1, manual: 1, went: 0, held: 1 });
  });

  test('the press after a refused copy is a plain link', async () => {
    const { seen, press } = page([false, false, false]);
    await press();
    await press();
    await press();
    expect(seen).toEqual({ writes: 1, manual: 1, went: 0, held: 1 });
  });

  test('a refused copy from the Copy button frees the links too', async () => {
    const { seen, clipboard, press } = page([false]);
    expect(await clipboard.copy()).toBe(false);
    await press();
    expect(seen).toEqual({ writes: 1, manual: 1, went: 0, held: 0 });
  });

  test('the Copy button can still try again after a refusal', async () => {
    const { seen, clipboard } = page([false, true]);
    expect(await clipboard.copy()).toBe(false);
    expect(await clipboard.copy()).toBe(true);
    expect(seen.writes).toBe(2);
  });

  test('repeat presses keep copying while the clipboard works', async () => {
    const { seen, press } = page([true, true]);
    await press();
    await press();
    expect(seen).toEqual({ writes: 2, manual: 0, went: 2, held: 2 });
  });
});

describe('the invite page', () => {
  test('leaves through the one place that knows the copy state', async () => {
    const source = await read('../pages/i.astro');
    expect(source).toContain('clipboard.leave(event');
    expect(source).toContain('clipboard.copy()');
    expect(source).not.toContain('navigator.clipboard.writeText(copied);\n');
    expect(source).not.toContain('event.preventDefault()');
  });

  test('stops offering to copy once the copy is by hand', async () => {
    const source = await read('../pages/i.astro');
    expect(source).toContain('if (go) go.textContent = goLabel;');
  });
});
