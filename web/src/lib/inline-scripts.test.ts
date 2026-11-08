import { describe, expect, test } from 'bun:test';
import { INVITE_CODE, JS_CLASS } from './inline-scripts.mjs';

type Listener = { type: string; fn: (e: unknown) => void; capture: unknown };

const ORIGIN = 'https://hasala.app';
const MODULE = `${ORIGIN}/_astro/Base.abc123.js`;

function boot() {
  const classes = new Set<string>();
  const listeners: Listener[] = [];
  const invite = { shown: false };
  const document = {
    readyState: 'interactive',
    documentElement: { classList: { add: (c: string) => classes.add(c), remove: (c: string) => classes.delete(c), contains: (c: string) => classes.has(c) } },
    querySelector: (selector: string) => (selector === '[data-code]:not([hidden])' && invite.shown ? {} : null),
  };
  const addEventListener = (type: string, fn: (e: unknown) => void, capture: unknown) => listeners.push({ type, fn, capture });
  new Function('document', 'addEventListener', 'origin', JS_CLASS)(document, addEventListener, ORIGIN);
  const openInvite = (location: { pathname: string; hash: string }) => new Function('document', 'addEventListener', 'location', INVITE_CODE)(document, addEventListener, location);
  const dispatch = (e: unknown) => listeners.filter((l) => l.type === 'error' && l.capture === true).forEach((l) => l.fn(e));
  const fire = (target: unknown) => dispatch({ target });
  const fireOnWindow = (filename: string) => dispatch({ target: {}, filename });
  return { classes, document, invite, openInvite, fire, fireOnWindow };
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

describe('the invite view', () => {
  const invited = () => {
    const page = boot();
    page.openInvite({ pathname: '/i/ABCD', hash: '' });
    expect(page.classes.has('has-code')).toBe(true);
    return page;
  };

  test('falls back to the view with no code when a module cannot load', () => {
    const { classes, fire } = invited();
    fire({ tagName: 'SCRIPT', type: 'module' });
    expect(classes.has('has-code')).toBe(false);
  });

  test('falls back when a module throws before any code is shown', () => {
    const { classes, fireOnWindow } = invited();
    fireOnWindow(MODULE);
    expect(classes.has('has-code')).toBe(false);
  });

  test('stays once the code is on the page and another module fails', () => {
    const { classes, invite, fire } = invited();
    invite.shown = true;
    fire({ tagName: 'SCRIPT', type: 'module' });
    expect(classes.has('has-code')).toBe(true);
    expect(classes.has('js')).toBe(false);
  });

  test('stays for a failure that is not one of our modules', () => {
    const { classes, fire, fireOnWindow } = invited();
    fire({ tagName: 'SCRIPT', type: '' });
    fireOnWindow(`${ORIGIN}/other.js`);
    expect(classes.has('has-code')).toBe(true);
  });

  test('an address with no code never gets it', () => {
    const page = boot();
    page.openInvite({ pathname: '/i', hash: '' });
    expect(page.classes.has('has-code')).toBe(false);
  });

  test('the head script that sets the class runs before the one that watches for a failure', async () => {
    const base = await Bun.file(new URL('../layouts/Base.astro', import.meta.url)).text();
    expect(base.indexOf('set:html={JS_CLASS}')).toBeGreaterThan(-1);
    expect(base.indexOf('set:html={JS_CLASS}')).toBeLessThan(base.indexOf('<slot name="head"'));
  });

  test('the page script puts it back when it reads a code after another module failed', async () => {
    const source = await Bun.file(new URL('../pages/i.astro', import.meta.url)).text();
    const showing = source.indexOf("const shown = code.match(/.{4}/g)!.join('-');");
    expect(source.indexOf("document.documentElement.classList.add('has-code');")).toBeGreaterThan(-1);
    expect(source.indexOf("document.documentElement.classList.add('has-code');")).toBeLessThan(showing);
  });
});
