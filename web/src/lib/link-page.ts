export type LinkPage = 'freeze' | 'confirm' | 'leave';
export type LinkArrival = { step: 'ask'; token: string } | { step: 'done' } | { step: 'incomplete' };

const TOKEN = /^[A-Za-z0-9_-]{43}$/;
const DONE = 'hasalaLinkDone';

export function arriveAtLink(page: LinkPage, path: string, place: Pick<Location, 'hash'> = location, hist: History = history): LinkArrival {
  const token = place.hash.slice(1);
  const state = hist.state;
  if (TOKEN.test(token)) {
    const { [DONE]: _finished, ...rest } = state ?? {};
    hist.replaceState(state && DONE in state ? rest : state, '', path);
    return { step: 'ask', token };
  }
  hist.replaceState(state, '', path);
  return !token && state?.[DONE] === page ? { step: 'done' } : { step: 'incomplete' };
}

export function markLinkDone(page: LinkPage, hist: History = history): void {
  hist.replaceState({ ...hist.state, [DONE]: page }, '');
}
