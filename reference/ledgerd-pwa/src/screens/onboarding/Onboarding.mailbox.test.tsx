/**
 * The catch-up screen, driven through the REAL walk.
 *
 * `MailboxSetup.test.tsx` proves the sub-flow with a `runCatchUp` handed to it.
 * That is exactly what could not be trusted: the walk rendered `MailboxSetup`
 * with no runner at all, so the screen whose copy says "ledger is reading your
 * bank emails and filing them" ran nothing, showed no spinner and no counts.
 * A component test with the prop injected passes either way, so the guard has to
 * mount `Onboarding` itself and watch the runtime's catch-up be called.
 *
 * The two boundaries with a popup or a network behind them are INJECTED and
 * nothing else is: `connect` (which opens a window) and `catchUp` (which mints a
 * Google token). Everything between them is the shipped code.
 *
 * # Why props and not `vi.mock`
 *
 * This file used `vi.mock` on both modules until 2026-08-16, and the mocks never
 * took effect. Vitest runs under Bun here (`process.versions.bun`), and Bun
 * imports real source modules natively rather than through vitest's module
 * runner, so a `vi.mock` factory for a relative path is never called — silently.
 * No warning, no error: the walk simply drove the REAL `connectMailbox` into
 * jsdom's unimplemented `window.open` and stopped on the error screen, and the
 * three tests here failed for a reason that looked like a product bug.
 *
 * `vi.mock` still works for the one thing `src/test/setup.ts` uses it for, a
 * VIRTUAL module (`virtual:pwa-register/react`), because Vite resolves that at
 * transform time and there is no real file for Bun to import instead.
 *
 * So: if you need a seam in this codebase, add a prop. A mock that cannot mock
 * is this repo's first failure class — a check that cannot fail.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import type { SqlDriver } from "@ledger/client/store/driver";
import type { SecretStore } from "@ledger/client/store/store";

import { MotionProvider } from "../../app/MotionProvider";
import { projectionWith } from "../../test/projectionFixture";
import { emptyFacts, type OnboardingFacts } from "../../v2/onboarding";
import type { StoredKeys, KeyVault } from "../../v2/keys";
import type { V2Handle } from "../../v2/session";
import { Onboarding } from "./Onboarding";

/** The runtime deps the walk hands the catch-up — the whole point of this file. */
interface CaughtDeps {
  handle: V2Handle;
  dek: CryptoKey;
  accountId: string;
  writer: unknown;
  driver: unknown;
  syncToHead: () => Promise<void>;
}

const connectMailbox = vi.fn(async () => ({ email: "ledger.beta@example.com" }));
const runMailboxCatchUp = vi.fn(async (_deps: CaughtDeps) => ({
  fetched: 7,
  ops: 5,
  review: 2,
  unreadable: 0,
  setAside: 3,
}));

const DEK = {} as CryptoKey;

const vault: KeyVault = {
  read: async (): Promise<StoredKeys> => ({
    accountId: "u_1",
    ingestPub: new Uint8Array(32),
    ingestPrivSealed: new Uint8Array(64),
    ingestPrivIv: new Uint8Array(12),
    dek: DEK,
  }),
  write: async () => undefined,
  clear: async () => undefined,
};

let db: SqlDriver;

beforeEach(async () => {
  db = await projectionWith();
  connectMailbox.mockClear();
  runMailboxCatchUp.mockClear();
});

function memorySecrets(): SecretStore {
  const held = new Map<string, string>();
  return {
    get: (k) => held.get(k) ?? null,
    set: (k, v) => {
      if (v === null) held.delete(k);
      else held.set(k, v);
    },
  };
}

function handleStub(): V2Handle {
  return {
    signedIn: () => true,
    signUp: async () => {},
    signIn: async () => {},
    enrol: async () => {},
    signOut: async () => {},
    close: () => {},
    driver: db,
    client: {
      get userId() {
        return "u_1";
      },
      get sessionToken() {
        return "tok";
      },
      get pending() {
        return [];
      },
      emitMany: () => [],
      state: () => ({ txns: new Map(), homeCurrency: null }),
    },
  } as unknown as V2Handle;
}

function facts(): OnboardingFacts {
  return { ...emptyFacts(), hasSession: true, accountId: "u_1", keysReady: true, mailRoute: "mailbox" };
}

/** Walks the real mailbox sub-flow up to the catching-up screen. */
async function walkToCatchUp() {
  const handle = handleStub();
  const doFetch = vi.fn(async () => new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } }));
  const syncToHead = vi.fn(async () => undefined);
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <MotionProvider>
      <QueryClientProvider client={qc}>
        <Onboarding
          handle={handle}
          facts={facts()}
          done={vi.fn()}
          fetch={doFetch as unknown as typeof fetch}
          secrets={memorySecrets()}
          vault={vault}
          syncToHead={syncToHead}
          mailboxConfigured={async () => true}
          connect={() => connectMailbox()}
          catchUp={(deps) => runMailboxCatchUp(deps as unknown as CaughtDeps)}
        />
      </QueryClientProvider>
    </MotionProvider>,
  );

  await screen.findByTestId("mailbox-guidance");
  await waitFor(() => expect(screen.getByText("Connect with Google").closest("button")!).toBeEnabled());
  await userEvent.click(screen.getByText("Connect with Google"));
  await screen.findByTestId("mailbox-backfill");
  await userEvent.click(screen.getByText("Start catching up"));
  await screen.findByTestId("mailbox-catching-up");
  return { handle, syncToHead };
}

describe("the onboarding catch-up actually runs", () => {
  it("calls the runtime catch-up with this device's keys, writer and driver", async () => {
    const { handle, syncToHead } = await walkToCatchUp();

    await waitFor(() => expect(runMailboxCatchUp).toHaveBeenCalledTimes(1));
    const deps = runMailboxCatchUp.mock.calls[0]![0];
    expect(deps.handle).toBe(handle);
    expect(deps.dek).toBe(DEK);
    expect(deps.accountId).toBe("u_1");
    expect(deps.driver).toBe(handle.driver);
    expect(deps.writer).not.toBeNull();
    await deps.syncToHead();
    expect(syncToHead).toHaveBeenCalled();
  });

  it("shows the counts it read, so the screen's promise is honoured", async () => {
    await walkToCatchUp();
    const summary = await screen.findByTestId("mailbox-catchup-summary");
    expect(summary.textContent).toContain("7 emails read");
    expect(summary.textContent).toContain("3 filed");
    expect(summary.textContent).toContain("2 waiting for review");
  });

  it("says what was set aside, so the counts on screen add up", async () => {
    await walkToCatchUp();
    const line = await screen.findByTestId("mailbox-catchup-setaside");
    expect(line.textContent).toMatch(/^3 not from a bank ledger recognises/);
    expect(line.textContent).toMatch(/still in your mailbox/);
  });
});
