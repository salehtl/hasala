// @ts-check
/**
 * The only inline scripts the site runs. They sit in <head> so they apply
 * before first paint, which a bundled module cannot do. astro.config.mjs
 * hashes these exact strings into every page's CSP (script-src), so keep
 * them here and render them with set:html: an edit changes the hash too.
 */

/** Marks the document as scripted, so CSS can hide no-JS fallbacks. */
export const JS_CLASS = "document.documentElement.classList.add('js')";

/** Plays the hero entrance once per tab session. */
export const HERO_SEEN =
  "try{if(sessionStorage.getItem('hasala:hero'))document.documentElement.classList.add('hero-seen');else sessionStorage.setItem('hasala:hero','1')}catch(e){}";

/**
 * /i: an address with a code (/i/<code>, or the older /i#<code>) shows the
 * invited page; without one, the page explains where a code comes from.
 * Decided before first paint, so neither view flashes; the page script
 * checks the code itself and drops the class if it is not one.
 */
export const INVITE_CODE = "if(/^\\/i\\/./.test(location.pathname)||location.hash.length>1)document.documentElement.classList.add('has-code')";

export const INLINE_SCRIPTS = [JS_CLASS, HERO_SEEN, INVITE_CODE];
