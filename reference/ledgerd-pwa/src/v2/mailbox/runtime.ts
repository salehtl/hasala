/**
 * The one place the mailbox fetch lane is wired to the running app.
 *
 * Task 12 built `runFetchCycle` and `startMailboxLiveness` as pure engines with
 * every dependency injected; Task 14's onboarding sealed a token but deliberately
 * did NOT start a scheduler (onboarding unmounts on "Open ledger"). This module
 * is the integration both deferred to Task 15: it derives the fetch-cycle
 * dependencies from the running V2 runtime plus the account DEK + id read from the
 * key vault, so two callers — the holder-device app-shell liveness scheduler and
 * the settings drill-in's "Catch up now" — build them the same way and cannot
 * drift.
 *
 * # Op authoring runs through here, so read the disciplines it upholds
 *
 * The cycle authors `txn_ingested` ops, the highest-risk code in the repo. This
 * module supplies the four dependencies that keep a resume from minting a second
 * op for the same message:
 *
 *   - **`syncToHead`** pulls the log to head before authoring, so a peer device's
 *     op is visible to dedup (D5).
 *   - **`alreadyIngested`** answers whether an ingest id has already folded on
 *     THIS device, read from the projection — the durable half of the dedup the
 *     cycle's in-memory `pendingIngest` set does for the current session.
 *   - **`grantId`** is the account id (D9 pins one grant per account), recorded in
 *     every op's provenance so a review card can re-fetch by message id.
 *   - **`hasSealedToken`** is the holder test (D9): it opens the sealed row and a
 *     residual-row throw counts as "not a holder", so a non-holder never fetches
 *     and a shared-browser residual never masquerades as a connection.
 */

import { newEntityID } from "@ledger/client/net/client";
import { ensureProjection } from "@ledger/client/replay/projection";
import type { SqlDriver } from "@ledger/client/store/driver";
import type { Definition } from "@ledger/client/tmpl/exec";

import {
  deleteMailboxGrant,
  disconnectMailbox,
  mailboxRevokeUnconfirmed,
  mintAccessToken,
  sweepMailboxLocal,
} from "../mailboxConnect";
import { browserMailboxTokenStore, openMailboxToken, type KeyStore } from "../mailboxToken";
import { readTemplateDefinitions } from "../onboardingIO";
import type { V2Handle } from "../session";
import type { Writer } from "../writer";
import { listSenders, trustSender } from "./senders";
import {
  importSetAsideDomain,
  runFetchCycle,
  startMailboxLiveness,
  type CycleReport,
  type FetchCycleDeps,
  type MailboxLivenessDeps,
} from "./fetch";

/** What the running app can supply the fetch lane. */
export interface MailboxRuntimeDeps {
  handle: V2Handle;
  /** The account DEK, read from the key vault (`keys.ts`). Never persisted here. */
  dek: CryptoKey;
  /** The account id — the grant id (D9) and the sealed-token AAD binding. */
  accountId: string;
  /** The device writer (`useWriter`). */
  writer: Writer;
  /** This device's projection, for the durable dedup read. */
  driver: SqlDriver;
  /** Pulls the log to head before authoring (D5). Usually `sync.run("refresh")`. */
  syncToHead(): Promise<void>;
  /** The sealed-token/checkpoint store. Defaults to the browser IndexedDB store. */
  store?: KeyStore;
}

/**
 * Whether an ingest id has already folded into this device's projection.
 *
 * A `SELECT 1` against the `txn` table — the durable counterpart to the cycle's
 * in-session `pendingIngest` set. `ensureProjection` first so a device that has
 * not yet built its projection reads "no" (a backfill re-authors, safe under the
 * server's ingest-id dedup) rather than throwing on a missing table.
 */
function alreadyIngestedIn(driver: SqlDriver, ingestId: string): boolean {
  ensureProjection(driver);
  return driver.prepare("SELECT 1 FROM txn WHERE ingest_id = ? LIMIT 1").all(ingestId).length > 0;
}

/** The fetch-cycle dependencies for the running app. */
export function fetchCycleDeps(deps: MailboxRuntimeDeps): FetchCycleDeps {
  const store = deps.store ?? browserMailboxTokenStore();
  return {
    syncToHead: deps.syncToHead,
    mintAccessToken: () => mintAccessToken(deps.handle, deps.dek, deps.accountId, { store }),
    loadSenders: () => listSenders(deps.handle),
    loadTemplates: () => readTemplateDefinitions(deps.handle.client) as Promise<readonly Definition[]>,
    alreadyIngested: (ingestId) => alreadyIngestedIn(deps.driver, ingestId),
    writer: deps.writer,
    newID: newEntityID,
    grantId: deps.accountId,
    store,
  };
}

/** Runs one fetch cycle for the running app. Never rejects (see `runFetchCycle`). */
export function runMailboxCatchUp(deps: MailboxRuntimeDeps): Promise<CycleReport> {
  return runFetchCycle(fetchCycleDeps(deps));
}

/**
 * "This is my bank": trusts a sender domain for this account, then imports the
 * messages the fetch lane set aside for it.
 *
 * The two steps are ordered and both matter. `trustSender` is the account-wide
 * fact (D6, server-side per-user list) that makes FUTURE mail from the domain
 * eligible; {@link importSetAsideDomain} is what goes back for the mail already
 * received — which is only possible because D5 leaves it in the burner mailbox.
 * A refused trust (the per-account cap, a forwarder domain) throws before
 * anything is imported, so the surface reports one failure rather than a
 * half-done action.
 */
export async function importMailboxSetAsideDomain(
  deps: MailboxRuntimeDeps & { domain: string },
): Promise<CycleReport> {
  await trustSender(deps.handle, deps.domain);
  return importSetAsideDomain(fetchCycleDeps(deps), deps.domain);
}

/**
 * Fully disconnects the account's mailbox — the Settings disconnect, and the path
 * Task 17's deletion reuses.
 *
 * The order matters and is fixed: open the sealed token (if this device holds a
 * usable one) and revoke it at Google via {@link disconnectMailbox}. Then sweep
 * everything local — the token row AND the unsealed sibling STATE row (the
 * checkpoint, backfill, unreadable tally and client-held connected email) —
 * through the one {@link sweepMailboxLocal} helper. Only then delete the grant,
 * which is the one step that can fail on the network: everything local is
 * already clean by the time it runs, so a grant-delete retry never has to reopen
 * a token that is gone.
 *
 * # A revoke Google never answered does not abort the rest
 *
 * The revoke is the only step whose outcome is not ours to decide, and it used
 * to throw straight out of here — so a 503 left the burner address and the
 * checkpoint in cleartext IndexedDB and the grant row alive, on a user who had
 * asked to disconnect. The failure is held instead: the sweep and the grant
 * delete run (both are things we control, and deleting the grant kills the
 * token's only route back to Google anyway, so keeping it would only be
 * residue), and the failure is then rethrown as
 * {@link mailboxRevokeUnconfirmed} — never swallowed, because the one thing
 * that did NOT happen is the revocation at Google, and only the user can finish
 * that from their Google Account page.
 */
export async function disconnectMailboxAccount(args: {
  handle: V2Handle;
  /** null when this device holds no keys (a non-holder disconnecting) — revoke is skipped. */
  dek: CryptoKey | null;
  accountId: string | null;
  store?: KeyStore;
  /** Seam. Defaults to the global `fetch`, and reaches only the revoke route. */
  fetch?: typeof fetch;
  /** Seam. Defaults to `DELETE /api/v1/mailbox/grant`. */
  deleteGrant?: (handle: V2Handle) => Promise<void>;
}): Promise<void> {
  const store = args.store ?? browserMailboxTokenStore();
  let token: string | null = null;
  if (args.dek !== null && args.accountId !== null) {
    token = await openMailboxToken(args.dek, args.accountId, store).catch(() => null);
  }
  let revokeFailure: unknown = null;
  if (token !== null) {
    try {
      await disconnectMailbox(args.handle, token, { store, ...(args.fetch ? { fetch: args.fetch } : {}) });
    } catch (err) {
      revokeFailure = err;
    }
  }
  await sweepMailboxLocal(store);
  await (args.deleteGrant ?? deleteMailboxGrant)(args.handle);
  if (revokeFailure !== null) throw mailboxRevokeUnconfirmed(revokeFailure);
}

/**
 * Whether this device holds a usable sealed token — the holder test (D9).
 *
 * `openMailboxToken` returns `null` for no row (not a holder) and THROWS on a
 * present-but-unreadable row (a shared-browser residual), which is also "not a
 * holder": the liveness scheduler must not fetch from a device whose only token
 * is another account's residual. So a throw resolves `false`, exactly as the
 * review-content loader treats it.
 */
async function hasSealedToken(deps: MailboxRuntimeDeps): Promise<boolean> {
  const store = deps.store ?? browserMailboxTokenStore();
  try {
    return (await openMailboxToken(deps.dek, deps.accountId, store)) !== null;
  } catch {
    return false;
  }
}

/**
 * Starts the persistent, holder-gated liveness scheduler for the app shell
 * (spec D8): one cycle at boot, then one on a while-open interval, each gated on
 * a sealed token being present so a non-holder device never fetches. Returns the
 * stop function the shell calls on unmount. The token gate is re-checked before
 * every tick, so a connect (a token appears) or a disconnect (it is swept) is
 * picked up without restarting the scheduler.
 */
export function startAppShellLiveness(
  deps: MailboxRuntimeDeps,
  opts: Pick<MailboxLivenessDeps, "intervalMs" | "setInterval" | "clearInterval"> = {},
): () => void {
  return startMailboxLiveness({
    hasSealedToken: () => hasSealedToken(deps),
    runCycle: () => runMailboxCatchUp(deps),
    ...opts,
  });
}
