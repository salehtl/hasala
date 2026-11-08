import { describe, expect, test } from 'bun:test';
import { JS_CLASS } from './inline-scripts.mjs';

type Listener = { type: string; fn: (e: unknown) => void; capture: unknown };

function boot() {
  const classes = new Set<string>();
  const listeners: Listener[] = [];
  const document = { documentElement: { classList: { add: (c: string) => classes.add(c), remove: (c: string) => classes.delete(c) } } };
  const addEventListener = (type: string, fn: (e: unknown) => void, capture: unknown) => listeners.push({ type, fn, capture });
  new Function('document', 'addEventListener', JS_CLASS)(document, addEventListener);
  const fire = (target: unknown) => listeners.filter((l) => l.type === 'error' && l.capture === true).forEach((l) => l.fn({ target }));
  return { classes, fire };
}

describe('the scripted-page class', () => {
  test('is set before any module runs', () => {
    expect(boot().classes.has('js')).toBe(true);
  });

  test('goes when a module script cannot load', () => {
    const { classes, fire } = boot();
    fire({ tagName: 'SCRIPT', type: 'module' });
    expect(classes.has('js')).toBe(false);
  });

  test('stays when a third-party classic script cannot load', () => {
    const { classes, fire } = boot();
    fire({ tagName: 'SCRIPT', type: '' });
    expect(classes.has('js')).toBe(true);
  });

  test('stays for a failed image and for a runtime error', () => {
    const { classes, fire } = boot();
    fire({ tagName: 'IMG' });
    fire({});
    expect(classes.has('js')).toBe(true);
  });
});
