/**
 * Talking to hasalad's public routes (spec 07 §5): JSON in, `02`'s JSON
 * envelope out ({ "error": "<code>", "detail"?: "..." } on failure). No
 * cookies, no referrer. A network failure resolves to status 0.
 */
export type ApiAnswer = { status: number; error: string; data: Record<string, unknown>; retryAfter: number };

export async function postJson(url: string, body: unknown): Promise<ApiAnswer> {
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(body),
      credentials: 'omit',
      mode: 'cors',
      referrerPolicy: 'no-referrer',
      cache: 'no-store',
    });
    let data: Record<string, unknown> = {};
    try {
      data = await res.json();
    } catch {
      /* an empty body is fine */
    }
    const retryAfter = Number.parseInt(res.headers.get('Retry-After') ?? '', 10);
    return { status: res.status, error: typeof data.error === 'string' ? data.error : '', data, retryAfter: Number.isFinite(retryAfter) ? retryAfter : 0 };
  } catch {
    return { status: 0, error: 'network', data: {}, retryAfter: 0 };
  }
}

/** "a minute", "3 minutes", "an hour": for a Retry-After in seconds. */
export function waitText(seconds: number): string {
  if (seconds <= 90) return 'a minute';
  const min = Math.ceil(seconds / 60);
  if (min < 60) return `${min} minutes`;
  const h = Math.ceil(min / 60);
  return h === 1 ? 'an hour' : `${h} hours`;
}

/** Spec 07 §5.3 / §5.6: a bank name the server accepts (bank_text, §4.3), or null. */
export function bankText(v: string): string | null {
  const t = v.trim().replace(/\s+/g, ' ');
  if (!t) return '';
  return [...t].length <= 64 && /^[\p{L}\p{M}\p{Nd} &.'()/-]+$/u.test(t) ? t : null;
}

type Turnstile = {
  render: (el: HTMLElement, opts: Record<string, unknown>) => string;
  reset: (id: string) => void;
  remove: (id: string) => void;
};
declare global {
  interface Window {
    turnstile?: Turnstile;
    hasalaTurnstileReady?: () => void;
  }
}
const waiting: (() => void)[] = [];
let requested = false;

/**
 * Loads Turnstile's api.js once per document. The router rebuilds <head> on
 * every client-side navigation and would drop the tag, so an empty
 * placeholder with the same transition:persist id goes into each incoming
 * page: Astro then keeps our tag where it is. data-astro-exec tells the
 * router the tag has run, so it never re-inserts (and re-runs) it.
 */
function loadTurnstile(): void {
  if (requested) return;
  requested = true;
  window.hasalaTurnstileReady = () => waiting.splice(0).forEach((f) => f());
  const s = document.createElement('script');
  s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=hasalaTurnstileReady';
  s.async = true;
  s.dataset.astroTransitionPersist = 'turnstile';
  s.dataset.astroExec = '';
  document.head.append(s);
  document.addEventListener('astro:before-swap', (e) => {
    const keep = e.newDocument.createElement('meta');
    keep.dataset.astroTransitionPersist = 'turnstile';
    e.newDocument.head.append(keep);
  });
}

/**
 * Cloudflare Turnstile, rendered explicitly (so it also appears after a
 * client-side navigation) with the action the server checks (spec 07 §5.10).
 * Returns a reset function: tokens are single use, so call it after every
 * attempt. A no-op when the form has no widget (no site key at build time).
 */
export function renderTurnstile(form: HTMLFormElement, action: 'waitlist' | 'bank_request', signal: AbortSignal): () => void {
  const box = form.querySelector<HTMLElement>('.cf-turnstile');
  if (!box?.dataset.sitekey) return () => {};
  let id = '';
  const draw = () => {
    if (signal.aborted || !window.turnstile || box.childElementCount) return;
    id = window.turnstile.render(box, { sitekey: box.dataset.sitekey, action, theme: 'light', size: 'flexible', appearance: 'interaction-only' });
    signal.addEventListener('abort', () => window.turnstile?.remove(id), { once: true });
  };
  if (window.turnstile) draw();
  else {
    waiting.push(draw);
    loadTurnstile();
  }
  return () => {
    if (id) window.turnstile?.reset(id);
  };
}
