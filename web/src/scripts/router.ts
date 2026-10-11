/**
 * Glue for Astro's <ClientRouter /> (Base.astro). On a client-side
 * navigation the router gives <html> the new page's attributes, which drops
 * the classes the <head> scripts added on the first load, and a head script
 * that already ran is not run again. So the classes are put on the incoming
 * document before the swap:
 *   js         no-JS fallbacks stay hidden;
 *   hero-seen  the hero entrance still plays once per tab session;
 *   routed     this page arrived by a client-side navigation, so first-load
 *              entrances (the invite tile on /i) stay still;
 *   vt-swap    scrolling is instant while the router puts the new page at the
 *              top, at its #fragment or back where it was (a smooth scroll
 *              under the cross-fade reads as a glitch). It goes once the new
 *              page's scripts have run.
 * Page scripts re-run through onPage() in ./page.
 *
 * Every page carries the same CSP (src/lib/csp-union.mjs), because the
 * document keeps enforcing the policy it loaded with. If a fetched page
 * brings a different one (a deploy since this tab loaded), it is loaded in
 * full instead of swapped in.
 */
import { onPage } from './page';

const root = document.documentElement;
const CSP = 'meta[http-equiv="content-security-policy" i]';

document.addEventListener('astro:before-preparation', (e) => {
  const load = e.loader;
  e.loader = async () => {
    await load();
    if (e.newDocument === document) return;
    const csp = (d: Document) => d.querySelector(CSP)?.getAttribute('content');
    if (csp(e.newDocument) !== csp(document)) e.preventDefault();
  };
});

document.addEventListener('astro:before-swap', (e) => {
  const next = e.newDocument.documentElement.classList;
  next.add('js', 'vt-swap', 'routed');
  let seen = root.classList.contains('hero-seen');
  try {
    seen ||= !!sessionStorage.getItem('hasala:hero');
  } catch {
    /* no storage: the entrance plays, as on a full load */
  }
  if (seen) next.add('hero-seen');
});

// Once the new page's scripts have run.
onPage(() => root.classList.remove('vt-swap'));
