/**
 * Talking to hasalad's public routes: JSON in, `02`'s JSON
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
    return { status: res.status, error: typeof data.error === 'string' ? data.error : '', data, retryAfter: Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : 0 };
  } catch {
    return { status: 0, error: 'network', data: {}, retryAfter: 0 };
  }
}

/** "a minute", "3 minutes", "an hour": for a Retry-After in seconds. */
export function waitText(seconds: number): string {
  if (!(seconds > 0)) return 'a few minutes';
  if (seconds <= 90) return 'a minute';
  const min = Math.ceil(seconds / 60);
  if (min < 60) return `${min} minutes`;
  const h = Math.ceil(min / 60);
  return h === 1 ? 'an hour' : `${h} hours`;
}

/** A bank name the server accepts (its bank_text rules), or null. */
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
const waiting: ((loaded: boolean) => void)[] = [];
let requested = false;
let keepsTag = false;
const settleLoad = (loaded: boolean) => waiting.splice(0).forEach((f) => f(loaded));

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
  window.hasalaTurnstileReady = () => settleLoad(true);
  const s = document.createElement('script');
  s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=hasalaTurnstileReady';
  s.async = true;
  s.dataset.astroTransitionPersist = 'turnstile';
  s.dataset.astroExec = '';
  s.onerror = () => {
    s.remove();
    requested = false;
    settleLoad(false);
  };
  document.head.append(s);
  if (keepsTag) return;
  keepsTag = true;
  document.addEventListener('astro:before-swap', (e) => {
    const keep = e.newDocument.createElement('meta');
    keep.dataset.astroTransitionPersist = 'turnstile';
    e.newDocument.head.append(keep);
  });
}

export type TurnstileCheck = { state: 'off' } | { state: 'ready'; token: string } | { state: 'missing' };
export type TurnstileGate = { check: () => Promise<TurnstileCheck>; reset: () => void };
const MISSING: TurnstileCheck = { state: 'missing' };

/**
 * Cloudflare Turnstile, rendered explicitly (so it also appears after a
 * client-side navigation) with the action the server checks.
 * Returns the form's token check and its reset: tokens are single use, so
 * call reset after every attempt. With no widget (no site key at build time)
 * check answers "off" and reset does nothing.
 */
export function renderTurnstile(form: HTMLFormElement, action: 'waitlist' | 'bank_request', signal: AbortSignal, waitMs = 15000): TurnstileGate {
  const box = form.querySelector<HTMLElement>('.cf-turnstile');
  if (!box?.dataset.sitekey) return { check: async () => ({ state: 'off' }), reset: () => {} };
  let id = '';
  let token = '';
  const waiters = new Set<(c: TurnstileCheck) => void>();
  const settle = (c: TurnstileCheck) => waiters.forEach((f) => f(c));
  const give = (t: string) => {
    token = t;
    if (t) settle({ state: 'ready', token: t });
  };
  const draw = () => {
    if (signal.aborted || id || !window.turnstile || box.childElementCount) return;
    id = window.turnstile.render(box, {
      sitekey: box.dataset.sitekey,
      action,
      theme: 'light',
      size: 'flexible',
      appearance: 'interaction-only',
      callback: give,
      'expired-callback': () => give(''),
    });
  };
  const load = () => {
    if (window.turnstile) draw();
    else {
      waiting.push((loaded) => (loaded ? draw() : settle(MISSING)));
      loadTurnstile();
    }
  };
  signal.addEventListener(
    'abort',
    () => {
      if (id) window.turnstile?.remove(id);
      id = '';
      token = '';
      settle(MISSING);
    },
    { once: true },
  );
  load();
  return {
    check: () =>
      new Promise((resolve) => {
        if (signal.aborted) return resolve(MISSING);
        if (token) return resolve({ state: 'ready', token });
        const finish = (c: TurnstileCheck) => {
          clearTimeout(timer);
          waiters.delete(finish);
          resolve(c);
        };
        const timer = setTimeout(() => finish(MISSING), waitMs);
        waiters.add(finish);
        if (!id) load();
      }),
    reset: () => {
      token = '';
      if (id) window.turnstile?.reset(id);
    },
  };
}

export async function postWithTurnstile(url: string, body: Record<string, string>, turnstile: TurnstileGate): Promise<ApiAnswer> {
  const check = await turnstile.check();
  if (check.state === 'missing') return { status: 403, error: 'turnstile_failed', data: {}, retryAfter: 0 };
  return postJson(url, check.state === 'ready' ? { ...body, turnstileToken: check.token } : body);
}
