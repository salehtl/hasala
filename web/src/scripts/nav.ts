/**
 * Nav: frosts up after 24 px of scroll; marks the link to the page you are
 * on; closes the mobile menu when one of its links is used. The nav persists
 * across client-side navigations (transition:persist in Nav.astro), so its
 * state is reset for every page here.
 */
import { onPage } from './page';

const root = document.documentElement;
const frost = () => root.classList.toggle('is-scrolled', window.scrollY > 24);
// The router replaces <html>'s classes on a swap and has already scrolled the
// new page into place, so the frost is right before the new page is shown.
document.addEventListener('astro:after-swap', frost);

onPage((signal) => {
  frost();
  addEventListener('scroll', frost, { passive: true, signal });

  const menu = document.getElementById('site-menu');
  menu?.addEventListener(
    'click',
    (e) => {
      if ((e.target as Element).closest('a')) menu.hidePopover?.();
    },
    { signal },
  );
  // Back and forward don't click a menu link: shut it before the page changes.
  signal.addEventListener('abort', () => menu?.matches(':popover-open') && menu.hidePopover(), { once: true });

  const here = location.pathname.replace(/\/$/, '') || '/';
  for (const link of document.querySelectorAll<HTMLAnchorElement>('[data-nav-link]')) {
    if (new URL(link.href).pathname === here) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  }
});
