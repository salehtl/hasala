/**
 * The waitlist form ("Request an invite"). It is also how people ask for a
 * bank Hasala doesn't read yet: "Another bank", then its name.
 *
 * Waitlist: validates on submit, then live once a field has an error; never
 * clears what was typed; errors are red-700 text with an icon, never colour
 * alone; focus moves to the first field with a problem. Submitting keeps the
 * button's width, says "Sending…" and locks the fields; after 8 s it says
 * "Still trying". Posts JSON to PUBLIC_API_BASE/v1/waitlist. Every accepted
 * submission shows the same "Request sent" card: the server answers
 * 202 whether the address is new or already on the list.
 *
 * In "email" mode (PUBLIC_WAITLIST_MODE, see src/lib/env.ts; the markup then
 * carries data-mail instead of data-api), the form validates the same way
 * and then, instead of posting, opens a pre-filled email to that address in
 * the visitor's email app and shows how to finish if it didn't open.
 */
import { reducedMotion } from './motion';
import { onPage } from './page';
import { bankText, postJson, renderTurnstile, waitText, type ApiAnswer } from './api';

type State = 'default' | 'focus' | 'error' | 'success';
const BANK_NAMES: Record<string, string> = { dib: 'Dubai Islamic Bank', enbd: 'Emirates NBD', adib: 'Abu Dhabi Islamic Bank', other: 'Another bank' };

const MSG = {
  emailEmpty: 'Enter your email so we can send the invite.',
  emailBad: 'We couldn’t use that email. Check it and try again.',
  bankEmpty: 'Pick your bank so we know which alerts to expect.',
  bankBad: 'Pick your bank from the list.',
  otherBad: 'Use letters, numbers and spaces for the bank name, up to 64 characters.',
};

/** The status line for answers that are not about one field. */
function answerText(a: ApiAnswer): { text: string; retry: boolean } {
  if (a.status === 0) return { text: 'We couldn’t reach Hasala. Check your connection.', retry: true };
  if (a.error === 'turnstile_failed') return { text: 'We couldn’t check that you’re not a bot. Try again.', retry: true };
  if (a.error === 'waitlist_full') return { text: 'The waitlist is full for now. Please try again in a few days.', retry: false };
  if (a.error === 'bank_list_full') return { text: 'We can’t take new bank names right now. Pick one from the list, or try again later.', retry: false };
  if (a.status === 429) return { text: `Too many tries from here. Try again in ${waitText(a.retryAfter)}.`, retry: false };
  if (a.status === 503) return { text: 'Hasala is busy right now. Try again in a minute.', retry: true };
  return { text: 'Something went wrong on our side.', retry: true };
}

/** A mailto: URL with a subject and a plain-text body (CRLF line breaks, as RFC 6068 asks). */
function mailto(to: string, subject: string, lines: string[]): string {
  return `mailto:${to}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(lines.join('\r\n'))}`;
}

/** Points the "Try again" link at the email and opens it in the visitor's email app. */
function openMail(card: HTMLElement, url: string): void {
  const again = card.querySelector<HTMLAnchorElement>('[data-mailto]');
  if (again) again.href = url;
  window.location.href = url;
}

export function initWaitlist(): void {
  onPage(setup);
}

function setup(signal: AbortSignal): void {
  const root = document.querySelector<HTMLElement>('[data-waitlist]');
  const form = root?.querySelector<HTMLFormElement>('[data-waitlist-form]');
  if (!root || !form) return;
  // The script validates; without it, the browser's own checks run.
  form.noValidate = true;
  const done = root.querySelector<HTMLElement>('.wl-done')!;
  const coin = root.querySelector<SVGElement>('.wl-coin');
  // By id: in "email" mode the fields have no names.
  const email = form.elements.namedItem('wl-email') as HTMLInputElement;
  const bank = form.elements.namedItem('wl-bank') as HTMLSelectElement;
  const other = form.elements.namedItem('wl-other') as HTMLInputElement;
  const otherField = form.querySelector<HTMLElement>('[data-field="other"]')!;
  const honeypot = form.elements.namedItem('wl-website') as HTMLInputElement;
  const submit = form.querySelector<HTMLButtonElement>('.wl-submit')!;
  const label = submit.querySelector<HTMLElement>('.wl-submit__label')!;
  const spinner = submit.querySelector<HTMLElement>('.spinner')!;
  const status = form.querySelector<HTMLElement>('.wl-status')!;
  const api = root.dataset.api;
  const mail = root.dataset.mail;
  const resetTurnstile = renderTurnstile(form, 'waitlist', signal);
  let touched = false;
  let sending = false;

  const setState = (s: State) => {
    if (root.dataset.state === s) return;
    root.dataset.state = s;
    if (reducedMotion() && coin) coin.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200 });
  };

  const showOther = () => {
    otherField.hidden = bank.value !== 'other';
    if (otherField.hidden) setError('other', null);
  };
  bank.addEventListener('change', showOther, { signal });

  // Errors
  type Field = 'email' | 'bank' | 'other';
  const fields: Field[] = ['email', 'bank', 'other'];
  const controls: Record<Field, HTMLInputElement | HTMLSelectElement> = { email, bank, other };
  const setError = (name: Field, message: string | null) => {
    const field = form.querySelector<HTMLElement>(`[data-field="${name}"]`)!;
    const control = controls[name];
    const err = field.querySelector<HTMLElement>('.field__error')!;
    field.toggleAttribute('data-invalid', !!message);
    if (message) control.setAttribute('aria-invalid', 'true');
    else control.removeAttribute('aria-invalid');
    err.hidden = !message;
    err.querySelector('span')!.textContent = message ?? '';
  };
  const emailProblem = (v: string): string | null => {
    const value = v.trim();
    if (!value) return MSG.emailEmpty;
    if (!value.includes('@') || /\s/.test(value)) return 'That doesn’t look like an email address. Check for an @.';
    const [local, domain = ''] = value.split(/@(?=[^@]*$)/);
    if (!local) return 'Add the part before the @.';
    if (!/^[^.\s]+(\.[^.\s]+)+$/.test(domain) || /\.$/.test(domain)) return 'That email looks unfinished. Check the part after the @.';
    return null;
  };
  const otherProblem = (): string | null => (bank.value === 'other' && bankText(other.value) === null ? MSG.otherBad : null);
  const validate = (): boolean => {
    const e = emailProblem(email.value);
    const b = bank.value ? null : MSG.bankEmpty;
    const o = otherProblem();
    setError('email', e);
    setError('bank', b);
    setError('other', o);
    return !e && !b && !o;
  };
  const focusFirstError = () => {
    const first = fields.find((f) => controls[f].getAttribute('aria-invalid'));
    if (first) controls[first].focus();
  };
  // Once every field is fixed, the coin stops sulking.
  const settle = () => {
    const anyInvalid = fields.some((f) => controls[f].getAttribute('aria-invalid'));
    if (!anyInvalid && root.dataset.state === 'error') setState(form.contains(document.activeElement) ? 'focus' : 'default');
  };
  email.addEventListener('input', () => touched && (setError('email', emailProblem(email.value)), settle()), { signal });
  bank.addEventListener('change', () => touched && (setError('bank', bank.value ? null : MSG.bankEmpty), settle()), { signal });
  other.addEventListener('input', () => touched && (setError('other', otherProblem()), settle()), { signal });

  // The coin follows focus
  form.addEventListener(
    'focusin',
    () => {
      if (root.dataset.state !== 'error') setState('focus');
    },
    { signal },
  );
  form.addEventListener(
    'focusout',
    () => {
      requestAnimationFrame(() => {
        if (!form.contains(document.activeElement) && root.dataset.state === 'focus') setState('default');
      });
    },
    { signal },
  );

  const lock = (on: boolean) => {
    sending = on;
    submit.style.width = on ? `${submit.offsetWidth}px` : '';
    submit.disabled = on;
    spinner.hidden = !on;
    label.textContent = on ? 'Sending…' : 'Request an invite';
    email.readOnly = on;
    other.readOnly = on;
    bank.disabled = on;
  };

  const setStatus = (text: string, tone: 'info' | 'error' = 'info', retry = false) => {
    status.dataset.tone = tone;
    status.textContent = text;
    if (retry) {
      const b = document.createElement('button');
      b.type = 'button';
      b.textContent = 'Retry';
      b.addEventListener('click', () => form.requestSubmit());
      status.append(' ', b);
    }
  };

  const showDone = (bankShown = BANK_NAMES[bank.value] ?? '') => {
    const addr = email.value.trim();
    done.querySelectorAll('[data-done-email]').forEach((el) => (el.textContent = addr));
    // "api": the catalog name only, as in the confirmation email. "email": what the email says.
    done.querySelector('[data-done-bank]')!.textContent = bankShown;
    form.hidden = true;
    done.hidden = false;
    setState('success');
    done.querySelector<HTMLElement>('#wl-done-title')!.focus({ preventScroll: true });
    done.scrollIntoView({ block: 'nearest', behavior: reducedMotion() ? 'auto' : 'smooth' });
  };

  form.addEventListener(
    'submit',
    async (ev) => {
      ev.preventDefault();
      if (sending) return;
      touched = true;
      setStatus('');
      if (!validate()) {
        setState('error');
        focusFirstError();
        return;
      }
      settle();
      // A filled honeypot is a bot: pretend it worked and send nothing.
      if (honeypot.value) {
        showDone();
        return;
      }
      const typed = bank.value === 'other' ? bankText(other.value) : '';
      if (mail) {
        const bankLine = typed ? `Another bank: ${typed}` : (BANK_NAMES[bank.value] ?? '');
        showDone(bankLine);
        openMail(
          done,
          mailto(mail, 'Hasala invite request', [
            'Hi Hasala,',
            '',
            'Please add me to the waitlist for the Hasala beta.',
            '',
            `Email: ${email.value.trim()}`,
            `Bank: ${bankLine}`,
          ]),
        );
        return;
      }
      const body: Record<string, string> = { email: email.value.trim(), bank: bank.value, source: 'web', website: '' };
      if (typed) body.otherBank = typed;
      const token = (form.elements.namedItem('cf-turnstile-response') as HTMLInputElement | null)?.value;
      if (token) body.turnstileToken = token;

      lock(true);
      const slow = window.setTimeout(() => setStatus('Still trying. Check your connection.'), 8000);
      const answer = await postJson(`${api!}/v1/waitlist`, body);
      window.clearTimeout(slow);
      lock(false);
      resetTurnstile();
      setStatus('');
      if (answer.status >= 200 && answer.status < 300) {
        showDone();
        return;
      }
      if (answer.error === 'bad_email' || answer.error === 'bad_bank') {
        if (answer.error === 'bad_email') setError('email', MSG.emailBad);
        else if (bank.value === 'other' && typed) setError('other', MSG.otherBad);
        else setError('bank', MSG.bankBad);
        setState('error');
        focusFirstError();
        return;
      }
      if (root.dataset.state === 'error') setState('default');
      const { text, retry } = answerText(answer);
      setStatus(text, 'error', retry);
    },
    { signal },
  );

  // "Copy link for a friend", or (in "email" mode) "Copy <address>".
  document.querySelectorAll<HTMLButtonElement>('[data-copy]').forEach((btn) => {
    const text = btn.querySelector('span')!;
    const label = text.textContent;
    btn.addEventListener(
      'click',
      async () => {
        const value = btn.dataset.copy!;
        try {
          await navigator.clipboard.writeText(value);
          text.textContent = btn.dataset.copied ?? 'Copied';
        } catch {
          text.textContent = value;
        }
        window.setTimeout(() => (text.textContent = label), 2400);
      },
      { signal },
    );
  });

  // Every "Request an invite" button scrolls here and focuses Email.
  const goToForm = () => {
    const target = document.getElementById('invite');
    target?.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'start' });
    window.setTimeout(() => email.focus({ preventScroll: true }), reducedMotion() ? 0 : 600);
  };
  document.querySelectorAll<HTMLAnchorElement>('a[href="#invite"], a[href="/#invite"]').forEach((a) =>
    a.addEventListener(
      'click',
      (e) => {
        if (form.hidden) return;
        e.preventDefault();
        history.replaceState(history.state, '', '#invite');
        goToForm();
      },
      { signal },
    ),
  );

  if (location.hash === '#invite') window.setTimeout(() => email.focus({ preventScroll: true }), 300);
}
