import { describe, expect, it, vi } from "vitest";

import { isMailboxRevokeUnconfirmed } from "../mailboxConnect";
import { MAILBOX_TOKEN_ROW, memoryKeyStore, sealMailboxToken } from "../mailboxToken";
import type { V2Handle } from "../session";
import { disconnectMailboxAccount } from "./runtime";
import { MAILBOX_STATE_ROW, readMailboxState, writeMailboxState } from "./state";

const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const REFRESH_TOKEN = "1//0eXaMpLe-refresh-token_9f83aa2c4b7e1d6f0a2b3c4d5e6f7a8b9c0d1e2f";

function fakeHandle(): V2Handle {
  return {
    client: {
      get sessionToken(): string | null {
        return "session-token";
      },
      get server(): string {
        return "";
      },
    },
  } as unknown as V2Handle;
}

async function freshDek(): Promise<CryptoKey> {
  return crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

/** A fetch double answering the revoke route with one status, and nothing else. */
function revokeAnswering(httpStatus: number): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const path = String(input);
    if (path.endsWith("/api/v1/mailbox/revoke") && init?.method === "POST") {
      return new Response(httpStatus === 204 ? null : JSON.stringify({ error: "unavailable" }), {
        status: httpStatus,
        headers: { "content-type": "application/json" },
      });
    }
    throw new Error(`unexpected call: ${init?.method ?? "GET"} ${path}`);
  }) as unknown as typeof fetch;
}

describe("disconnectMailboxAccount", () => {
  it("sweeps the sibling STATE row — the connected-email cache — not only the token", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    // A connected mailbox: a token row and a state row carrying the client-held
    // address and a checkpoint.
    backing.set(MAILBOX_TOKEN_ROW, { iv: new Uint8Array(12), sealed: new Uint8Array(8) });
    await writeMailboxState(
      { historyId: "h1", backfillDays: 30, lastCycleAt: "2026-08-12T10:00:00.000Z", unreadable: { count: 2, recent: [] }, connectedEmail: "burner@gmail.com" },
      store,
    );

    const deleteGrant = vi.fn(async () => undefined);
    // dek null: a non-holder (or keys-unavailable) disconnect still sweeps everything local.
    await disconnectMailboxAccount({ handle: fakeHandle(), dek: null, accountId: null, store, deleteGrant });

    // Both rows gone.
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(backing.has(MAILBOX_STATE_ROW)).toBe(false);
    // And a fresh read carries no connected email or checkpoint.
    const after = await readMailboxState(store);
    expect(after.connectedEmail ?? null).toBeNull();
    expect(after.historyId).toBeNull();
    expect(after.unreadable.count).toBe(0);
    expect(deleteGrant).toHaveBeenCalledTimes(1);
  });

  it("deletes the grant last, after the local sweep", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    await writeMailboxState(
      { historyId: "h1", backfillDays: 30, lastCycleAt: null, unreadable: { count: 0, recent: [] }, connectedEmail: "x@gmail.com" },
      store,
    );
    // The grant delete observes a state row already swept — proving order.
    let stateRowAtGrantDelete: unknown = "unseen";
    const deleteGrant = vi.fn(async () => {
      stateRowAtGrantDelete = backing.get(MAILBOX_STATE_ROW);
    });
    await disconnectMailboxAccount({ handle: fakeHandle(), dek: null, accountId: null, store, deleteGrant });
    expect(stateRowAtGrantDelete).toBeUndefined();
  });

  /**
   * The revoke is the one step that needs Google reachable, and it is NOT the
   * step that clears what we control. A 503 used to propagate out of
   * `disconnectMailbox` before the state sweep and the grant delete ever ran,
   * leaving the burner address and the checkpoint in cleartext IndexedDB and the
   * grant row alive — the user asked to disconnect and got neither.
   */
  it("a revoke that fails on infrastructure still sweeps local state and deletes the grant", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);
    const state = await readMailboxState(store);
    await writeMailboxState({ ...state, historyId: "h1", connectedEmail: "burner@gmail.com" }, store);

    const deleteGrant = vi.fn(async () => undefined);
    const err = await disconnectMailboxAccount({
      handle: fakeHandle(),
      dek,
      accountId: ACCOUNT,
      store,
      deleteGrant,
      fetch: revokeAnswering(503),
    }).catch((e: unknown) => e);

    // Everything local is gone, and the account fact every device reads is gone.
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(backing.has(MAILBOX_STATE_ROW)).toBe(false);
    expect((await readMailboxState(store)).connectedEmail ?? null).toBeNull();
    expect(deleteGrant).toHaveBeenCalledTimes(1);
    // And the caller can tell the Google-side revocation did not happen.
    expect(isMailboxRevokeUnconfirmed(err)).toBe(true);
    expect(String((err as Error).message)).toContain("myaccount.google.com/permissions");
    expect(String((err as Error).message)).not.toContain(REFRESH_TOKEN);
  });

  it("a 403 revoke stays a success — the grant is already gone, so there is nothing to revoke", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);

    const deleteGrant = vi.fn(async () => undefined);
    await expect(
      disconnectMailboxAccount({
        handle: fakeHandle(),
        dek,
        accountId: ACCOUNT,
        store,
        deleteGrant,
        fetch: revokeAnswering(403),
      }),
    ).resolves.toBeUndefined();
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(backing.has(MAILBOX_STATE_ROW)).toBe(false);
    expect(deleteGrant).toHaveBeenCalledTimes(1);
  });

  it("a revoke that succeeds resolves, and never reports an unconfirmed revocation", async () => {
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    const dek = await freshDek();
    await sealMailboxToken(dek, ACCOUNT, REFRESH_TOKEN, store);

    const deleteGrant = vi.fn(async () => undefined);
    await expect(
      disconnectMailboxAccount({
        handle: fakeHandle(),
        dek,
        accountId: ACCOUNT,
        store,
        deleteGrant,
        fetch: revokeAnswering(204),
      }),
    ).resolves.toBeUndefined();
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(deleteGrant).toHaveBeenCalledTimes(1);
  });
});
