/**
 * Nav: frosts up after 24 px of scroll; marks the landing section in view;
 * closes the mobile menu when one of its links is used. The nav persists
 * across client-side navigations (transition:persist in Nav.astro), so its
 * state is reset for every page here.
 */
import { onPage, observe } from './page';

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

  const links = [...document.querySelectorAll<HTMLAnchorElement>('[data-spy]')];
  const mark = (current?: string) => {
    for (const l of links) {
      if (l.dataset.spy === current) l.setAttribute('aria-current', 'true');
      else l.removeAttribute('aria-current');
    }
  };
  mark();
  const targets = links.map((l) => document.getElementById(l.dataset.spy!)).filter((el): el is HTMLElement => !!el);
  if (!targets.length) return;
  const visible = new Set<string>();
  const io = observe(
    signal,
    (entries) => {
      for (const e of entries) e.isIntersecting ? visible.add(e.target.id) : visible.delete(e.target.id);
      mark(targets.find((t) => visible.has(t.id))?.id);
    },
    { rootMargin: '-45% 0px -50% 0px' },
  );
  targets.forEach((t) => io?.observe(t));
});
