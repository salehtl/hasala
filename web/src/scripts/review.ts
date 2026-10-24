/**
 * The review deck (components/detail/Review.astro), on the landing and on
 * /how-it-works. Motion moment D, "Review · the swipe loop": the first time
 * the stage is in view, three cards are swiped (each to its own direction)
 * and the deck rests on the fourth. It plays once, in under five seconds, and
 * stops for good on hover, focus, a hidden tab or any interaction, so nothing
 * moves on its own for long (WCAG 2.2.2). After that the visitor sorts: drag
 * or flick the top card, tap a pill, a legend chip or Use, or press an arrow
 * key on the focused deck. After the last card the deck says "All caught up"
 * and offers Start again; Undo puts the last card back. Only the visitor's
 * own choices are announced to screen readers. With reduced motion nothing
 * plays on its own and a choice crossfades to the next card.
 */
import { reducedMotion } from './motion';
import { onPage, observe } from './page';

type Dir = 'need' | 'want' | 'save' | 'transfer';
const DIRS: Dir[] = ['need', 'want', 'save', 'transfer'];
const LABEL: Record<Dir, string> = { need: 'Need', want: 'Want', save: 'Save', transfer: 'Transfer' };
const KEYS: Record<string, Dir> = { ArrowRight: 'need', ArrowLeft: 'want', ArrowDown: 'save', ArrowUp: 'transfer' };
const OUT: Record<Dir, [number, number, number]> = {
  need: [1.4, 0, 16],
  want: [-1.4, 0, -16],
  save: [0, 1.2, 4],
  transfer: [0, -1.2, -4],
};
const EASE_OUT = 'cubic-bezier(.22,1,.36,1)';
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function initReview(): void {
  onPage(setup);
}

function setup(signal: AbortSignal): void {
  const stage = document.querySelector<HTMLElement>('[data-review]');
  if (!stage) return;
  const $ = <T extends HTMLElement>(s: string) => stage.querySelector<T>(s);
  const cards = [...stage.querySelectorAll<HTMLElement>('.rcard')];
  const n = cards.length;
  const total = Number(stage.dataset.total) || n + 1;
  const deck = $('.deck')!;
  const done = $('[data-review-done]')!;
  const toast = $('.toast')!;
  const toastText = $('[data-toast-text]')!;
  const counter = $('[data-review-count]');
  const progress = $('[data-review-progress]');
  const live = $('[data-review-live]');
  const pills = new Map<Dir, HTMLElement>();
  stage.querySelectorAll<HTMLElement>('[data-sort]').forEach((b) => pills.set(b.dataset.sort as Dir, b));
  // The legend beside the stage: lights up with the swipe and sorts on tap.
  const section = stage.closest('section') ?? document;
  const legends = new Map<Dir, HTMLElement>();
  DIRS.forEach((d) => {
    const l = section.querySelector<HTMLElement>(`.dir--${d}`);
    if (l) legends.set(d, l);
  });

  let top = 0;
  let busy = false;
  let history: number[] = [];
  let timer = 0;
  let inView = false;
  let paused = false;
  let played = false;
  // The demo's lean, while it runs: a touch on the card cancels it.
  let autoLean: (() => void) | null = null;

  const say = (s: string) => live && (live.textContent = s);
  const lit = (dir: Dir | null) => DIRS.forEach((d) => legends.get(d)?.toggleAttribute('data-active', d === dir));

  const layout = () => {
    cards.forEach((c, i) => {
      const pos = i === top ? '0' : i === top + 1 ? '1' : 'x';
      c.dataset.pos = pos;
      c.style.transform = '';
      c.style.opacity = '';
      if (pos === '0') c.removeAttribute('aria-hidden');
      else c.setAttribute('aria-hidden', 'true');
      c.querySelectorAll<HTMLElement>('.rcard__tint').forEach((t) => (t.style.opacity = ''));
    });
    const end = top >= n;
    deck.dataset.left = String(n - top);
    done.hidden = !end;
    stage.toggleAttribute('data-done', end);
    legends.forEach((l) => l.toggleAttribute('aria-disabled', end));
    const at = Math.min(top + 2, total); // "2 of 6" for the first card, as in the app
    if (counter) counter.textContent = String(at);
    // The first card's 2/6 is the stylesheet's, so nothing moves on load.
    if (progress) progress.style.clipPath = top ? `inset(0 ${((1 - (end ? 1 : at / total)) * 100).toFixed(3)}% 0 0 round 3px)` : '';
  };

  const showToast = (dir: Dir, announce: boolean) => {
    toastText.textContent = `Sorted as ${LABEL[dir]}`;
    if (announce) say(`Sorted as ${LABEL[dir]}. ${top + 1 >= n ? 'All caught up. ' : ''}Undo is available.`);
    toast.toggleAttribute('data-show', true);
    window.clearTimeout(Number(toast.dataset.t));
    toast.dataset.t = String(window.setTimeout(() => toast.removeAttribute('data-show'), 2200));
  };

  const tint = (card: HTMLElement, dir: Dir, amount: number) => {
    const t = card.querySelector<HTMLElement>(`.rcard__tint--${dir}`);
    if (t) t.style.opacity = String(amount);
  };

  // The next card, or the "All caught up" panel, settles into place.
  const advance = () => {
    history.push(top);
    top++;
    layout();
    if (top >= n) done.animate([{ opacity: 0, transform: 'scale(.96)' }, { opacity: 1, transform: 'none' }], { duration: 240, easing: EASE_OUT });
  };

  async function swipe(dir: Dir, opts: { drag?: boolean; auto?: boolean; v?: number } = {}) {
    if (busy || top >= n) return;
    busy = true;
    const card = cards[top];
    const next = cards[top + 1];
    const pill = pills.get(dir);
    const legend = legends.get(dir);
    if (reducedMotion()) {
      const fade = card.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 200, fill: 'forwards' });
      await fade.finished;
      showToast(dir, !opts.auto);
      advance();
      fade.cancel();
      (cards[top] ?? done).animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200 });
      busy = false;
      return;
    }
    const w = stage!.clientWidth;
    const [ox, oy, rot] = OUT[dir];
    if (!opts.drag) {
      // 700 → 1220 ms: the drag. The card leans, the tint grows, the pill swells.
      pill?.toggleAttribute('data-active', true);
      legend?.toggleAttribute('data-active', true);
      const lean = card.animate(
        [{ transform: 'none' }, { transform: `translate(${ox * 40}px, ${oy * 40}px) rotate(${rot * 0.38}deg)` }],
        { duration: 520, easing: EASE_OUT, fill: 'forwards' },
      );
      card.querySelector<HTMLElement>(`.rcard__tint--${dir}`)?.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 520, fill: 'forwards' });
      if (opts.auto)
        autoLean = () => {
          autoLean = null;
          card.getAnimations({ subtree: true }).forEach((a) => a.cancel());
          pill?.removeAttribute('data-active');
          legend?.removeAttribute('data-active');
          busy = false;
        };
      const leaned = await lean.finished.then(
        () => true,
        () => false,
      );
      autoLean = null;
      if (!leaned) return; // grabbed mid-lean: the card is the visitor's now
    }
    // 1220 → 1500 ms: commit. Out it goes; the toast rises with Undo. A
    // drag leaves from where the finger let go at the finger's speed: this
    // curve starts at 2× its average speed, so 2·distance / release speed
    // (clamped to 180–320 ms) carries the flick on without a lurch. The
    // demo, starting from rest, accelerates away.
    const from = card.getAnimations().length ? getComputedStyle(card).transform : card.style.transform || 'none';
    const tx = ox * w;
    const ty = oy * 600;
    let duration = 280;
    if (opts.drag) {
      const m = new DOMMatrixReadOnly(from === 'none' ? undefined : from);
      const dist = Math.hypot(tx - m.e, ty - m.f);
      duration = Math.min(320, Math.max(180, (2 * dist) / Math.max(opts.v ?? 0, 1)));
    }
    const fly = card.animate(
      [
        { transform: from, opacity: 1 },
        { transform: `translate(${tx}px, ${ty}px) rotate(${rot}deg)`, opacity: 0 },
      ],
      { duration, easing: opts.drag ? 'cubic-bezier(.3,.6,.4,1)' : 'cubic-bezier(.5,0,.75,0)', fill: 'forwards' },
    );
    showToast(dir, !opts.auto);
    // 1500 → 1740 ms: the peek card scales up and lifts into place.
    next?.animate([{ transform: 'translateY(10px) scale(0.96)' }, { transform: 'none' }], {
      duration: 240,
      delay: 200,
      easing: EASE_OUT,
      fill: 'forwards',
    });
    await fly.finished;
    await wait(240);
    pill?.removeAttribute('data-active');
    legend?.removeAttribute('data-active');
    card.getAnimations({ subtree: true }).forEach((a) => a.cancel());
    next?.getAnimations().forEach((a) => a.cancel());
    advance();
    busy = false;
  }

  const appear = (el: HTMLElement) => {
    if (!reducedMotion()) el.animate([{ opacity: 0, transform: 'scale(.96)' }, { opacity: 1, transform: 'none' }], { duration: 240, easing: 'ease-out' });
  };

  const undo = () => {
    if (busy || !history.length) return;
    top = history.pop()!;
    layout();
    toast.removeAttribute('data-show');
    say('Undone.');
    appear(cards[top]);
  };

  const restart = () => {
    if (busy) return;
    top = 0;
    history = [];
    layout();
    toast.removeAttribute('data-show');
    // The button that was pressed is gone; keep focus on the deck.
    deck.focus();
    say(`Back to the first card, ${cards[0].querySelector('.rcard__merchant')?.textContent}.`);
    appear(cards[0]);
  };

  // Autoplay, once: the first three cards, each to its own direction.
  const PLAN = cards.slice(0, 3).map((c) => c.dataset.to as Dir);
  let running = false;
  async function play() {
    if (played || running) return;
    running = true;
    for (const dir of PLAN) {
      await wait(500);
      if (!canPlay()) break;
      played = true; // once a card has moved, the demo never starts again
      await swipe(dir, { auto: true });
    }
    running = false;
  }
  const canPlay = () => !signal.aborted && inView && !paused && !document.hidden && !reducedMotion();
  signal.addEventListener('abort', () => {
    window.clearTimeout(timer);
    window.clearTimeout(Number(toast.dataset.t));
  });
  const schedule = () => {
    window.clearTimeout(timer);
    if (!played && canPlay()) timer = window.setTimeout(play, 300);
  };

  // Hover, focus or a touch stops the demo for good: the visitor is in charge.
  const stop = () => (paused = true);
  stage.addEventListener('pointerenter', (e) => {
    if (e.pointerType === 'mouse') stop();
  });
  stage.addEventListener('focusin', stop);
  document.addEventListener('visibilitychange', schedule, { signal });

  observe(
    signal,
    ([e]) => {
      inView = e.isIntersecting;
      schedule();
    },
    { threshold: 0.4 },
  )?.observe(stage);

  // Pills in the stage and legend chips beside it.
  section.querySelectorAll<HTMLElement>('[data-sort]').forEach((btn) =>
    btn.addEventListener('click', () => {
      stop();
      void swipe(btn.dataset.sort as Dir);
    }),
  );
  $('[data-undo]')?.addEventListener('click', undo);
  $('[data-review-restart]')?.addEventListener('click', restart);
  // Use takes Hasala's guess: the card goes where it belongs.
  stage.addEventListener('click', (e) => {
    const card = (e.target as Element).closest('[data-use]')?.closest<HTMLElement>('.rcard[data-pos="0"]');
    if (card) void swipe(card.dataset.to as Dir);
  });
  deck.addEventListener('keydown', (e) => {
    const dir = KEYS[e.key];
    if (!dir || e.target !== deck) return;
    e.preventDefault();
    stop();
    void swipe(dir);
  });

  // Drag to try. A flick commits as well as a long drag: the release speed
  // comes from the last few pointer samples. Past 140 px the card drags with
  // rising resistance. A second finger is ignored.
  let startX = 0;
  let startY = 0;
  let dx = 0;
  let dy = 0;
  let id = 0;
  let dragging = false;
  let samples: [number, number, number][] = [];
  const band = (d: number) => {
    const a = Math.abs(d) - 140;
    return a <= 0 ? d : Math.sign(d) * (140 + (a * 0.55 * 300) / (300 + 0.55 * a));
  };
  stage.addEventListener('pointerdown', (e) => {
    // Use is a tap, not a drag: no capture, so its click lands on it.
    stop();
    if (dragging || (e.target as Element).closest('[data-use]')) return;
    const card = (e.target as Element).closest<HTMLElement>('.rcard[data-pos="0"]');
    if (card) autoLean?.();
    if (!card || busy) return;
    dragging = true;
    id = e.pointerId;
    startX = e.clientX;
    startY = e.clientY;
    dx = dy = 0;
    samples = [[0, 0, e.timeStamp]];
    card.setPointerCapture(e.pointerId);
  });
  stage.addEventListener('pointermove', (e) => {
    if (!dragging || e.pointerId !== id) return;
    dx = e.clientX - startX;
    dy = e.clientY - startY;
    samples = [...samples.slice(-2), [dx, dy, e.timeStamp]];
    const card = cards[top];
    const x = band(dx);
    card.style.transform = `translate(${x}px, ${band(dy)}px) rotate(${x / 14}deg)`;
    const dir = dirFor(dx, dy);
    const d = Math.hypot(dx, dy);
    DIRS.forEach((k) => tint(card, k, k === dir ? Math.min(1, d / 120) : 0));
    // The legend beside the stage answers the drag, as it does the pills.
    lit(d > 24 ? dir : null);
  });
  const end = (e: PointerEvent) => {
    if (!dragging || e.pointerId !== id) return;
    dragging = false;
    const card = cards[top];
    const [sx, sy, st] = samples[0];
    const v = Math.hypot(dx - sx, dy - sy) / Math.max(1, e.timeStamp - st);
    // A flick needs some travel too, so a tap that jitters never commits, and
    // a cancel (the page took over to scroll) is never a flick.
    const flick = e.type === 'pointerup' && v > 0.11 && Math.hypot(dx, dy) > 24;
    const dir = dirFor(dx, dy);
    const commit = Math.hypot(dx, dy) > 90 || flick;
    // The chosen direction's legend stays lit until the card has gone.
    lit(commit ? dir : null);
    if (commit) {
      void swipe(dir, { drag: true, v });
    } else if (dx || dy) {
      card.animate([{ transform: card.style.transform }, { transform: 'none' }], { duration: 240, easing: 'cubic-bezier(.34,1.56,.64,1)' });
      card.style.transform = '';
      DIRS.forEach((k) => tint(card, k, 0));
    }
  };
  stage.addEventListener('pointerup', end);
  stage.addEventListener('pointercancel', end);

  layout();
}

function dirFor(dx: number, dy: number): Dir {
  if (Math.abs(dx) >= Math.abs(dy)) return dx > 0 ? 'need' : 'want';
  return dy > 0 ? 'save' : 'transfer';
}
