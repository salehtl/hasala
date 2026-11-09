import { afterAll, beforeAll, describe, expect, test } from 'bun:test';

const realDocument = globalThis.document;
const handlers = new Map<string, ((e: unknown) => void)[]>();
const root = new Set<string>(['js']);
const classList = (set: Set<string>) => ({
  add: (...c: string[]) => c.forEach((x) => set.add(x)),
  remove: (...c: string[]) => c.forEach((x) => set.delete(x)),
  contains: (c: string) => set.has(c),
});

beforeAll(async () => {
  (globalThis as { document?: unknown }).document = {
    documentElement: { classList: classList(root) },
    addEventListener: (type: string, fn: (e: unknown) => void) => handlers.set(type, [...(handlers.get(type) ?? []), fn]),
  };
  await import('./router');
});

afterAll(() => {
  (globalThis as { document?: unknown }).document = realDocument;
});

function swap(): Set<string> {
  const next = new Set<string>();
  const e = { newDocument: { documentElement: { classList: classList(next) } } };
  handlers.get('astro:before-swap')?.forEach((f) => f(e));
  return next;
}

describe('the classes a client-side navigation carries', () => {
  test('a page whose scripts run stays marked as scripted', () => {
    root.add('js');
    expect(swap().has('js')).toBe(true);
  });

  test('a page whose module failed is not marked as scripted again', () => {
    root.delete('js');
    const next = swap();
    expect(next.has('js')).toBe(false);
    expect(next.has('routed')).toBe(true);
  });
});
