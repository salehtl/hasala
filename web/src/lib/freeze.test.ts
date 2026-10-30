import { describe, expect, test } from 'bun:test';
import { postFreeze } from './freeze';

const token = 'A'.repeat(43);
const answering = (status: number) => (async () => new Response(null, { status })) as unknown as typeof fetch;

describe('postFreeze', () => {
  test('only a 204 is done', async () => {
    expect(await postFreeze('https://api.example/api', token, answering(204))).toBe('done');
  });

  for (const status of [200, 202, 400, 403, 404, 426, 429, 500, 502, 503, 530]) {
    test(`a ${status} asks for a retry`, async () => {
      expect(await postFreeze('https://api.example/api', token, answering(status))).toBe('retry');
    });
  }

  test('a failed request is unreachable', async () => {
    const failing = (async () => {
      throw new TypeError('failed to fetch');
    }) as unknown as typeof fetch;
    expect(await postFreeze('https://api.example/api', token, failing)).toBe('unreachable');
  });

  test('the request can read the status and stays free of a preflight', async () => {
    let url = '';
    let init: RequestInit = {};
    const capture = (async (u: string, i: RequestInit) => {
      url = u;
      init = i;
      return new Response(null, { status: 204 });
    }) as unknown as typeof fetch;
    await postFreeze('https://api.example/api', token, capture);
    expect(url).toBe('https://api.example/api/v1/account/freeze');
    expect(init.method).toBe('POST');
    expect(init.mode).toBe('cors');
    expect(init.credentials).toBe('omit');
    expect(init.referrerPolicy).toBe('no-referrer');
    expect(init.headers).toEqual({ 'content-type': 'text/plain;charset=UTF-8' });
    expect(init.body).toBe(JSON.stringify({ token }));
  });
});
