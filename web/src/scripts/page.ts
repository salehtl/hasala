/**
 * Page lifecycle under Astro's <ClientRouter />. A bundled module runs once
 * per full load, but the router swaps pages without reloading, so every
 * per-page setup goes through onPage(): it runs now (the module runs after
 * the document is parsed, or right after a swap when the router first adds
 * it), and again after every later swap. The AbortSignal fires when the page
 * is swapped out: pass it to addEventListener and use it to disconnect
 * observers, so nothing from the old page keeps running.
 */
export function onPage(init: (signal: AbortSignal) => void): void {
  let ctrl: AbortController | undefined;
  let stale = false;
  const run = () => {
    ctrl?.abort();
    ctrl = new AbortController();
    stale = false;
    init(ctrl.signal);
  };
  document.addEventListener('astro:before-swap', () => {
    ctrl?.abort();
    ctrl = undefined;
    stale = true;
  });
  document.addEventListener('astro:page-load', () => {
    if (stale) run();
  });
  run();
}

/** An IntersectionObserver that disconnects when the page is swapped out. */
export function observe(
  signal: AbortSignal,
  cb: IntersectionObserverCallback,
  opts?: IntersectionObserverInit,
): IntersectionObserver | null {
  if (!('IntersectionObserver' in window)) return null;
  const io = new IntersectionObserver(cb, opts);
  signal.addEventListener('abort', () => io.disconnect(), { once: true });
  return io;
}
