/**
 * The Gmail mailbox connect ceremony, client half (spec §2.1, Task 9).
 *
 * What this suite is really guarding, in the order the risk sits:
 *
 *   - **The ceremony never reports a connection it cannot use.** The whole
 *     point of the ceremony is to land a SEALED refresh token on this device.
 *     Every path that ends without one must reject, and each rejection carries
 *     the kind whose remedy is honest — including the popup-closed fallback,
 *     where a grant visible at the broker proves the consent happened but
 *     proves nothing at all about this device holding a token.
 *   - **The Task 8 I-1 custody contract.** `openMailboxToken` returns `null`
 *     for no row and THROWS on a present-but-unopenable one (the shared-browser
 *     account-switch residual). Both mean "no usable token"; the throw
 *     additionally means "sweep the residual first". Never a banner, never
 *     "connected".
 *   - **Carry-forward A.** The callback page scrubs the single-use claim code
 *     out of its URL. The real `web/public/mailbox-callback.js` is executed
 *     here, not a copy of it, so the assertion cannot drift from the shipped
 *     asset.
 *   - **No secret in any message.** A thrown error is a log line somewhere;
 *     neither the refresh token nor the claim code may be in one.
 *
 * The stores are injected everywhere (`memoryKeyStore`): jsdom's IndexedDB is
 * absent, and `mailboxToken.ts`'s default silently falls back to a per-call
 * memory store, which would make a delete-then-read assertion pass for the
 * wrong reason.
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { beforeEach, describe, expect, test } from "vitest";
import { webPlatform } from "@ledger/client/platform.web";

import {
  connectMailbox,
  disconnectMailbox,
  isMailboxConnectAbandoned,
  isMailboxError,
  isMailboxReconnectRequired,
  MAILBOX_CHANNEL,
  mailboxConfigured,
  mailboxConfiguredStrict,
  mailboxConnected,
  type MailboxBroadcast,
  type MailboxCeremonyDeps,
  mintAccessToken,
  type PopupHandle,
} from "./mailboxConnect";
import {
  MAILBOX_TOKEN_ROW,
  memoryKeyStore,
  openMailboxToken,
  sealMailboxToken,
  type KeyStore,
} from "./mailboxToken";
import { MAILBOX_STATE_ROW, readMailboxState, writeMailboxState } from "./mailbox/state";
import { type V2Handle } from "./session";

const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const OTHER_ACCOUNT = "22222222-2222-4222-8222-222222222222";
const REFRESH_TOKEN = "1//0eXaMpLe-refresh-token_9f83aa2c4b7e1d6f0a2b3c4d5e6f7a8b9c0d1e2f";
const CLAIM_CODE = "cLaImC0de-6f0a2b3c4d5e6f7a8b9c0d1e";
const BURNER = "ledger.beta.7f3a@example.com";

async function freshDek(): Promise<CryptoKey> {
  return crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

/**
 * Seeds the unsealed sibling STATE row a connected mailbox leaves in IndexedDB:
 * the burner address, the historyId checkpoint and the message-id ring. Written
 * through `writeMailboxState` rather than as a literal, so a field added to
 * `MailboxState` cannot make these residue tests seed a shape the reader
 * discards (a discarded row would leave nothing to sweep and the test could not
 * fail).
 */
async function seedMailboxState(store: KeyStore): Promise<void> {
  const state = await readMailboxState(store);
  await writeMailboxState({ ...state, historyId: "history-1", connectedEmail: BURNER }, store);
}

/** The only two things `mailboxConnect` reads off a handle. */
function fakeHandle(opts: { sessionToken?: string | null; server?: () => string } = {}): V2Handle {
  const sessionToken = opts.sessionToken === undefined ? "session-token" : opts.sessionToken;
  const getServer = opts.server ?? ((): string => "");
  return {
    client: {
      get sessionToken(): string | null {
        return sessionToken;
      },
      get server(): string {
        return getServer();
      },
    },
  } as unknown as V2Handle;
}

// ---------------------------------------------------------------------------
// A routed fetch double
// ---------------------------------------------------------------------------

type Route = (body: unknown) => { status: number; json?: unknown; text?: string };

interface Recorder {
  fetch: typeof fetch;
  /** Every call, as `"POST /api/v1/mailbox/token"`, in order. */
  calls: string[];
  /** The decoded JSON bodies, keyed by route. */
  bodies: Map<string, unknown>;
}

function router(routes: Record<string, Route>): Recorder {
  const calls: string[] = [];
  const bodies = new Map<string, unknown>();
  const doFetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const path = String(input);
    const key = `${init?.method ?? "GET"} ${path}`;
    calls.push(key);
    const body = typeof init?.body === "string" ? (JSON.parse(init.body) as unknown) : undefined;
    if (body !== undefined) bodies.set(key, body);
    const route = routes[key];
    if (route === undefined) throw new Error(`unrouted request: ${key}`);
    const out = route(body);
    // 204/205/304 are null-body statuses: `new Response("", {status: 204})`
    // throws, so a bodyless answer must really be bodyless.
    const bodyless = out.status === 204 || out.status === 205 || out.status === 304;
    const text = bodyless ? null : (out.text ?? (out.json === undefined ? "" : JSON.stringify(out.json)));
    return new Response(text, { status: out.status, headers: { "Content-Type": "application/json" } });
  };
  return { fetch: doFetch as unknown as typeof fetch, calls, bodies };
}

const ok = (json: unknown): Route => () => ({ status: 200, json });

/**
 * Answers each successive call to one route differently, so a test can say "no
 * grant before the window opened, a grant after it closed" — the before/after
 * pair the unfinished-connect labels are proved from. The last entry repeats.
 */
function sequence(...steps: Route[]): Route {
  let i = 0;
  return (body) => {
    const step = steps[Math.min(i, steps.length - 1)];
    i += 1;
    if (step === undefined) throw new Error("empty sequence");
    return step(body);
  };
}

const GRANT_ACTIVE = { provider: "gmail", status: "active", created_at: "2026-08-12T00:00:00Z" };
const noContent = (): Route => () => ({ status: 204 });
const status = (code: number, error?: string): Route => () => ({
  status: code,
  json: error === undefined ? {} : { error, detail: "" },
});

// ---------------------------------------------------------------------------
// A BroadcastChannel double, and a popup double
// ---------------------------------------------------------------------------

class FakeBus {
  private readonly open: { onmessage: ((e: MessageEvent) => void) | null }[] = [];

  make(): MailboxBroadcast {
    const channel = {
      onmessage: null as ((e: MessageEvent) => void) | null,
      close: () => {
        const i = this.open.indexOf(channel);
        if (i >= 0) this.open.splice(i, 1);
      },
    };
    this.open.push(channel);
    return channel;
  }

  /** How many channels are open — the ceremony must not leak one. */
  get openCount(): number {
    return this.open.length;
  }

  post(data: unknown): void {
    for (const c of [...this.open]) c.onmessage?.({ data } as MessageEvent);
  }
}

/**
 * A popup the test can close, and that records how it was driven. `null` from
 * `open` is the popup-blocked case. `navigated` is every consent URL it was
 * pointed at; `closeCount` is how many times begin-failure closed it.
 */
function fakePopup(closed = false): PopupHandle & { closed: boolean; navigated: string[]; closeCount: number } {
  const popup = {
    closed,
    navigated: [] as string[],
    closeCount: 0,
    navigate(url: string): void {
      popup.navigated.push(url);
    },
    close(): void {
      popup.closeCount += 1;
    },
  };
  return popup;
}

/** A sleep that yields a real macrotask, so a polling loop cannot starve the test. */
const instantSleep = (): Promise<void> => new Promise<void>((r) => setTimeout(r, 0));

function idToken(claims: unknown): string {
  const b64 = (s: string): string =>
    webPlatform.toBase64(webPlatform.utf8Encode(s)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `${b64(JSON.stringify({ alg: "RS256" }))}.${b64(JSON.stringify(claims))}.not-a-signature`;
}

/** The deps every ceremony test shares: fake channel, fake sleep, injected store. */
function ceremonyDeps(over: Partial<MailboxCeremonyDeps> & { bus?: FakeBus } = {}): MailboxCeremonyDeps {
  const bus = over.bus ?? new FakeBus();
  return {
    channel: () => bus.make(),
    sleep: instantSleep,
    pollIntervalMs: 1,
    ...over,
  };
}

// ---------------------------------------------------------------------------

describe("MAILBOX_CHANNEL", () => {
  // A wire identity: the app and the popup page are two separate programs that
  // agree only on this string, and `mailbox-callback.js` is a `public/` asset
  // copied verbatim, so it cannot import the constant. Protected once shipped
  // (CLAUDE.md) — this is the only thing that keeps the two spellings equal.
  test("is the protected channel name, spelled identically in the shipped callback page", () => {
    expect(MAILBOX_CHANNEL).toBe("ledger-v2-mailbox-connect");
    expect(callbackSource()).toContain(`"${MAILBOX_CHANNEL}"`);
  });
});

describe("connectMailbox", () => {
  let bus: FakeBus;
  let store: KeyStore;
  let backing: Map<string, unknown>;

  beforeEach(() => {
    bus = new FakeBus();
    backing = new Map<string, unknown>();
    store = memoryKeyStore(backing);
  });

  const connectRoutes = (over: Record<string, Route> = {}): Record<string, Route> => ({
    "POST /api/v1/mailbox/oauth/begin": ok({ auth_url: "https://accounts.google.com/o/oauth2/v2/auth?state=s" }),
    "POST /api/v1/mailbox/oauth/claim": ok({
      refresh_token: REFRESH_TOKEN,
      access_token: "ya29.access",
      id_token: idToken({ email: BURNER, email_verified: true }),
    }),
    "GET /api/v1/mailbox/grant": status(404, "no_grant"),
    ...over,
  });

  test("resolves with the burner address by polling the claim endpoint, and seals the token", async () => {
    const dek = await freshDek();
    const net = router(connectRoutes());
    const popup = fakePopup();

    const opened: string[] = [];
    const p = connectMailbox(fakeHandle(), dek, ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: (url) => {
        opened.push(url);
        return popup;
      },
    });

    await expect(p).resolves.toEqual({ email: BURNER });
    // The window opens at about:blank (synchronously, inside the gesture) and is
    // then navigated to the consent URL.
    expect(opened).toEqual(["about:blank"]);
    expect(popup.navigated).toEqual(["https://accounts.google.com/o/oauth2/v2/auth?state=s"]);
    // The opener collects its OWN ceremony's tokens by session — the claim POST
    // carries no code, so it works even when the popup could not hand one back.
    expect(net.bodies.get("POST /api/v1/mailbox/oauth/claim")).toEqual({});
    // The point of the whole ceremony: a token this device can actually open.
    expect(await openMailboxToken(dek, ACCOUNT, store)).toBe(REFRESH_TOKEN);
  });

  // The popup opens SYNCHRONOUSLY, before any network await — WebKit blocks a
  // popup opened after an await, so this is the whole fix. A mutation that moves
  // the open back after begin's await turns `openedAtCallCount` non-zero.
  test("opens the popup synchronously, before the begin fetch has even been issued", async () => {
    const net = router(connectRoutes());
    let openedAtCallCount = -1;
    const p = connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => {
        openedAtCallCount = net.calls.length;
        return fakePopup();
      },
    });
    // Opened before connectMailbox awaited anything: no fetch had run yet.
    expect(openedAtCallCount).toBe(0);
    await p;
  });

  // Exactly one grant read on the happy path: the before-snapshot, taken after
  // the window opens (at about:blank) but before it is NAVIGATED to consent —
  // the only window in which it still proves what the labels need and cannot yet
  // have been changed by a consent. The tokens themselves are collected by
  // polling the claim endpoint (by session), not by a message from the popup.
  test("reads the grant once before navigating to consent, then collects tokens by poll", async () => {
    const net = router(connectRoutes());
    let callsAtOpen: string[] = [];
    let callsAtNavigate: string[] = [];
    const p = connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => {
        callsAtOpen = [...net.calls];
        return {
          closed: false,
          navigate: (): void => {
            callsAtNavigate = [...net.calls];
          },
          close: (): void => undefined,
        };
      },
    });
    await p;
    expect(net.calls.filter((c) => c === "GET /api/v1/mailbox/grant")).toHaveLength(1);
    // Nothing was fetched before the window opened…
    expect(callsAtOpen).toEqual([]);
    // …and the grant had been read by the time it was navigated to consent.
    expect(callsAtNavigate).toContain("GET /api/v1/mailbox/grant");
    // The tokens arrived over the claim poll, never a window message.
    expect(net.calls).toContain("POST /api/v1/mailbox/oauth/claim");
  });

  test("a cancelled consent (no claim ever minted) is a typed cancellation, and seals nothing", async () => {
    // The callback mints no claim on a cancelled consent, so the poll only ever
    // sees 204 and the closed popup ends the wait — no window message involved.
    const net = router(connectRoutes({ "POST /api/v1/mailbox/oauth/claim": noContent() }));
    const p = connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => fakePopup(true),
    });

    await expect(p).rejects.toMatchObject({ mailboxKind: "cancelled" });
    expect(backing.size).toBe(0);
  });

  /**
   * The label-to-meaning table, pinned row by row.
   *
   * These four cases are the whole reason `connectMailbox` snapshots the grant
   * before opening the window. The server's ONLY `Grants.Upsert` is inside the
   * claim POST (`internal/api/mailbox.go`), so a grant row exists only because
   * some client already made a successful claim — which means the after-reading
   * alone cannot tell "this ceremony's consent completed" from "this account was
   * already connected before we started". A first draft of this file keyed on
   * the after-reading alone and had the two labels effectively INVERTED: a user
   * cancelling a reconnect was told "the mailbox was authorised", which nothing
   * in that flow had done.
   *
   * Each case therefore asserts the kind AND that the message does not overclaim
   * — the sentence Tasks 14/15 will write is the thing under test, not the
   * enum spelling.
   */
  const closedPopupCase = async (grant: Route): Promise<unknown> => {
    // The claim never becomes available (204 forever): the ceremony did not
    // complete, and the closed popup ends the wait on the before/after label.
    const net = router(
      connectRoutes({ "GET /api/v1/mailbox/grant": grant, "POST /api/v1/mailbox/oauth/claim": noContent() }),
    );
    return connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => fakePopup(true),
    }).catch((e: unknown) => e);
  };

  test("no grant before, none after: cancelled, and it claims nothing was authorised", async () => {
    const err = await closedPopupCase(status(404, "no_grant"));
    expect((err as { mailboxKind: string }).mailboxKind).toBe("cancelled");
    expect((err as Error).message).not.toMatch(/authoris|already connected/i);
    expect(backing.size).toBe(0);
  });

  /**
   * No grant before, a grant after: the ONE case in which "the mailbox was
   * authorised" is provable — a claim POST is the only thing that can have
   * created that row, and it was not made from here (another tab of this origin
   * heard the broadcast, or the popup died between the claim and being heard).
   * Still a failure: this device holds nothing.
   */
  test("no grant before, a grant after: claim_lost — the only provable authorisation", async () => {
    const dek = await freshDek();
    const net = router(
      connectRoutes({
        "GET /api/v1/mailbox/grant": sequence(status(404, "no_grant"), ok(GRANT_ACTIVE)),
        "POST /api/v1/mailbox/oauth/claim": noContent(),
      }),
    );
    const err = await connectMailbox(fakeHandle(), dek, ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => fakePopup(true),
    }).catch((e: unknown) => e);

    expect(isMailboxError(err)).toBe(true);
    expect((err as { mailboxKind: string }).mailboxKind).toBe("claim_lost");
    // This device polled (and got 204s) but sealed nothing: never a success.
    expect(await openMailboxToken(dek, ACCOUNT, store)).toBeNull();
  });

  test("a grant already there: reconnect_incomplete, and it never claims a fresh authorisation", async () => {
    const err = await closedPopupCase(ok(GRANT_ACTIVE));
    expect((err as { mailboxKind: string }).mailboxKind).toBe("reconnect_incomplete");
    expect((err as Error).message).not.toMatch(/authoris/i);
    // The kind the fetch lane stops on is a different one; do not conflate them.
    expect(isMailboxReconnectRequired(err)).toBe(false);
    expect(isMailboxConnectAbandoned(err)).toBe(true);
    expect(backing.size).toBe(0);
  });

  // Prove nothing, claim nothing. If the before-snapshot could not be read, an
  // after-reading showing a grant is not evidence of anything.
  test("an unreadable before-snapshot falls back to the kind that claims least", async () => {
    const err = await closedPopupCase(sequence(status(503, "unavailable"), ok(GRANT_ACTIVE)));
    expect((err as { mailboxKind: string }).mailboxKind).toBe("cancelled");
    expect((err as Error).message).not.toMatch(/authoris|already connected/i);
  });

  test("a cancellation during a reconnect keeps the reconnect wording", async () => {
    const err = await closedPopupCase(ok(GRANT_ACTIVE));
    // A user who cancels a reconnect has not lost the mailbox they had, and the
    // copy must not read as though they have.
    expect((err as { mailboxKind: string }).mailboxKind).toBe("reconnect_incomplete");
    expect(isMailboxConnectAbandoned(err)).toBe(true);
  });

  test("a blocked popup is its own kind, and does not wait for a poll to time out", async () => {
    const net = router(connectRoutes());
    const p = connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => null,
    });
    await expect(p).rejects.toMatchObject({ mailboxKind: "popup_blocked" });
    // The open is now the FIRST thing the ceremony does, so a blocked popup
    // fails before begin or the grant read is ever issued — nothing is fetched
    // at all, and nothing is polled.
    expect(net.calls).toEqual([]);
  });

  test("a popup left open forever ends at the deadline instead of hanging", async () => {
    // The claim never becomes available and the window never closes: only the
    // deadline can end the wait.
    const net = router(connectRoutes({ "POST /api/v1/mailbox/oauth/claim": noContent() }));
    const p = connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => fakePopup(),
      pollIntervalMs: 100,
      deadlineMs: 500,
    });
    await expect(p).rejects.toMatchObject({ mailboxKind: "cancelled" });
  });

  test("a refused begin closes the blank window it had already opened, and never navigates it", async () => {
    // The popup opens first now (the WebKit fix), so a begin failure must clean
    // it up: the window opened, was never navigated to consent, and was closed.
    const popup = fakePopup();
    const net = router(connectRoutes({ "POST /api/v1/mailbox/oauth/begin": status(503, "unavailable") }));
    await expect(
      connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
        ...ceremonyDeps({ bus }),
        fetch: net.fetch,
        store,
        open: () => popup,
      }),
    ).rejects.toMatchObject({ mailboxKind: "unavailable" });
    expect(popup.navigated).toEqual([]);
    expect(popup.closeCount).toBe(1);
  });

  test("a rate-limited begin is its own kind", async () => {
    const net = router(connectRoutes({ "POST /api/v1/mailbox/oauth/begin": status(429, "rate_limited") }));
    await expect(
      connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
        ...ceremonyDeps({ bus }),
        fetch: net.fetch,
        store,
        open: () => fakePopup(),
      }),
    ).rejects.toMatchObject({ mailboxKind: "rate_limited" });
  });

  test("an id_token that does not decode still returns a connected mailbox, with no address", async () => {
    const dek = await freshDek();
    const net = router(
      connectRoutes({
        "POST /api/v1/mailbox/oauth/claim": ok({ refresh_token: REFRESH_TOKEN, id_token: "not.a.jwt" }),
      }),
    );
    const p = connectMailbox(fakeHandle(), dek, ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => fakePopup(),
    });
    // The token is sealed and the grant is recorded: failing the whole ceremony
    // over a cosmetic label would send a connected user to reconnect.
    await expect(p).resolves.toEqual({ email: "" });
    expect(await openMailboxToken(dek, ACCOUNT, store)).toBe(REFRESH_TOKEN);
  });

  test("no secret reaches an error message", async () => {
    const net = router(
      connectRoutes({ "POST /api/v1/mailbox/oauth/claim": status(403, "mailbox_refused") }),
    );
    const p = connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => fakePopup(),
    });
    const err = await p.catch((e: unknown) => e);
    expect(String((err as Error).message)).not.toContain(CLAIM_CODE);
    expect(String((err as Error).message)).not.toContain(REFRESH_TOKEN);
  });

  test("a device with no session says so, and does not call it offline", async () => {
    const net = router(connectRoutes());
    await expect(
      connectMailbox(fakeHandle({ sessionToken: null }), await freshDek(), ACCOUNT, {
        ...ceremonyDeps({ bus }),
        fetch: net.fetch,
        store,
        open: () => fakePopup(),
      }),
    ).rejects.toMatchObject({ mailboxKind: "unavailable" });
    // The popup opens first (the WebKit fix), but no session means no fetch is
    // ever issued — the ceremony fails in the try and closes the window.
    expect(net.calls).toEqual([]);
  });

  // `Client.server` throws a ConfigError when the build has no server and there
  // is no ambient origin. `client.ts` documents the day this cost: read inside
  // the try around `fetch`, a misconfiguration is re-thrown as "offline" and the
  // UI tells a perfectly connected user to try again later.
  test("an unconfigured server is not reported as offline", async () => {
    const net = router(connectRoutes());
    const boom = (): string => {
      throw new Error("no server configured: pass --server");
    };
    const err = await connectMailbox(fakeHandle({ server: boom }), await freshDek(), ACCOUNT, {
      ...ceremonyDeps({ bus }),
      fetch: net.fetch,
      store,
      open: () => fakePopup(),
    }).catch((e: unknown) => e);
    expect(isMailboxError(err)).toBe(true);
    expect((err as { mailboxKind: string }).mailboxKind).not.toBe("offline");
  });

  test("a transport failure is offline", async () => {
    const dead = (): Promise<Response> => Promise.reject(new TypeError("Failed to fetch"));
    await expect(
      connectMailbox(fakeHandle(), await freshDek(), ACCOUNT, {
        ...ceremonyDeps({ bus }),
        fetch: dead as unknown as typeof fetch,
        store,
        open: () => fakePopup(),
      }),
    ).rejects.toMatchObject({ mailboxKind: "offline" });
  });
});

describe("mintAccessToken", () => {
  let store: KeyStore;
  let backing: Map<string, unknown>;

  beforeEach(() => {
    backing = new Map<string, unknown>();
    store = memoryKeyStore(backing);
  });

  test("trades the sealed refresh token for an access token", async () => {
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    const net = router({ "POST /api/v1/mailbox/token": ok({ access_token: "ya29.minted", expires_in: 3599 }) });

    await expect(mintAccessToken(fakeHandle(), dek, ACCOUNT, { fetch: net.fetch, store })).resolves.toBe("ya29.minted");
    expect(net.bodies.get("POST /api/v1/mailbox/token")).toEqual({ refresh_token: REFRESH_TOKEN });
  });

  test("no token row at all is a reconnect, not an error", async () => {
    const net = router({});
    const err = await mintAccessToken(fakeHandle(), await freshDek(), ACCOUNT, {
      fetch: net.fetch,
      store,
    }).catch((e: unknown) => e);
    expect(isMailboxReconnectRequired(err)).toBe(true);
    expect(net.calls).toEqual([]);
  });

  /**
   * Task 8, I-1. The shared-browser account-switch residual: account A's sealed
   * token row survives account B signing in, and B's `openMailboxToken` THROWS
   * on it. The contract says treat that as "no usable token — reconnect, and
   * sweep the row", never as an error banner and never as connected.
   */
  test("a residual row sealed for another account routes to reconnect AND is swept", async () => {
    await sealMailboxToken(await freshDek(), OTHER_ACCOUNT, REFRESH_TOKEN, store);
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(true);
    backing.set("account", { anAccountRow: true });

    const net = router({});
    const err = await mintAccessToken(fakeHandle(), await freshDek(), ACCOUNT, {
      fetch: net.fetch,
      store,
    }).catch((e: unknown) => e);

    expect(isMailboxReconnectRequired(err)).toBe(true);
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    // The sweep is the token row and only the token row.
    expect(backing.has("account")).toBe(true);
    // Nothing was asked of the broker with a token that cannot be read.
    expect(net.calls).toEqual([]);
  });

  test("the generic refusal plus a reconnect_required grant is a reconnect, and sweeps the dead token", async () => {
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    const net = router({
      "POST /api/v1/mailbox/token": status(403, "mailbox_refused"),
      "GET /api/v1/mailbox/grant": ok({ provider: "gmail", status: "reconnect_required" }),
    });

    const err = await mintAccessToken(fakeHandle(), dek, ACCOUNT, { fetch: net.fetch, store }).catch(
      (e: unknown) => e,
    );
    expect(isMailboxReconnectRequired(err)).toBe(true);
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(String((err as Error).message)).not.toContain(REFRESH_TOKEN);
  });

  test("the generic refusal with the grant gone (404 no_grant) is also a reconnect", async () => {
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    const net = router({
      "POST /api/v1/mailbox/token": status(403, "mailbox_refused"),
      "GET /api/v1/mailbox/grant": status(404, "no_grant"),
    });
    await expect(mintAccessToken(fakeHandle(), dek, ACCOUNT, { fetch: net.fetch, store })).rejects.toMatchObject({
      mailboxKind: "reconnect_required",
    });
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
  });

  // Sweeping on a maybe would turn one 503 into a mandatory reconnect ceremony
  // for a mailbox that is perfectly healthy.
  test("a refusal whose grant state cannot be read KEEPS the token", async () => {
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    const net = router({
      "POST /api/v1/mailbox/token": status(403, "mailbox_refused"),
      "GET /api/v1/mailbox/grant": status(503, "unavailable"),
    });

    const err = await mintAccessToken(fakeHandle(), dek, ACCOUNT, { fetch: net.fetch, store }).catch(
      (e: unknown) => e,
    );
    expect(isMailboxReconnectRequired(err)).toBe(false);
    expect((err as { mailboxKind: string }).mailboxKind).toBe("unavailable");
    expect(await openMailboxToken(dek, ACCOUNT, store)).toBe(REFRESH_TOKEN);
  });

  /**
   * The residue gap: sweeping the sealed token alone leaves the UNSEALED state
   * row — burner address, historyId, message-id ring — behind in cleartext. On a
   * shared browser that row is another account's mailbox address.
   */
  test("the residual-row sweep takes the unsealed STATE row with it", async () => {
    await sealMailboxToken(await freshDek(), OTHER_ACCOUNT, REFRESH_TOKEN, store);
    await seedMailboxState(store);
    expect(backing.has(MAILBOX_STATE_ROW)).toBe(true);
    backing.set("account", { anAccountRow: true });

    const net = router({});
    const err = await mintAccessToken(fakeHandle(), await freshDek(), ACCOUNT, {
      fetch: net.fetch,
      store,
    }).catch((e: unknown) => e);

    expect(isMailboxReconnectRequired(err)).toBe(true);
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(backing.has(MAILBOX_STATE_ROW)).toBe(false);
    // No connected address survives the sweep.
    expect((await readMailboxState(store)).connectedEmail ?? null).toBeNull();
    // Still only the mailbox rows: the account row is not ours to touch.
    expect(backing.has("account")).toBe(true);
  });

  test("the dead-token sweep after a generic refusal takes the STATE row too", async () => {
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    await seedMailboxState(store);
    const net = router({
      "POST /api/v1/mailbox/token": status(403, "mailbox_refused"),
      "GET /api/v1/mailbox/grant": ok({ provider: "gmail", status: "reconnect_required" }),
    });

    await expect(mintAccessToken(fakeHandle(), dek, ACCOUNT, { fetch: net.fetch, store })).rejects.toMatchObject({
      mailboxKind: "reconnect_required",
    });
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(backing.has(MAILBOX_STATE_ROW)).toBe(false);
  });

  // The counterweight to the two sweeps above: a token kept is a connection that
  // still works, and its checkpoint must survive with it or the next cycle
  // re-reads the whole backfill window.
  test("a kept token keeps its STATE row", async () => {
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    await seedMailboxState(store);
    const net = router({ "POST /api/v1/mailbox/token": status(503, "unavailable") });

    await expect(mintAccessToken(fakeHandle(), dek, ACCOUNT, { fetch: net.fetch, store })).rejects.toMatchObject({
      mailboxKind: "unavailable",
    });
    expect((await readMailboxState(store)).historyId).toBe("history-1");
  });

  test("a 503 from the token route is unavailable and keeps the token", async () => {
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    const net = router({ "POST /api/v1/mailbox/token": status(503, "unavailable") });
    await expect(mintAccessToken(fakeHandle(), dek, ACCOUNT, { fetch: net.fetch, store })).rejects.toMatchObject({
      mailboxKind: "unavailable",
    });
    expect(await openMailboxToken(dek, ACCOUNT, store)).toBe(REFRESH_TOKEN);
  });
});

describe("disconnectMailbox", () => {
  test("revokes at the broker and then forgets the token, leaving the account row", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    await sealMailboxToken(await freshDek(), ACCOUNT, REFRESH_TOKEN, store);
    backing.set("account", { anAccountRow: true });

    const net = router({ "POST /api/v1/mailbox/revoke": noContent() });
    await disconnectMailbox(fakeHandle(), REFRESH_TOKEN, { fetch: net.fetch, store });

    expect(net.bodies.get("POST /api/v1/mailbox/revoke")).toEqual({ refresh_token: REFRESH_TOKEN });
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(backing.has("account")).toBe(true);
  });

  test("forgetting the token forgets the unsealed STATE row with it", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    await sealMailboxToken(await freshDek(), ACCOUNT, REFRESH_TOKEN, store);
    await seedMailboxState(store);

    const net = router({ "POST /api/v1/mailbox/revoke": noContent() });
    await disconnectMailbox(fakeHandle(), REFRESH_TOKEN, { fetch: net.fetch, store });

    expect(backing.has(MAILBOX_STATE_ROW)).toBe(false);
    expect((await readMailboxState(store)).connectedEmail ?? null).toBeNull();
  });

  test("a generic refusal still forgets the token — a dead token is nothing to keep", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    await sealMailboxToken(await freshDek(), ACCOUNT, REFRESH_TOKEN, store);
    const net = router({ "POST /api/v1/mailbox/revoke": status(403, "mailbox_refused") });

    await disconnectMailbox(fakeHandle(), REFRESH_TOKEN, { fetch: net.fetch, store });
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
  });

  // The grant may still be live at Google and this token is the only thing that
  // can reach it. Forgetting it here would strand a live grant forever.
  test("a 503 keeps the token so the revoke can be retried", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    const net = router({ "POST /api/v1/mailbox/revoke": status(503, "unavailable") });

    await expect(disconnectMailbox(fakeHandle(), REFRESH_TOKEN, { fetch: net.fetch, store })).rejects.toMatchObject({
      mailboxKind: "unavailable",
    });
    expect(await openMailboxToken(dek, ACCOUNT, store)).toBe(REFRESH_TOKEN);
  });
});

// ---------------------------------------------------------------------------
// The shipped popup page
// ---------------------------------------------------------------------------

/**
 * The REAL `web/public/mailbox-callback.js`, read off disk and executed with its
 * free globals shadowed by fakes.
 *
 * A copy of the script inlined here would be a test that cannot fail: the asset
 * is a `public/` file, copied verbatim into the bundle and never imported by
 * anything, so nothing else in the repo would notice it drifting.
 */
function callbackSource(): string {
  // `import.meta.url` is an http:// URL under vite's module runner, so the asset
  // is resolved from vitest's root (`web/`) instead.
  return readFileSync(resolve(process.cwd(), "public/mailbox-callback.js"), "utf8");
}

interface CallbackRun {
  posted: unknown[];
  replaced: (string | null | undefined)[];
  closed: number;
  channelsLeftOpen: number;
}

function runCallbackPage(search: string): CallbackRun {
  const posted: unknown[] = [];
  const replaced: (string | null | undefined)[] = [];
  let closed = 0;
  let channelsLeftOpen = 0;

  const location = { search, pathname: "/mailbox-callback.html", href: `/mailbox-callback.html${search}` };
  const history = {
    replaceState: (_state: unknown, _title: string, url?: string | null) => {
      replaced.push(url);
      location.search = "";
      location.href = String(url);
    },
  };
  class FakeBroadcastChannel {
    constructor(readonly name: string) {
      channelsLeftOpen++;
    }
    postMessage(data: unknown): void {
      posted.push({ name: this.name, data });
    }
    close(): void {
      channelsLeftOpen--;
    }
  }
  const close = (): void => {
    closed++;
  };

  // eslint-disable-next-line @typescript-eslint/no-implied-eval
  const run = new Function("location", "history", "BroadcastChannel", "close", "URLSearchParams", callbackSource());
  run(location, history, FakeBroadcastChannel, close, URLSearchParams);

  return { posted, replaced, closed, channelsLeftOpen };
}

describe("mailbox-callback.js (the shipped popup page)", () => {
  test("broadcasts the claim on the mailbox channel and closes", () => {
    const run = runCallbackPage(`?claim=${encodeURIComponent(CLAIM_CODE)}`);
    expect(run.posted).toEqual([{ name: MAILBOX_CHANNEL, data: { claim: CLAIM_CODE, error: null } }]);
    expect(run.closed).toBe(1);
    expect(run.channelsLeftOpen).toBe(0);
  });

  // Carry-forward A (Task 4 review). The claim code is single-use and short
  // lived, but until it is spent it is a bearer credential for one ceremony —
  // and a URL is the one place a secret is copied into session history, into a
  // Referer header and into any crash report the browser sends.
  test("scrubs the claim code out of the URL", () => {
    const run = runCallbackPage(`?claim=${encodeURIComponent(CLAIM_CODE)}`);
    expect(run.replaced).toEqual(["/mailbox-callback.html"]);
    for (const url of run.replaced) expect(String(url)).not.toContain(CLAIM_CODE);
  });

  test("broadcasts a ceremony-over error so the opener stops waiting", () => {
    const run = runCallbackPage("?error=denied");
    expect(run.posted).toEqual([{ name: MAILBOX_CHANNEL, data: { claim: null, error: "denied" } }]);
    expect(run.closed).toBe(1);
  });

  /**
   * The service worker claims every navigation for the app shell, and this page
   * is a real document rather than a client-side route — so without an explicit
   * denylist entry the popup would render the PWA, the claim would never be
   * broadcast, and every connect would die in its popup-closed fallback while
   * looking, from the outside, like a page that loaded fine.
   *
   * Asserted against the source because `sw.ts` is a service-worker entry point
   * with no importable seam; a Workbox route object cannot be constructed in
   * jsdom. It is a coarse assertion that nonetheless fails the moment the entry
   * is removed, which is the failure that matters.
   */
  test("the service worker does not swallow the callback navigation with the app shell", () => {
    const sw = readFileSync(resolve(process.cwd(), "src/sw.ts"), "utf8");
    const denylist = /denylist:\s*\[([^\]]*)\]/.exec(sw)?.[1] ?? "";
    expect(denylist).toContain("mailbox-callback");
  });

  // The whole reason this page exists is that COOP severs `window.opener`, so a
  // `postMessage` to it would be a silent no-op that only shows up as a
  // ceremony that never finishes. Comments are stripped first — the page's own
  // documentation explains the constraint and must be allowed to say the word.
  test("never reaches for window.opener", () => {
    const code = callbackSource()
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/^\s*\/\/.*$/gm, "");
    expect(code).toContain("BroadcastChannel");
    expect(code).not.toContain("opener");
  });
});

/**
 * The two grant-presence probes Tasks 14/15 read: `mailboxConnected` (the
 * milestone fact) and `mailboxConfigured` (the route-card switch). Both stand on
 * `GET /grant`, and both must fail-closed rather than guess.
 */
describe("the grant-presence probes", () => {
  test("mailboxConnected is true for a grant in any state, false for none, false on error", async () => {
    const live = router({ "GET /api/v1/mailbox/grant": ok(GRANT_ACTIVE) });
    expect(await mailboxConnected(fakeHandle(), { fetch: live.fetch })).toBe(true);

    // A reconnect_required grant is still a mailbox the user connected.
    const dead = router({ "GET /api/v1/mailbox/grant": ok({ provider: "gmail", status: "reconnect_required" }) });
    expect(await mailboxConnected(fakeHandle(), { fetch: dead.fetch })).toBe(true);

    const none = router({ "GET /api/v1/mailbox/grant": status(404, "no_grant") });
    expect(await mailboxConnected(fakeHandle(), { fetch: none.fetch })).toBe(false);

    // Unreadable (503) reads as not-connected — the safe direction (walk the
    // mail stage rather than skip it on a stale belief).
    const down = router({ "GET /api/v1/mailbox/grant": status(503, "unavailable") });
    expect(await mailboxConnected(fakeHandle(), { fetch: down.fetch })).toBe(false);
  });

  test("mailboxConfigured tells an unmounted route from a mounted no_grant answer", async () => {
    // Mounted, no grant: 404 carrying the no_grant code ⇒ configured.
    const mounted = router({ "GET /api/v1/mailbox/grant": status(404, "no_grant") });
    expect(await mailboxConfigured(fakeHandle(), { fetch: mounted.fetch })).toBe(true);

    // A live grant is obviously configured.
    const live = router({ "GET /api/v1/mailbox/grant": ok(GRANT_ACTIVE) });
    expect(await mailboxConfigured(fakeHandle(), { fetch: live.fetch })).toBe(true);

    // A mounted-but-busy broker (503) is still configured.
    const busy = router({ "GET /api/v1/mailbox/grant": status(503, "unavailable") });
    expect(await mailboxConfigured(fakeHandle(), { fetch: busy.fetch })).toBe(true);

    // Unmounted: the mux's own bare 404, plain text, no error code ⇒ not configured.
    const unmounted = router({ "GET /api/v1/mailbox/grant": () => ({ status: 404, text: "404 page not found\n" }) });
    expect(await mailboxConfigured(fakeHandle(), { fetch: unmounted.fetch })).toBe(false);

    // A transport failure fails closed — no card offline.
    const offline = router({});
    const throwing = (): Promise<Response> => Promise.reject(new TypeError("network"));
    expect(await mailboxConfigured(fakeHandle(), { fetch: throwing as unknown as typeof fetch })).toBe(false);
    void offline;
  });

  test("mailboxConfiguredStrict resolves an authoritative answer and THROWS a transient one", async () => {
    // Authoritative answers resolve, exactly as `mailboxConfigured` folds them.
    const mounted = router({ "GET /api/v1/mailbox/grant": status(404, "no_grant") });
    expect(await mailboxConfiguredStrict(fakeHandle(), { fetch: mounted.fetch })).toBe(true);

    const unmounted = router({ "GET /api/v1/mailbox/grant": () => ({ status: 404, text: "404 page not found\n" }) });
    expect(await mailboxConfiguredStrict(fakeHandle(), { fetch: unmounted.fetch })).toBe(false);

    // The one difference: a transport failure is RETHROWN, not folded to false —
    // this is what lets a react-query caller retry the transient (Onboarding's
    // MailStep) instead of hiding the route card on a flaky first byte.
    const throwing = (): Promise<Response> => Promise.reject(new TypeError("network"));
    await expect(
      mailboxConfiguredStrict(fakeHandle(), { fetch: throwing as unknown as typeof fetch }),
    ).rejects.toSatisfy(isMailboxError);
  });
});
