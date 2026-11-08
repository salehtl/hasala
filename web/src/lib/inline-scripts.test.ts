import { describe, expect, test } from 'bun:test';
import { JS_CLASS } from './inline-scripts.mjs';

type Listener = { type: string; fn: (e: unknown) => void; capture: unknown };

const ORIGIN = 'https://hasala.app';
const MODULE = `${ORIGIN}/_astro/Base.abc123.js`;

function boot() {
  const classes = new Set<string>();
  const listeners: Listener[] = [];
  const document = { readyState: 'interactive', documentElement: { classList: { add: (c: string) => classes.add(c), remove: (c: string) => classes.delete(c) } } };
  const addEventListener = (type: string, fn: (e: unknown) => void, capture: unknown) => listeners.push({ type, fn, capture });
  new Function('document', 'addEventListener', 'origin', JS_CLASS)(document, addEventListener, ORIGIN);
  const dispatch = (e: unknown) => listeners.filter((l) => l.type === 'error' && l.capture === true).forEach((l) => l.fn(e));
  const fire = (target: unknown) => dispatch({ target });
  const fireOnWindow = (filename: string) => dispatch({ target: {}, filename });
  return { classes, document, fire, fireOnWindow };
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

  test('goes when a module cannot be parsed or throws while the page boots', () => {
    const { classes, fireOnWindow } = boot();
    fireOnWindow(MODULE);
    expect(classes.has('js')).toBe(false);
  });

  test('stays for an error from a script that is not one of ours', () => {
    const { classes, fireOnWindow } = boot();
    fireOnWindow('https://challenges.cloudflare.com/_astro/api.js');
    fireOnWindow(`${ORIGIN}/other.js`);
    fireOnWindow('');
    expect(classes.has('js')).toBe(true);
  });

  test('stays for an error once the page has finished loading', () => {
    const { classes, document, fireOnWindow } = boot();
    document.readyState = 'complete';
    fireOnWindow(MODULE);
    expect(classes.has('js')).toBe(true);
  });
});
