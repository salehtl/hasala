/**
 * The Gmail transaction-mailbox route (spec §3, D11): burner guidance → the
 * consent ceremony → a backfill window → the catching-up confirmation.
 *
 * # It owns its own sub-flow; the machine advances only at the end
 *
 * The onboarding machine is at `keys_secured` the whole time this is on screen.
 * A grant appears server-side the instant the ceremony completes, but this
 * screen does NOT dispatch `mailbox_connected` there — it would advance the walk
 * to the home-currency step and unmount the backfill and catching-up screens in
 * the same frame, exactly the one-frame flash `Address` avoids by advancing only
 * on a Continue tap. So the sub-flow runs to its end and `onConnected` fires from
 * the final Continue. (A reload mid-flow re-reads the grant at boot and skips
 * straight to the currency step — the same resume behaviour `Address` has once
 * its address is minted, and acceptable: the backfill has a default and is
 * re-runnable in Settings.)
 *
 * # This screen does NOT start the long-lived liveness scheduler
 *
 * `startMailboxLiveness` (spec D8) fetches while the app is open on the holder
 * device — but onboarding UNMOUNTS on "Open ledger", which would stop any
 * scheduler this screen started in the same instant it became useful. So the
 * persistent scheduler belongs to the holder-device app shell (Task 15), which
 * re-derives the DEK + account id from the key vault exactly as this screen does
 * and gates on `hasSealedToken` (true once the ceremony sealed one here). This
 * screen's job is the one-time ceremony and an HONEST confirmation of how the
 * lane stays current thereafter — "ledger catches up when you open it", never a
 * near-real-time promise the fetch-on-open lane cannot keep.
 *
 * # The connect tap opens the popup inside the gesture (WebKit)
 *
 * WebKit — the primary PWA platform — drops the tap's user activation across an
 * await and blocks a popup opened after one. So the DEK + account id are read
 * from the vault on MOUNT (not on the tap), the "Connect with Google" button is
 * disabled until that read lands, and the tap handler is synchronous: it calls
 * `connectMailbox` with the already-read credentials, and `connectMailbox` opens
 * the popup as its first synchronous act, before any await. Nothing on the path
 * from tap to `window.open` awaits.
 *
 * # Motion
 *
 * Static tree-swaps with focus on the heading, the onboarding convention. The
 * one exception the criteria allow — a FADE on the connect WAIT state — is the
 * only animation here; the reduced-motion user gets an opacity settle, which
 * `MotionConfig reducedMotion="user"` keeps.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { m } from "motion/react";

import { Button } from "../../components/ui/Button";
import { PixelSpinner } from "../../components/ui/PixelSpinner";
import { SegmentedControl } from "../../components/ui/SegmentedControl";
import { FADE } from "../../lib/motion";
import { browserKeyVault, type KeyVault } from "../../v2/keys";
import { connectMailbox, isMailboxError, type MailboxFailureKind } from "../../v2/mailboxConnect";
import {
  browserMailboxTokenStore,
  type KeyStore,
} from "../../v2/mailboxToken";
import { readMailboxState, writeMailboxState } from "../../v2/mailbox/state";
import type { CycleReport } from "../../v2/mailbox/fetch";
import {
  BACKFILL_COPY,
  BACKFILL_WINDOWS,
  BURNER_GUIDANCE_COPY,
  CATCHING_UP_COPY,
  MAILBOX_CONNECT_FAILURE_COPY,
  connectedLabel,
  type BackfillDays,
} from "../../v2/onboarding";
import type { V2Handle } from "../../v2/session";
import { Notice, SkipStep, Step } from "./Shell";

/** How this screen gets the DEK + account id, and how it reaches Google. Injected in tests. */
export interface MailboxSetupProps {
  handle: V2Handle;
  /** Dispatch `mailbox_connected` — fired ONLY from the final Continue. */
  onConnected: () => void;
  /** Switch back to the forwarding route (`mail_route_chosen: "forward"`). */
  onForward: () => void;
  /** "Set this up later" — the same address_issued skip both routes carry. */
  onSkip: () => void;
  /**
   * Where the DEK + account id are read from, ON MOUNT (see the header). Defaults
   * to the browser key vault.
   */
  vault?: KeyVault;
  /**
   * Runs the consent ceremony. Defaults to {@link connectMailbox} bound to the
   * handle and the DEK + account id read from the vault on mount. Called
   * SYNCHRONOUSLY from the tap so its popup opens inside the gesture. Injected
   * whole in tests so no real popup or crypto is needed.
   */
  connect?: (dek: CryptoKey, accountId: string) => Promise<{ email: string }>;
  /** Persists the chosen backfill window. Defaults to writing the mailbox state store. */
  saveBackfill?: (days: BackfillDays) => Promise<void>;
  /**
   * Runs one initial catch-up cycle to render its {@link CycleReport}.
   *
   * The walk supplies it (`Onboarding`'s `MailStep`), because the fetch runtime's
   * other dependencies — the writer, this device's projection driver and the pull
   * to head — belong to the handle, not to this screen. What this screen owns is
   * the half the runner cannot get anywhere else: the DEK + account id it already
   * read from the vault on MOUNT for the gesture rule above. So they are passed
   * back in at call time rather than read a second time, and the prop stays a
   * plain function a test can hand over whole.
   *
   * Still optional: with no runner the catching-up screen shows no spinner and no
   * counts rather than a progress bar for work nobody started.
   */
  runCatchUp?: (days: BackfillDays, creds: { dek: CryptoKey; accountId: string }) => Promise<CycleReport>;
  embedded?: boolean;
}

type Phase =
  | { kind: "guidance" }
  | { kind: "connecting" }
  | { kind: "error"; failure: MailboxFailureKind }
  | { kind: "backfill"; email: string }
  | { kind: "catching_up"; email: string; report: CycleReport | null; running: boolean };

/** The mailbox setup flow. */
/** The DEK + account id, read from the vault on mount so the tap needs no await. */
type Creds = { status: "loading" } | { status: "ready"; dek: CryptoKey; accountId: string } | { status: "error" };

export function MailboxSetup({
  handle,
  onConnected,
  onForward,
  onSkip,
  vault,
  connect,
  saveBackfill,
  runCatchUp,
  embedded = false,
}: MailboxSetupProps) {
  const [phase, setPhase] = useState<Phase>({ kind: "guidance" });
  const [backfill, setBackfill] = useState<BackfillDays>(BACKFILL_WINDOWS[0].days);

  // Stable across renders so the mount read runs once — an inline
  // `browserKeyVault()` default would be a new object every render and re-fire
  // the effect forever.
  const activeVault = useMemo(() => vault ?? browserKeyVault(), [vault]);
  const [creds, setCreds] = useState<Creds>({ status: "loading" });

  // Read the DEK on MOUNT, not on the tap: the popup must open synchronously
  // inside the gesture (WebKit), and `vault.read()` is an await. See the header.
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

  // Synchronous: NOTHING awaits between the tap and the popup opening. `doConnect`
  // opens the window as its first synchronous act (`connectMailbox`), and the
  // credentials it needs were already read on mount.
  const runConnect = useCallback(() => {
    if (creds.status !== "ready") {
      // Post keys_secured this is near-impossible; if the vault could not be
      // read, it is not a connect failure the user caused. It is also not a
      // GOOGLE failure: nothing has been sent. `unavailable` used to be shown
      // here, and its copy says "Something went wrong on the way to Google" —
      // which sent a user whose key vault failed to go and check Google.
      setPhase({ kind: "error", failure: "device_keys_unavailable" });
      return;
    }
    setPhase({ kind: "connecting" });
    const doConnect =
      connect ?? ((dek: CryptoKey, accountId: string) => connectMailbox(handle, dek, accountId));
    doConnect(creds.dek, creds.accountId).then(
      ({ email }) => setPhase({ kind: "backfill", email }),
      (err) => setPhase({ kind: "error", failure: isMailboxError(err) ? err.mailboxKind : "unavailable" }),
    );
  }, [handle, creds, connect]);

  const startCatchUp = useCallback(
    async (email: string) => {
      const days = backfill;
      const persist =
        saveBackfill ??
        (async (d: BackfillDays): Promise<void> => {
          const store: KeyStore = browserMailboxTokenStore();
          const state = await readMailboxState(store);
          // The connected address is client-held: decoded from the id_token at
          // connect and cached here so Settings can show "Connected as …" with no
          // server read. Not a secret — the same class as the cleartext inbound
          // address the forwarding lane caches. See `mailbox/state.ts`.
          await writeMailboxState({ ...state, backfillDays: d, connectedEmail: email === "" ? null : email }, store);
        });
      try {
        await persist(days);
      } catch {
        // A backfill window that could not be written is not a wall: it defaults
        // to 30 days, and Settings can change it. Carry on to the confirmation.
      }
      // A runner with no credentials to run with is no runner: the screen must
      // not claim to be reading a mailbox it cannot open. Reaching here without
      // ready credentials is near-impossible (the connect tap refuses without
      // them), which is exactly why it is stated rather than assumed.
      const ready = creds.status === "ready" ? { dek: creds.dek, accountId: creds.accountId } : null;
      const run = runCatchUp !== undefined && ready !== null ? runCatchUp : undefined;
      setPhase({ kind: "catching_up", email, report: null, running: run !== undefined });
      if (run === undefined || ready === null) return;
      try {
        const report = await run(days, ready);
        setPhase({ kind: "catching_up", email, report, running: false });
      } catch {
        setPhase({ kind: "catching_up", email, report: null, running: false });
      }
    },
    [backfill, saveBackfill, runCatchUp, creds],
  );

  if (phase.kind === "connecting") {
    return (
      <Step testId="mailbox-connecting" embedded={embedded} title="Opening the Google window">
        <m.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={FADE}
          className="flex items-center gap-3 text-muted"
          role="status"
        >
          <PixelSpinner size={12} />
          <span className="text-sm">Waiting for you to finish signing in with Google…</span>
        </m.div>
      </Step>
    );
  }

  if (phase.kind === "error") {
    const copy = MAILBOX_CONNECT_FAILURE_COPY[phase.failure];
    return (
      <Step
        testId="mailbox-error"
        embedded={embedded}
        title={copy.title}
        footer={
          <>
            <Button variant="primary" onClick={runConnect}>
              {copy.action}
            </Button>
            <Button variant="ghost" onClick={onForward}>
              Forward to a ledger address instead
            </Button>
          </>
        }
      >
        <Notice tone="danger" announce testId="mailbox-error-notice">
          <p>{copy.body}</p>
        </Notice>
        <SkipStep step="address_issued" onSkip={onSkip} testId="mailbox-skip" />
      </Step>
    );
  }

  if (phase.kind === "backfill") {
    return (
      <Step
        testId="mailbox-backfill"
        embedded={embedded}
        title={BACKFILL_COPY.title}
        intro={BACKFILL_COPY.body}
        footer={
          <Button variant="primary" onClick={() => void startCatchUp(phase.email)}>
            {BACKFILL_COPY.action}
          </Button>
        }
      >
        <p data-testid="mailbox-connected-label" className="text-sm text-muted">
          {connectedLabel(phase.email)}
        </p>
        <SegmentedControl<`${BackfillDays}`>
          fullWidth
          value={`${backfill}`}
          onChange={(v) => setBackfill(Number(v) as BackfillDays)}
          options={BACKFILL_WINDOWS.map((w) => ({ value: `${w.days}` as `${BackfillDays}`, label: w.label }))}
        />
      </Step>
    );
  }

  if (phase.kind === "catching_up") {
    return (
      <Step
        testId="mailbox-catching-up"
        embedded={embedded}
        title={CATCHING_UP_COPY.title}
        intro={CATCHING_UP_COPY.body}
        footer={
          phase.running ? undefined : (
            <Button variant="primary" onClick={onConnected}>
              {CATCHING_UP_COPY.action}
            </Button>
          )
        }
      >
        <p data-testid="mailbox-connected-label" className="text-sm text-muted">
          {connectedLabel(phase.email)}
        </p>
        {phase.running && (
          <div className="flex items-center gap-3 text-muted" role="status">
            <PixelSpinner size={12} />
            <span className="text-sm">Reading your mailbox…</span>
          </div>
        )}
        {phase.report !== null && <CatchUpSummary report={phase.report} />}
        <Notice title="Staying up to date">
          <p>{CATCHING_UP_COPY.liveness}</p>
          <p className="text-muted">{CATCHING_UP_COPY.reviewNote}</p>
        </Notice>
      </Step>
    );
  }

  // Guidance — the first screen of the route.
  return (
    <Step
      testId="mailbox-guidance"
      embedded={embedded}
      title={BURNER_GUIDANCE_COPY.title}
      intro={BURNER_GUIDANCE_COPY.lead}
      footer={
        <>
          <Button variant="primary" disabled={creds.status === "loading"} onClick={runConnect}>
            {BURNER_GUIDANCE_COPY.action}
          </Button>
          <Button variant="ghost" onClick={onForward}>
            Forward to a ledger address instead
          </Button>
        </>
      }
    >
      <Notice title="Why a mailbox of its own" testId="mailbox-why">
        <p>{BURNER_GUIDANCE_COPY.why}</p>
      </Notice>
      <p data-testid="mailbox-unsupported" className="text-xs leading-relaxed text-muted">
        {BURNER_GUIDANCE_COPY.unsupportedBank}
      </p>
      <SkipStep step="address_issued" onSkip={onSkip} testId="mailbox-skip" />
    </Step>
  );
}

/**
 * The counts from one catch-up cycle, when a live runner produced them. Honest
 * plurals and no amount anywhere — a mailbox op carries no money on the hot
 * stream (D5), and this is a count of messages, not a total.
 */
function CatchUpSummary({ report }: { report: CycleReport }) {
  const filed = report.ops - report.review;
  const setAside = report.setAside ?? 0;
  return (
    <ul data-testid="mailbox-catchup-summary" className="text-sm text-muted flex flex-col gap-1">
      <li>{`${report.fetched} ${report.fetched === 1 ? "email" : "emails"} read`}</li>
      <li>{`${filed} filed as ${filed === 1 ? "a transaction" : "transactions"}`}</li>
      <li>{`${report.review} waiting for review`}</li>
      {report.unreadable > 0 && <li>{`${report.unreadable} ledger could not read`}</li>}
      {/*
        A first backfill is the run most likely to meet senders that are not the
        account's banks, and a count that is missing here is a count that does not
        add up on screen. Same two honest claims `SET_ASIDE_COPY.body` makes —
        nothing was written for them, nothing left the mailbox — and no promise of
        a control this screen does not carry; Settings lists them by sender.
      */}
      {setAside > 0 && (
        <li data-testid="mailbox-catchup-setaside">
          {`${setAside} not from a bank ledger recognises — nothing was written for ${
            setAside === 1 ? "it" : "them"
          }, and ${setAside === 1 ? "it is" : "they are"} still in your mailbox`}
        </li>
      )}
    </ul>
  );
}
