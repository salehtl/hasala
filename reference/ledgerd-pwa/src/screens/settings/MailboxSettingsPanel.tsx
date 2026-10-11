/**
 * The body of the "Transaction mailbox" settings drill-in (spec §3, D6a/D7/D10).
 *
 * # Four states, designed not bolted on
 *
 * The mailbox route has genuinely different situations, and each is a distinct
 * honest render rather than one screen with things hidden:
 *
 *   - **active** — a live grant AND this device holds the sealed token (the
 *     holder, D9): the connected address, a last-catch-up line, "Catch up now", a
 *     backfill window it can re-run, the durable unreadable count, and Disconnect.
 *   - **another_device** — a live grant but no token here: this device reads
 *     nothing, so it offers no catch-up and points at the device that can, plus a
 *     way to move the connection here. NOT an error.
 *   - **reconnect_required** — Google stopped honouring the grant (D10's weekly
 *     beta expiry): the honest reconnect copy, never "one tap".
 *   - **never_connected** — no grant at all: a connect affordance, and a pointer
 *     to the forwarding route which lives elsewhere in Settings.
 *
 * `reconnect_incomplete` (a connect attempt that did not replace an existing
 * mailbox) is a CONNECT-flow outcome with its own copy in
 * `MAILBOX_CONNECT_FAILURE_COPY`; it is never rendered by this panel, which is
 * why the two reconnect kinds cannot be confused here.
 *
 * # Two honesty rails this panel keeps
 *
 *  - **No verified-origin implication (D6a).** A mailbox row is client-authored
 *    and its money stays editable; nothing here says a server checked the sender.
 *    The source note says where a row came from and stops. `onboarding.test.ts`
 *    forbids the word across `MAILBOX_SETTINGS_COPY`.
 *  - **Liveness is not health.** The last-catch-up line is when a fetch last ran,
 *    not a claim that anything is healthy (Task 6). The durable unreadable count
 *    is the health surface — messages the lane could not read, kept visible
 *    across sessions (the durable half of the nothing-dropped invariant, §2.5).
 *
 * # Motion
 *
 * None of its own. It is the body of `V2Settings`'s `SettingsPage`, which owns the
 * x:100%→0 drill-in slide; the disconnect confirmation is the shared `Dialog`.
 * This file adds no `m.*` and no per-component reduced-motion handling.
 */

import { useCallback, useEffect, useState } from "react";

import { Button } from "../../components/ui/Button";
import { Dialog, DialogFooter } from "../../components/ui/Dialog";
import { PixelSpinner } from "../../components/ui/PixelSpinner";
import { SectionLabel } from "../../components/ui/SectionLabel";
import { SegmentedControl } from "../../components/ui/SegmentedControl";
import { sinceLabel } from "../../lib/sinceLabel";
import {
  BACKFILL_WINDOWS,
  MAILBOX_ROUTE_OVERLAP_NOTICE,
  MAILBOX_SETTINGS_COPY,
  connectedLabel,
  type BackfillDays,
} from "../../v2/onboarding";
import type { CycleReport } from "../../v2/mailbox/fetch";
import { isMailboxRevokeUnconfirmed } from "../../v2/mailboxConnect";
import { mailboxSettingsState, type MailboxSettingsState } from "../../v2/mailbox/settingsState";
import { emptySetAsideLog, type MailboxState, type UnreadableLog } from "../../v2/mailbox/state";
import { SetAsideSection } from "../mailbox/SetAsideSection";

/** What the panel reads on mount and the actions it can take. All injected. */
export interface MailboxSettingsPanelProps {
  /** The grant status string, or `null` for no grant. Throws on a read failure. */
  loadGrantStatus: () => Promise<string | null>;
  /** Whether THIS device holds a usable sealed token (the holder test, D9). */
  hasSealedToken: () => Promise<boolean>;
  /** The device-local fetch state: connected email, last cycle, backfill, unreadable. */
  loadState: () => Promise<MailboxState>;
  /** A forwarding address is ALSO set up — shows the D7 "pick one route" notice. */
  forwardingConfigured: boolean;
  /** Runs one catch-up cycle (holder only). */
  catchUpNow: () => Promise<CycleReport>;
  /**
   * Trusts a sender domain and imports the mail the lane set aside for it
   * (`runtime.importMailboxSetAsideDomain`). The user's answer to "which of these
   * is your bank?" — the action that makes set-aside reversible rather than a
   * silent drop.
   */
  importSetAside: (domain: string) => Promise<CycleReport>;
  /** Persists a new backfill window for the next backfill. */
  saveBackfill: (days: BackfillDays) => Promise<void>;
  /** Opens the connect ceremony — for reconnect, another-device takeover, and never-connected. */
  onConnect: () => void;
  /** Revoke at Google + delete the sealed token + delete the grant. */
  disconnect: () => Promise<void>;
  /** Test seam. Defaults to `Date.now`. */
  now?: () => number;
}

type Load =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; state: MailboxSettingsState; data: MailboxState };

export function MailboxSettingsPanel({
  loadGrantStatus,
  hasSealedToken,
  loadState,
  forwardingConfigured,
  catchUpNow,
  importSetAside,
  saveBackfill,
  onConnect,
  disconnect,
  now = Date.now,
}: MailboxSettingsPanelProps) {
  const [load, setLoad] = useState<Load>({ status: "loading" });
  const [reload, setReload] = useState(0);
  const [disconnected, setDisconnected] = useState(false);

  useEffect(() => {
    let live = true;
    void (async () => {
      try {
        const [grant, holder, data] = await Promise.all([loadGrantStatus(), hasSealedToken(), loadState()]);
        if (live) setLoad({ status: "ready", state: mailboxSettingsState(grant, holder), data });
      } catch {
        if (live) setLoad({ status: "error" });
      }
    })();
    return () => {
      live = false;
    };
  }, [loadGrantStatus, hasSealedToken, loadState, reload]);

  if (disconnected) {
    return (
      <p data-testid="mailbox-settings-disconnected" role="status" className="text-sm leading-relaxed text-muted">
        {MAILBOX_SETTINGS_COPY.disconnect.done}
      </p>
    );
  }

  if (load.status === "loading") {
    return (
      <div data-testid="mailbox-settings-loading" className="flex items-center gap-3 text-muted" role="status">
        <PixelSpinner size={12} />
        <span className="text-sm">Reading your mailbox connection…</span>
      </div>
    );
  }

  if (load.status === "error") {
    return (
      <div data-testid="mailbox-settings-error" className="space-y-3">
        <p role="alert" className="text-sm leading-relaxed text-bad">
          ledger could not read your mailbox connection just now. Nothing is wrong with the connection itself.
        </p>
        <Button variant="secondary" onClick={() => setReload((n) => n + 1)}>
          Try again
        </Button>
      </div>
    );
  }

  return (
    <div data-testid="mailbox-settings" className="space-y-6">
      <p className="text-sm leading-relaxed text-muted">{MAILBOX_SETTINGS_COPY.intro}</p>

      {load.state === "active" && (
        <ActiveState
          data={load.data}
          catchUpNow={catchUpNow}
          importSetAside={importSetAside}
          onImported={() => setReload((n) => n + 1)}
          saveBackfill={saveBackfill}
          onDisconnected={() => setDisconnected(true)}
          disconnect={disconnect}
          now={now}
        />
      )}
      {load.state === "another_device" && <AnotherDevice onConnect={onConnect} />}
      {load.state === "reconnect_required" && <ReconnectRequired onConnect={onConnect} />}
      {load.state === "never_connected" && <NeverConnected onConnect={onConnect} />}

      {/* D7: a connected mailbox AND forwarding is asking for cross-path duplicates. */}
      {load.state !== "never_connected" && forwardingConfigured && <RouteOverlapNotice />}
    </div>
  );
}

function ActiveState({
  data,
  catchUpNow,
  importSetAside,
  onImported,
  saveBackfill,
  onDisconnected,
  disconnect,
  now,
}: {
  data: MailboxState;
  catchUpNow: () => Promise<CycleReport>;
  importSetAside: (domain: string) => Promise<CycleReport>;
  onImported: () => void;
  saveBackfill: (days: BackfillDays) => Promise<void>;
  onDisconnected: () => void;
  disconnect: () => Promise<void>;
  now: () => number;
}) {
  const [report, setReport] = useState<CycleReport | null>(null);
  const [catchingUp, setCatchingUp] = useState(false);
  const [lastCycleAt, setLastCycleAt] = useState<string | null>(data.lastCycleAt);

  const runCatchUp = useCallback(async () => {
    setCatchingUp(true);
    try {
      const r = await catchUpNow();
      setReport(r);
      setLastCycleAt(new Date(now()).toISOString());
    } finally {
      setCatchingUp(false);
    }
  }, [catchUpNow, now]);

  const since = lastCycleAt === null ? null : sinceLabel(Date.parse(lastCycleAt), now());

  return (
    <div className="space-y-6">
      <div className="space-y-1">
        <p data-testid="mailbox-settings-connected-label" className="text-sm font-medium text-fg">
          {connectedLabel(data.connectedEmail ?? "")}
        </p>
        {/* Liveness, said as liveness — never health (Task 6). */}
        <p data-testid="mailbox-settings-status" className="text-xs leading-relaxed text-muted">
          {MAILBOX_SETTINGS_COPY.lastCaughtUp(since)}
        </p>
      </div>

      <div className="space-y-3">
        <Button
          variant="secondary"
          data-testid="mailbox-settings-catchup"
          disabled={catchingUp}
          onClick={() => void runCatchUp()}
        >
          {catchingUp ? MAILBOX_SETTINGS_COPY.catchUp.running : MAILBOX_SETTINGS_COPY.catchUp.action}
        </Button>
        {report !== null && <CatchUpSummary report={report} />}
        <p className="text-xs leading-relaxed text-muted">{MAILBOX_SETTINGS_COPY.catchUp.liveness}</p>
      </div>

      <BackfillControl initial={data.backfillDays} saveBackfill={saveBackfill} />

      {/* What the lane did NOT import, and the action that overrules it. */}
      <SetAsideSection
        log={data.setAside ?? emptySetAsideLog()}
        importDomain={importSetAside}
        onImported={onImported}
      />

      <UnreadableSurface log={data.unreadable} />

      {/* The source note (D6a): says where these rows came from, not that anyone vouched. */}
      <p data-testid="mailbox-settings-source-note" className="text-xs leading-relaxed text-muted">
        {MAILBOX_SETTINGS_COPY.sourceNote}
      </p>

      <DisconnectControl disconnect={disconnect} onDisconnected={onDisconnected} />
    </div>
  );
}

/**
 * What a halted cycle says. A cycle that stops short used to render as
 * "0 emails read" with nothing else — a UI sentence the code did not honour,
 * and the reason a broken mailbox looked like an empty one.
 */
const HALTED_COPY: Record<NonNullable<CycleReport["haltedOn"]>, string> = {
  error: "ledger could not finish reading the mailbox.",
  reconnect_required: "ledger cannot read the mailbox until you reconnect it.",
  budget_full: "ledger stopped early: this account is out of storage.",
};

function CatchUpSummary({ report }: { report: CycleReport }) {
  const filed = report.ops - report.review;
  return (
    <div className="flex flex-col gap-2">
      {report.haltedOn !== undefined && (
        <p data-testid="mailbox-settings-catchup-halted" className="text-sm leading-relaxed text-warn">
          {HALTED_COPY[report.haltedOn]}
          {report.haltedDetail !== undefined && report.haltedDetail !== "" ? ` ${report.haltedDetail}` : ""}
        </p>
      )}
      <ul data-testid="mailbox-settings-catchup-summary" className="text-sm text-muted flex flex-col gap-1">
        <li>{`${report.fetched} ${report.fetched === 1 ? "email" : "emails"} read`}</li>
        <li>{`${filed} filed as ${filed === 1 ? "a transaction" : "transactions"}`}</li>
        <li>{`${report.review} waiting for review`}</li>
        {report.unreadable > 0 && <li>{`${report.unreadable} ledger could not read`}</li>}
        {/* Never hidden: mail the lane held back is the user's to overrule. */}
        {(report.setAside ?? 0) > 0 && (
          <li data-testid="mailbox-settings-catchup-setaside">
            {`${report.setAside ?? 0} not from a bank ledger recognises — listed below, still in your mailbox`}
          </li>
        )}
      </ul>
    </div>
  );
}

function BackfillControl({
  initial,
  saveBackfill,
}: {
  initial: number;
  saveBackfill: (days: BackfillDays) => Promise<void>;
}) {
  // Snap a stored window that is not one of the three offered to the nearest
  // offered value only for the control's own display; the save writes the offered
  // value the user picks. A user's own past non-standard window is honoured by the
  // fetch lane regardless (state.ts), so this never overwrites it until a save.
  const offered = BACKFILL_WINDOWS.map((w) => w.days) as readonly BackfillDays[];
  const [days, setDays] = useState<BackfillDays>(
    (offered.find((d) => d === initial) ?? offered[0]) as BackfillDays,
  );
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  const save = useCallback(async () => {
    setSaving(true);
    setSaved(false);
    try {
      await saveBackfill(days);
      setSaved(true);
    } finally {
      setSaving(false);
    }
  }, [days, saveBackfill]);

  return (
    <div data-testid="mailbox-settings-backfill" className="space-y-2">
      <SectionLabel>{MAILBOX_SETTINGS_COPY.backfill.title}</SectionLabel>
      <p className="text-xs leading-relaxed text-muted">{MAILBOX_SETTINGS_COPY.backfill.body}</p>
      <SegmentedControl<`${BackfillDays}`>
        fullWidth
        value={`${days}`}
        onChange={(v) => {
          setDays(Number(v) as BackfillDays);
          setSaved(false);
        }}
        options={BACKFILL_WINDOWS.map((w) => ({ value: `${w.days}` as `${BackfillDays}`, label: w.label }))}
      />
      <Button variant="ghost" data-testid="mailbox-settings-backfill-save" disabled={saving} onClick={() => void save()}>
        {saving ? "Saving…" : MAILBOX_SETTINGS_COPY.backfill.action}
      </Button>
      {saved && (
        <p role="status" className="text-xs text-muted">
          {MAILBOX_SETTINGS_COPY.backfill.saved}
        </p>
      )}
    </div>
  );
}

/**
 * The durable health surface: how many messages the lane could not read, kept
 * visible across sessions (§2.5). Rendered only when there are any — an empty
 * count is not news — and worded as health, apart from the liveness line above.
 */
function UnreadableSurface({ log }: { log: UnreadableLog }) {
  if (log.count === 0) return null;
  return (
    <div
      data-testid="mailbox-settings-unreadable"
      className="rounded-[var(--radius)] border border-warn/30 bg-warn/10 p-4 space-y-1"
    >
      <p className="text-sm font-medium text-warn">{MAILBOX_SETTINGS_COPY.unreadable.label(log.count)}</p>
      <p className="text-xs leading-relaxed text-muted">{MAILBOX_SETTINGS_COPY.unreadable.detail}</p>
    </div>
  );
}

function DisconnectControl({
  disconnect,
  onDisconnected,
}: {
  disconnect: () => Promise<void>;
  onDisconnected: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [unconfirmed, setUnconfirmed] = useState(false);

  const run = useCallback(async () => {
    setBusy(true);
    setFailed(false);
    setUnconfirmed(false);
    try {
      await disconnect();
      setOpen(false);
      onDisconnected();
    } catch (error) {
      // Not a failure. `disconnectMailboxAccount` sweeps the sealed token and
      // the mailbox state before it ever calls Google, so by the time this
      // arrives ledger has already stopped reading the mailbox and the grant is
      // gone. The only outstanding half is Google's own record of the
      // permission, which only the user can withdraw — so this branch reports
      // a completed disconnect carrying one thing left to do, and lands on the
      // disconnected state once acknowledged.
      if (isMailboxRevokeUnconfirmed(error)) setUnconfirmed(true);
      else setFailed(true);
    } finally {
      setBusy(false);
    }
  }, [disconnect, onDisconnected]);

  const acknowledge = useCallback(() => {
    setUnconfirmed(false);
    setOpen(false);
    onDisconnected();
  }, [onDisconnected]);

  return (
    <div className="space-y-2">
      <Button
        variant="ghost"
        data-testid="mailbox-settings-disconnect"
        className="text-bad"
        onClick={() => setOpen(true)}
      >
        {MAILBOX_SETTINGS_COPY.disconnect.action}
      </Button>
      {open && (
        <Dialog
          title={MAILBOX_SETTINGS_COPY.disconnect.title}
          onClose={() => (busy || unconfirmed ? undefined : setOpen(false))}
        >
          {unconfirmed ? (
            // The disconnect happened. There is nothing to confirm or retry
            // here, so the question and both of its buttons are gone: leaving
            // "Disconnect" on screen would invite a second run of work that is
            // already done.
            <>
              <p role="alert" data-testid="mailbox-settings-revoke-unconfirmed" className="text-sm leading-relaxed">
                {MAILBOX_SETTINGS_COPY.disconnect.revokeUnconfirmed}
              </p>
              <DialogFooter>
                <Button
                  variant="primary"
                  data-testid="mailbox-settings-revoke-unconfirmed-ack"
                  onClick={acknowledge}
                >
                  Done
                </Button>
              </DialogFooter>
            </>
          ) : (
            <>
              <p className="text-sm leading-relaxed mb-4">{MAILBOX_SETTINGS_COPY.disconnect.body}</p>
              {failed && (
                <p role="alert" className="text-sm text-bad mb-4">
                  {MAILBOX_SETTINGS_COPY.disconnect.failed}
                </p>
              )}
              <DialogFooter>
                <Button variant="ghost" disabled={busy} onClick={() => setOpen(false)}>
                  {MAILBOX_SETTINGS_COPY.disconnect.cancel}
                </Button>
                <Button
                  variant="danger"
                  data-testid="mailbox-settings-disconnect-confirm"
                  disabled={busy}
                  onClick={() => void run()}
                >
                  {busy ? MAILBOX_SETTINGS_COPY.disconnect.working : MAILBOX_SETTINGS_COPY.disconnect.confirm}
                </Button>
              </DialogFooter>
            </>
          )}
        </Dialog>
      )}
    </div>
  );
}

function ReconnectRequired({ onConnect }: { onConnect: () => void }) {
  return (
    <div data-testid="mailbox-settings-reconnect" className="space-y-3">
      <h3 className="text-sm font-semibold text-warn">{MAILBOX_SETTINGS_COPY.reconnect.title}</h3>
      <p className="text-sm leading-relaxed text-muted">{MAILBOX_SETTINGS_COPY.reconnect.body}</p>
      <Button variant="primary" data-testid="mailbox-settings-reconnect-action" onClick={onConnect}>
        {MAILBOX_SETTINGS_COPY.reconnect.action}
      </Button>
    </div>
  );
}

function AnotherDevice({ onConnect }: { onConnect: () => void }) {
  return (
    <div data-testid="mailbox-settings-another-device" className="space-y-3">
      <h3 className="text-sm font-semibold text-fg">{MAILBOX_SETTINGS_COPY.anotherDevice.title}</h3>
      <p className="text-sm leading-relaxed text-muted">{MAILBOX_SETTINGS_COPY.anotherDevice.body}</p>
      <Button variant="secondary" onClick={onConnect}>
        {MAILBOX_SETTINGS_COPY.anotherDevice.action}
      </Button>
    </div>
  );
}

function NeverConnected({ onConnect }: { onConnect: () => void }) {
  return (
    <div data-testid="mailbox-settings-never-connected" className="space-y-3">
      <h3 className="text-sm font-semibold text-fg">{MAILBOX_SETTINGS_COPY.neverConnected.title}</h3>
      <p className="text-sm leading-relaxed text-muted">{MAILBOX_SETTINGS_COPY.neverConnected.body}</p>
      <Button variant="primary" data-testid="mailbox-settings-connect" onClick={onConnect}>
        {MAILBOX_SETTINGS_COPY.neverConnected.action}
      </Button>
    </div>
  );
}

function RouteOverlapNotice() {
  return (
    <div
      data-testid="mailbox-settings-route-overlap"
      className="rounded-[var(--radius)] border border-warn/30 bg-warn/10 p-4 space-y-1"
    >
      <p className="text-sm font-medium text-warn">{MAILBOX_ROUTE_OVERLAP_NOTICE.title}</p>
      <p className="text-xs leading-relaxed text-muted">{MAILBOX_ROUTE_OVERLAP_NOTICE.body}</p>
    </div>
  );
}
