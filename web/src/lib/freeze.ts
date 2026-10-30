export type FreezeResult = 'done' | 'retry' | 'unreachable';

export async function postFreeze(api: string, token: string, send: typeof fetch = fetch): Promise<FreezeResult> {
  try {
    const answer = await send(`${api}/v1/account/freeze`, {
      method: 'POST',
      mode: 'cors',
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      cache: 'no-store',
      headers: { 'content-type': 'text/plain;charset=UTF-8' },
      body: JSON.stringify({ token }),
    });
    return answer.status === 204 ? 'done' : 'retry';
  } catch {
    return 'unreachable';
  }
}
