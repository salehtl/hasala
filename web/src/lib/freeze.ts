export type FreezeResult = 'done' | 'retry' | 'unreachable';

const FREEZE_WAIT_MS = 20_000;

export async function postFreeze(api: string, token: string, send: typeof fetch = fetch, waitMs = FREEZE_WAIT_MS): Promise<FreezeResult> {
  const stop = new AbortController();
  let waitedOut = false;
  const timer = setTimeout(() => {
    waitedOut = true;
    stop.abort();
  }, waitMs);
  try {
    const answer = await send(`${api}/v1/account/freeze`, {
      method: 'POST',
      mode: 'cors',
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      cache: 'no-store',
      headers: { 'content-type': 'text/plain;charset=UTF-8' },
      body: JSON.stringify({ token }),
      signal: stop.signal,
    });
    return answer.status === 204 ? 'done' : 'retry';
  } catch {
    return waitedOut ? 'retry' : 'unreachable';
  } finally {
    clearTimeout(timer);
  }
}
