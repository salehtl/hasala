/**
 * The live wiring behind the "Transaction mailbox" drill-in: it reads the DEK +
 * account id from the key vault on mount, builds the panel's loaders and actions
 * from the running runtime, and renders {@link MailboxSettingsPanel}.
 *
 * Kept apart from the panel so the panel stays purely injected — stories and its
 * component test drive it with fakes, no crypto, no network — while this file is
 * the one place the real handle, vault, writer and driver meet.
 *
 * # The connect/reconnect tap opens the popup inside the gesture (WebKit)
 *
 * The same rule `MailboxSetup` follows: WebKit drops the tap's user activation
 * across an await, so the DEK + account id are read on MOUNT (not on the tap), the
 * connect affordances are disabled until that read lands, and `onConnect` is
 * synchronous — it calls `connectMailbox` with the already-read credentials, and
 * `connectMailbox` opens the popup as its first synchronous act.
 */

import { useCallback, useEffect, useMemo, useState } from "react";

import { browserKeyVault, type KeyVault } from "../../v2/keys";
import { useV2OrThrow } from "../../v2/BootGate";
import { connectMailbox, readGrantStatus } from "../../v2/mailboxConnect";
import {
  browserMailboxTokenStore,
  openMailboxToken,
  type KeyStore,
} from "../../v2/mailboxToken";
import { readMailboxState, writeMailboxState } from "../../v2/mailbox/state";
import {
  disconnectMailboxAccount,
  importMailboxSetAsideDomain,
  runMailboxCatchUp,
} from "../../v2/mailbox/runtime";
import type { CycleReport } from "../../v2/mailbox/fetch";
import type { BackfillDays } from "../../v2/onboarding";
import { useWriter, type Writer } from "../../v2/writer";
import { PixelSpinner } from "../../components/ui/PixelSpinner";
import { MailboxSettingsPanel } from "./MailboxSettingsPanel";

type Creds = { status: "loading" } | { status: "ready"; dek: CryptoKey; accountId: string } | { status: "error" };

export interface MailboxSettingsDrillProps {
  /** Test seam. Defaults to the browser key vault. */
  vault?: KeyVault;
  /** Test seam. Defaults to the browser IndexedDB store. */
  store?: KeyStore;
  /** Test seam: a writer that records what a catch-up would append. */
  writer?: Writer;
}

export function MailboxSettingsDrill({ vault, store, writer: injectedWriter }: MailboxSettingsDrillProps) {
  const { handle, sync, facts } = useV2OrThrow();
  const writer = useWriter(injectedWriter);
  const activeVault = useMemo(() => vault ?? browserKeyVault(), [vault]);
  const tokenStore = useMemo(() => store ?? browserMailboxTokenStore(), [store]);
  const [creds, setCreds] = useState<Creds>({ status: "loading" });
  /** Bumped after a connect so the panel re-reads the now-present grant. */
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let live = true;
    void activeVault.read().then(
      (k) => {
        if (live) setCreds(k === null ? { status: "error" } : { status: "ready", dek: k.dek, accountId: k.accountId });
      },
      () => {
        if (live) setCreds({ status: "error" });
      },
    );
    return () => {
      live = false;
    };
  }, [activeVault]);

  const loadGrantStatus = useCallback(() => readGrantStatus(handle), [handle]);

  const hasSealedToken = useCallback(async (): Promise<boolean> => {
    if (creds.status !== "ready") return false;
    try {
      return (await openMailboxToken(creds.dek, creds.accountId, tokenStore)) !== null;
    } catch {
      return false;
    }
  }, [creds, tokenStore]);

  const loadState = useCallback(() => readMailboxState(tokenStore), [tokenStore]);

  const saveBackfill = useCallback(
    async (days: BackfillDays): Promise<void> => {
      const state = await readMailboxState(tokenStore);
      await writeMailboxState({ ...state, backfillDays: days }, tokenStore);
    },
    [tokenStore],
  );

  const catchUpNow = useCallback(async (): Promise<CycleReport> => {
    if (creds.status !== "ready" || writer === null) {
      return {
        fetched: 0,
        ops: 0,
        review: 0,
        unreadable: 0,
        setAside: 0,
        haltedOn: "error",
        haltedDetail: "This device is not ready to read the mailbox yet — reload and try again.",
      };
    }
    return runMailboxCatchUp({
      handle,
      dek: creds.dek,
      accountId: creds.accountId,
      writer,
      driver: handle.driver,
      syncToHead: () => sync.run("refresh"),
      store: tokenStore,
    });
  }, [creds, writer, handle, sync, tokenStore]);

  /**
   * "This is my bank": trust the domain, then import the mail the lane set aside
   * for it. A device that is not ready cannot do either, so it refuses honestly
   * rather than reporting an import that never ran.
   */
  const importSetAside = useCallback(
    async (domain: string): Promise<CycleReport> => {
      if (creds.status !== "ready" || writer === null) {
        return {
          fetched: 0,
          ops: 0,
          review: 0,
          unreadable: 0,
          setAside: 0,
          haltedOn: "error",
          haltedDetail: "This device is not ready to read the mailbox yet — reload and try again.",
        };
      }
      return importMailboxSetAsideDomain({
        handle,
        dek: creds.dek,
        accountId: creds.accountId,
        writer,
        driver: handle.driver,
        syncToHead: () => sync.run("refresh"),
        store: tokenStore,
        domain,
      });
    },
    [creds, writer, handle, sync, tokenStore],
  );

  // Synchronous: nothing awaits between the tap and the popup opening.
  const onConnect = useCallback((): void => {
    if (creds.status !== "ready") return;
    const { dek, accountId } = creds;
    connectMailbox(handle, dek, accountId, { store: tokenStore }).then(
      async ({ email }) => {
        // Cache the client-held address so the active state can show it with no
        // server read (see `mailbox/state.ts`). Best-effort — a failed write only
        // costs the label, not the connection.
        try {
          const state = await readMailboxState(tokenStore);
          await writeMailboxState({ ...state, connectedEmail: email === "" ? null : email }, tokenStore);
        } catch {
          /* label-only */
        }
        setReloadKey((n) => n + 1);
      },
      () => {
        // A cancelled/failed connect changes nothing; the panel re-reads and stays
        // on whatever state the grant actually reports.
        setReloadKey((n) => n + 1);
      },
    );
  }, [creds, handle, tokenStore]);

  const disconnect = useCallback(
    (): Promise<void> =>
      // Revoke → sweep token → sweep the sibling state row (checkpoint, backfill,
      // unreadable, connected email) → delete the grant. One ordered path, shared
      // with Task 17's deletion, so the state-cache sweep cannot be forgotten in
      // one caller and remembered in the other.
      disconnectMailboxAccount({
        handle,
        dek: creds.status === "ready" ? creds.dek : null,
        accountId: creds.status === "ready" ? creds.accountId : null,
        store: tokenStore,
      }),
    [creds, handle, tokenStore],
  );

  if (creds.status === "loading") {
    return (
      <div className="flex items-center gap-3 text-muted" role="status">
        <PixelSpinner size={12} />
        <span className="text-sm">Getting your mailbox connection ready…</span>
      </div>
    );
  }

  const forwardingConfigured = facts.forwardingDeclared || facts.inboundAddress !== null;

  return (
    <MailboxSettingsPanel
      key={reloadKey}
      loadGrantStatus={loadGrantStatus}
      hasSealedToken={hasSealedToken}
      loadState={loadState}
      forwardingConfigured={forwardingConfigured}
      catchUpNow={catchUpNow}
      importSetAside={importSetAside}
      saveBackfill={saveBackfill}
      onConnect={onConnect}
      disconnect={disconnect}
    />
  );
}
