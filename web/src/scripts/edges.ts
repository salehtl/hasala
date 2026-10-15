/**
 * Screen edges for iOS Safari (global.css, "Screen edges"). Safari shows a
 * solid colour behind the status bar (html's background, which is
 * --edge-top) and can extend the fixed .edge-top / .edge-bottom strips
 * behind its controls, so both follow the block under each screen edge: its
 * declared --edge-t at its top, --edge-b at its bottom, mixed in between (a
 * wash's solid stand-in). The theme-color meta follows the top. Checked once
 * per frame on scroll and resize (the toolbar collapsing resizes the
 * viewport) and after every page load, which covers restored scroll
 * positions. Colours change in one step, never animated. Swapping a page
 * drops the inline values, so the new page starts from its static ones.
 */
import { onPage } from './page';

const root = document.documentElement;

/**
 * The edge colour at viewport height y, or '' (the static value). The
 * declared colours are mixed by the browser (color-mix), so any colour
 * syntax works, including what the CSS minifier shortens them to.
 */
function at(y: number): string {
  for (const el of document.querySelectorAll('main > *, body > footer')) {
    const r = el.getBoundingClientRect();
    if (r.top <= y && y < r.bottom) {
      const s = getComputedStyle(el);
      return `color-mix(in srgb, ${s.getPropertyValue('--edge-t')}, ${s.getPropertyValue('--edge-b')} ${Math.round(((y - r.top) / r.height) * 100)}%)`;
    }
  }
  return '';
}

const set = (name: string, c: string) => (c ? root.style.setProperty(name, c) : root.style.removeProperty(name));

onPage((signal) => {
  let frame = 0;
  let last = '';
  const update = () => {
    frame = 0;
    const top = at(0);
    const bottom = at(innerHeight - 1);
    if (top + bottom === last) return;
    last = top + bottom;
    set('--edge-top', top);
    set('--edge-bottom', bottom);
    // html's background is --edge-top, resolved to a plain colour.
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', getComputedStyle(root).backgroundColor);
  };
  const queue = () => (frame ||= requestAnimationFrame(update));
  const opts = { passive: true, signal };
  addEventListener('scroll', queue, opts);
  addEventListener('resize', queue, opts);
  signal.addEventListener('abort', () => cancelAnimationFrame(frame));
  update();
});
