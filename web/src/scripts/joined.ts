const ERRORS: Record<string, string> = {
  bad_email: 'We couldn’t use that email address. Check it and try again.',
  bad_bank: 'We couldn’t use that bank. Pick one from the list, or type its name with letters, numbers and spaces.',
  turnstile_failed: 'We couldn’t check that you’re not a bot. Try again.',
  rate_limited: 'Too many tries from here. Wait a few minutes, then try again.',
  waitlist_full: 'The waitlist is full for now. Please try again in a few days.',
};

export function landJoined(doc: Pick<Document, 'querySelector' | 'title'>, at: Pick<Location, 'search' | 'replace'>): void {
  const ok = doc.querySelector<HTMLElement>('[data-joined-ok]');
  if (!ok) return;
  const query = new URLSearchParams(at.search);
  if (ok.hidden && !query.has('error')) return at.replace('/#invite');
  const code = query.get('error');
  if (!code) return;
  ok.hidden = true;
  doc.querySelector<HTMLElement>('[data-joined-error]')!.hidden = false;
  doc.querySelector<HTMLElement>('[data-joined-error-text]')!.textContent = ERRORS[code] ?? 'Something went wrong on our side. Try again in a minute.';
  doc.querySelector<HTMLElement>('.joined__panel')!.dataset.state = 'error';
  doc.title = 'Hasala · That didn’t go through';
}
