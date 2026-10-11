/**
 * The onboarding walk: the machine in `v2/onboarding.ts` on one side, the
 * screens on the other, and nothing else.
 *
 * # There is exactly one routing mechanism, and it is not here
 *
 * `screenFor(stepFor(facts))` decides what is on the glass. This component
 * holds no step number, no `next()` and no ordering of its own — every screen
 * reports a FACT (`address_issued`, `forwarding_configured`, …) and the position
 * falls out of the milestone table. That is what makes a force-quit free: nothing
 * here is a resume cursor that could disagree with what the log and the server say.
 *
 * The boot gate owns the layer above: it decides signed-out vs onboarding vs
 * ready, and re-derives the facts from scratch every time `done` is called. So
 * `done` is the only exit, and it is called once — when the machine reaches
 * `done`, which needs `setupSeen`, which the finish screen sets.
 *
 * # The device-local record is written on every change
 *
 * `saveLocalRecord` runs from an effect on the facts, so a tab closed between
 * two steps keeps the address it was given and every answer already given —
 * the skips, the forwarding declaration, the finish time. Everything else a
 * resumed walk needs — the banks, the currency, whether mail has arrived — is
 * in the log and on the server, which is what makes a SECOND device resume at
 * the same place rather than at the beginning (`v2/onboarding.ts`'s header).
 *
 * # Ops go through `emitMany`, and the outbox is the receipt
 *
 * The bank step and the currency step both commit by handing `Client.emitMany`
 * the specs their pure module built. Nothing here waits for a push: an op in the
 * outbox is durable (`emitMany` commits the client state before it returns), and the sync
 * engine drains it. A screen that awaited a network round trip before advancing
 * would strand an offline user on the last step of setup.
 */

import { useCallback, useEffect, useMemo, useReducer, useState } from "react";
import { useQuery } from "@tanstack/react-query";

import { Button } from "../../components/ui/Button";
import { PixelSpinner } from "../../components/ui/PixelSpinner";
import type { SecretStore } from "@ledger/client/store/store";

import {
  HANDOFF_COPY,
  mailStageScreen,
  onboardingReducer,
  saveLocalRecord,
  screenFor,
  stepFor,
  type BackfillDays,
  type MailRoute as MailRouteChoice,
  type OnboardingFacts,
  type SkippableStep,
} from "../../v2/onboarding";
import { runMailboxCatchUp } from "../../v2/mailbox/runtime";
import type { CycleReport } from "../../v2/mailbox/fetch";
import { writerFor } from "../../v2/writer";
import { mailboxConfiguredStrict as probeMailboxConfigured } from "../../v2/mailboxConnect";
import { PROFILE, SERVER } from "../../v2/BootGate";
import { readQuarantine, type TokenSource } from "../../v2/onboardingIO";
import { providerFor } from "../../v2/providers";
import { confirmationTask, type ConfirmationTask } from "../../v2/verificationCode";
import { webSecretStore, type V2Handle } from "../../v2/session";
import { browserKeyVault, keyStatus, type KeyStatus, type KeyVault } from "../../v2/keys";
import { Address } from "./Address";
import { MailRoute } from "./MailRoute";
import { MailboxSetup } from "./MailboxSetup";
import { RecoveryPhrase } from "./RecoveryPhrase";
import { OPEN_CONFIRMATION_COPY } from "./SetupStatus";
import { Notice, Step } from "./Shell";

export interface OnboardingProps {
  handle: V2Handle;
  /** Where the walk resumes from, as `boot()` re-derived it. */
  facts: OnboardingFacts;
  /** The boot gate's `again`. Called once the machine reaches `done`. */
  done: () => void;
  /** Injected by tests. */
  fetch?: typeof fetch;
  secrets?: SecretStore;
  server?: string;
  /** Injected by tests. Defaults to the browser's IndexedDB key vault. */
  vault?: KeyVault;
  /**
   * Pulls the log to head. The boot gate hands this walk a `sync` for exactly
   * this reason (`BootGateProps.onboarding`): nothing else in the tree pulls
   * while onboarding is on screen, and the mailbox catch-up must see a peer
   * device's ops before it authors (D5 dedup).
   *
   * Optional, and the default is a no-op rather than a guess: on a walk with no
   * sync wired the catch-up still runs, it simply authors against whatever this
   * device already holds — which on a device mid-onboarding is the whole log.
   */
  syncToHead?: () => Promise<void>;
  /**
   * Whether this deployment has a mailbox broker — the switch the route-choice
   * card is gated on (spec §2.3). Injected by tests; defaults to a same-origin
   * `GET /grant` probe (`mailboxConnect.mailboxConfiguredStrict`) that resolves
   * an authoritative answer and THROWS on a transient one, so the stage can
   * retry the transient before failing closed to the forwarding route alone.
   */
  mailboxConfigured?: (handle: V2Handle, deps?: { fetch?: typeof fetch }) => Promise<boolean>;
  /**
   * The two mailbox boundaries a jsdom test cannot cross: the consent ceremony
   * (which calls `window.open`) and the catch-up cycle (which mints a Google
   * token). Both default to the shipped implementation.
   *
   * These are PROPS and not `vi.mock` on purpose. Vitest runs under Bun here
   * (`process.versions.bun`), and Bun imports real modules natively rather than
   * through vitest's module runner — so `vi.mock` of a source module never takes
   * effect and its factory is never called. It fails SILENTLY: the test keeps
   * running, against the real module. `Onboarding.mailbox.test.tsx` mocked both
   * of these for weeks and was really driving the live ceremony into jsdom's
   * unimplemented `window.open`. An injected prop cannot fail that way.
   */
  connect?: (dek: CryptoKey, accountId: string) => Promise<{ email: string }>;
  /** See {@link connect}. Receives the deps the walk assembles. */
  catchUp?: typeof runMailboxCatchUp;
}

export function Onboarding({
  handle,
  facts: initial,
  done,
  fetch: doFetch,
  secrets,
  server = SERVER,
  vault,
  syncToHead,
  mailboxConfigured = probeMailboxConfigured,
  connect,
  catchUp = runMailboxCatchUp,
}: OnboardingProps) {
  const [facts, dispatch] = useReducer(onboardingReducer, initial);
  const step = stepFor(facts);
  /**
   * Stable across renders, both of them, and for the same reason.
   *
   * `MailboxSetup` reads the vault ONCE from a mount effect keyed on the vault
   * object; an inline `browserKeyVault()` in the JSX would be a new object every
   * render and re-fire that read forever. `pullToHead` is a dependency of the
   * catch-up runner below, which is itself a `useCallback`.
   */
  const activeVault = useMemo(() => vault ?? browserKeyVault(), [vault]);
  const pullToHead = useMemo(() => syncToHead ?? (async (): Promise<void> => undefined), [syncToHead]);
  /**
   * The forwarding claim, and the flag this walk no longer keeps.
   *
   * `Address` still reports whether the chosen provider is expected to email a
   * confirmation code, because that decides what its own screen says. Nothing
   * downstream reads it any more: the step that used to — a wait for the code
   * and then for a bank alert — is gone, and the provider's confirmation is now
   * a task the user does from Held mail whenever it turns up. A value with no
   * reader is dropped here rather than carried as state that looks meaningful.
   */
  const declareForwarding = useCallback((_expectConfirmation: boolean) => {
    dispatch({ type: "forwarding_declared" });
  }, []);

  /** The route-choice screen, and the mailbox flow's "forward instead" escape. */
  const chooseRoute = useCallback((route: MailRouteChoice) => {
    dispatch({ type: "mail_route_chosen", route });
  }, []);

  /**
   * The provider picker's answer. Device-local UI state, persisted by the same
   * effect that persists the route and the skips — so a reload lands on the
   * instructions rather than back on the list, and the hand-off screen still
   * knows whether this provider sends a confirmation.
   */
  const chooseProvider = useCallback((provider: string) => {
    dispatch({ type: "mail_provider_chosen", provider });
  }, []);

  /**
   * The mailbox flow's final Continue. It advances the machine past both mail
   * steps — deliberately here and not the instant the grant appears, so the
   * backfill and catching-up screens are not unmounted mid-flow. See
   * `MailboxSetup`'s header.
   */
  const declareConnected = useCallback(() => {
    dispatch({ type: "mailbox_connected" });
  }, []);

  /**
   * "Set this up later", from whichever step asked.
   *
   * The one piece of policy: **skipping the address skips the forwarding step
   * too.** They are one subject — here is your address, now send mail to it —
   * and the forwarding screen with no address on it is a page of instructions
   * pointing at nothing. Keeping the rule here rather than in `Address` means
   * the two steps' relationship is stated once, next to the table it is derived
   * from.
   */
  const skip = useCallback((step: SkippableStep) => {
    dispatch({ type: "step_skipped", step });
    if (step === "address_issued") dispatch({ type: "step_skipped", step: "forwarding_configured" });
  }, []);

  useEffect(() => {
    saveLocalRecord(secrets ?? webSecretStore(PROFILE), facts);
  }, [facts, secrets]);

  useEffect(() => {
    // The one exit. `done` re-runs boot, which re-derives these same facts from
    // the log, the server and the record just written — so the hand-off cannot
    // disagree with what this component believed.
    if (step === "done") done();
  }, [step, done]);

  const io = {
    ...(server === "" ? {} : { server }),
    ...(doFetch === undefined ? {} : { fetch: doFetch }),
  };

  /*
    There is no `commit` here any more, and its absence is the point.

    The walk used to author two things: the home-currency ops and, from the
    finish screen's plan control, a `budget_split_set`. Both left with the
    screens that emitted them (see `onboarding.ts`'s `SKIPPABLE_STEPS` and
    `Finish` below), so **onboarding now appends nothing to the op log at all**.
    On a repo whose highest-risk code is op authoring, a corridor that authors
    nothing is one fewer place a malformed op can be minted — and the two
    surfaces that do author these ops, in Settings, are the ones a user reaches
    deliberately rather than while trying to get into the app.
  */

  switch (screenFor(step)) {
    case "recovery":
      return (
        <RecoveryStep
          handle={handle}
          vault={vault ?? browserKeyVault()}
          server={server}
          {...(doFetch === undefined ? {} : { fetch: doFetch })}
          onSecured={() => dispatch({ type: "keys_secured" })}
        />
      );

    /*
      BOTH mail positions go through `MailStep`, and that is a FIX, not tidiness.

      `address` and `forwarding` are the two screens the mail stage can be on,
      and the route choice belongs in front of whichever one the user actually
      reaches first. Routing only `address` through it made the route-choice
      screen unreachable on every online deployment: `boot` reads
      `GET /api/v1/address`, that read MINTS the address, so `inboundAddress` is
      never null by the time the walk mounts, so `address_issued` is already met
      and the machine is at `forwarding` before a single frame is drawn. Every
      test of the card passed and no user could ever see it — found by
      `v2explore.mjs` walking the real stack with `--gmail-fixtures`, which is
      the only thing in this repo that could have found it.

      An auto-minted address is not an answer to "how should your bank mail
      reach ledger?". It is a resource the server hands out whether or not
      anybody intends to use it.
    */
    case "address":
    case "forwarding":
      return (
        <MailStep
          handle={handle}
          facts={facts}
          phase={screenFor(step) === "address" ? "address" : "forwarding"}
          mailboxConfigured={mailboxConfigured}
          vault={activeVault}
          syncToHead={pullToHead}
          connect={connect}
          catchUp={catchUp}
          onChoose={chooseRoute}
          onConnected={declareConnected}
          onIssued={(address) => dispatch({ type: "address_issued", address })}
          onForwardingDeclared={declareForwarding}
          onProviderChosen={chooseProvider}
          onSkip={skip}
          {...io}
        />
      );

    case "finish":
      return (
        <Finish
          facts={facts}
          client={handle.client}
          {...io}
          // The dispatch flows through the same effect that persists every
          // other answer (`saveLocalRecord` above), and that effect runs
          // before the `done` hand-off — so the finish time is on disk before
          // the walk unmounts.
          onFinish={() => dispatch({ type: "finished", at: new Date().toISOString() })}
        />
      );

    // `sign_in`, `confirming` and `product` are the boot gate's, not this
    // component's. Reaching one means the gate routed here on facts that no
    // longer say "onboarding", so the honest answer is to hand control back
    // rather than render a step whose preconditions are not met.
    case "sign_in":
    case "confirming":
    case "product":
      return (
        <Step title="Finishing setup" testId="onboarding-handback">
          <div className="flex items-center gap-3 text-muted" role="status">
            <PixelSpinner size={12} />
            <span className="text-sm">One moment…</span>
          </div>
        </Step>
      );
  }
}

/**
 * The mail stage at the `keys_secured` position: the route choice, the chosen
 * sub-flow, or — when no broker is configured — the plain address phase.
 *
 * The broker probe is a fetch, so it lands after first paint. Until it does the
 * screen shows a brief loading state rather than guessing a route: flashing the
 * address phase and then swapping to the cards would be the worse jank, and the
 * probe is one fast same-origin call.
 *
 * # A transient first byte is retried, not read as "no broker"
 *
 * The probe ({@link mailboxConfiguredStrict}) separates an AUTHORITATIVE answer
 * (a real HTTP status — a mounted route, or the unmounted mux's bare `404`) from
 * a TRANSIENT failure (offline, no session yet, a dropped request), which it
 * throws rather than folding to `false`. So this uses react-query with a bounded
 * retry — the same shape the Settings row's probe uses — and a transient error
 * is retried instead of hiding the route card from a user whose only problem was
 * a flaky first byte. Only once the retries are spent does it fail closed: an
 * exhausted probe, like an authoritative "not configured", resolves to no card
 * and the forwarding phase alone.
 */
function MailStep({
  handle,
  facts,
  phase,
  mailboxConfigured,
  vault,
  syncToHead,
  onChoose,
  onConnected,
  onIssued,
  onForwardingDeclared,
  onProviderChosen,
  onSkip,
  server,
  fetch: doFetch,
  connect,
  catchUp,
}: {
  handle: V2Handle;
  facts: OnboardingFacts;
  /** Which half of `Address` stands behind the route choice. See the caller. */
  phase: "address" | "forwarding";
  mailboxConfigured: (handle: V2Handle, deps?: { fetch?: typeof fetch }) => Promise<boolean>;
  /** Where `MailboxSetup` reads the DEK + account id on mount. Memoised by the caller. */
  vault: KeyVault;
  /** Pulls the log to head before the catch-up authors. See `OnboardingProps`. */
  syncToHead: () => Promise<void>;
  onChoose: (route: MailRouteChoice) => void;
  onConnected: () => void;
  onIssued: (address: string) => void;
  onForwardingDeclared: (expectConfirmation: boolean) => void;
  onProviderChosen: (id: string) => void;
  onSkip: (step: SkippableStep) => void;
  server?: string;
  fetch?: typeof fetch;
  /** See `OnboardingProps.connect` — injected, because `vi.mock` cannot work here. */
  connect?: (dek: CryptoKey, accountId: string) => Promise<{ email: string }>;
  /** See `OnboardingProps.catchUp`. */
  catchUp: typeof runMailboxCatchUp;
}) {
  // A bounded retry over the transient, then fail-closed. `retry` overrides the
  // provider default (tests pin `retry: false`) precisely so this hardening is
  // exercised, not silently disabled; a resolving probe (authoritative) never
  // reaches a retry, so a `false` answer still shows no card in one round.
  const probe = useQuery({
    queryKey: ["onboarding", "mailbox-configured"],
    queryFn: () => mailboxConfigured(handle, doFetch === undefined ? {} : { fetch: doFetch }),
    retry: 3,
    retryDelay: (attempt) => Math.min(150 * 2 ** attempt, 1000),
    staleTime: 5 * 60_000,
  });
  const configured: boolean | null = probe.isPending ? null : (probe.data ?? false);

  /**
   * The catch-up the catching-up screen says is happening.
   *
   * # Why it is assembled HERE and not in `MailboxSetup`
   *
   * `MailboxRuntimeDeps` is two halves. The account's DEK + id are the screen's,
   * because the WebKit gesture rule makes it read them on mount anyway — so they
   * come back in as the runner's second argument rather than being read twice.
   * Everything else is the WALK's: the handle, the writer keyed on it, this
   * device's projection driver and the gate's pull. Building them here keeps
   * `MailboxSetup` a screen with an injected runner — the shape its own tests
   * already drive — instead of a screen that reaches into the runtime.
   *
   * `writerFor`, not `useWriter`: onboarding renders OUTSIDE the boot gate's
   * `V2Provider` (the provider wraps `ready` only), so the hook would answer
   * `null` here. It is the same per-handle writer the app gets, from the same
   * `WeakMap` — a second one would split the optimistic store in two (`writer.ts`).
   *
   * The chosen window is not an argument to the cycle: `MailboxSetup` persists it
   * to the mailbox state row before it calls this, and `planFetch` reads
   * `backfillDays` from there — so the days are ignored here rather than passed
   * down a second path that could disagree with the stored one.
   *
   * `runFetchCycle` never rejects; a report with `haltedOn` is how a failure
   * arrives, and the screen renders counts either way.
   */
  const runCatchUp = useCallback(
    (_days: BackfillDays, creds: { dek: CryptoKey; accountId: string }): Promise<CycleReport> =>
      catchUp({
        handle,
        dek: creds.dek,
        accountId: creds.accountId,
        writer: writerFor(handle),
        driver: handle.driver,
        syncToHead,
      }),
    [handle, syncToHead, catchUp],
  );

  const addressIO = {
    ...(server === undefined ? {} : { server }),
    ...(doFetch === undefined ? {} : { fetch: doFetch }),
  };

  const addressPhase = (
    <Address
      client={handle.client}
      phase={phase}
      known={facts.inboundAddress}
      provider={facts.mailProvider}
      onProviderChosen={onProviderChosen}
      onIssued={onIssued}
      onForwardingDeclared={onForwardingDeclared}
      onSkip={onSkip}
      {...addressIO}
    />
  );

  if (configured === null) {
    return (
      <Step title="One moment" testId="mail-route-loading">
        <div className="flex items-center gap-3 text-muted" role="status">
          <PixelSpinner size={12} />
          <span className="text-sm">Getting things ready…</span>
        </div>
      </Step>
    );
  }

  const stage = mailStageScreen(facts, { mailboxConfigured: configured });
  if (stage === "route_choice") {
    return <MailRoute onChoose={onChoose} onSkip={() => onSkip("address_issued")} />;
  }
  if (stage === "mailbox_setup") {
    return (
      <MailboxSetup
        handle={handle}
        vault={vault}
        {...(connect === undefined ? {} : { connect })}
        runCatchUp={runCatchUp}
        onConnected={onConnected}
        onForward={() => onChoose("forward")}
        onSkip={() => onSkip("address_issued")}
      />
    );
  }
  return addressPhase;
}

/**
 * The recovery step, with the one question it has to answer first: does the
 * ACCOUNT already have keys?
 *
 * Both ceremonies live in `RecoveryPhrase`, and which one it shows is decided by
 * `keyStatus` — so the read happens here rather than in the boot gate, whose
 * `keysReady` deliberately collapses the three states into one boolean. A
 * `ready` answer at this point means another tab finished the ceremony while
 * this one sat on the step; reporting the fact is the right response to that,
 * not rendering a screen asking for keys that already exist.
 */
function RecoveryStep({
  handle,
  vault,
  server,
  fetch: doFetch,
  onSecured,
}: {
  handle: V2Handle;
  vault: KeyVault;
  server: string;
  fetch?: typeof fetch;
  onSecured: () => void;
}) {
  const [status, setStatus] = useState<KeyStatus | null>(null);
  const [failed, setFailed] = useState(false);
  /**
   * Bumped by "Try again", and a dependency of the read below.
   *
   * Explicit, rather than resting on the effect happening to re-run: `vault`
   * defaults to `browserKeyVault()` called inline in the JSX, so it is a new
   * object on every render and the read already re-fires more often than it
   * looks like it does. Depending on that accident to drive a retry would be a
   * retry that stops working the day someone memoises the prop.
   */
  const [attempt, setAttempt] = useState(0);
  const io = useMemo(
    () => ({
      sessionToken: handle.client.sessionToken,
      server,
      ...(doFetch === undefined ? {} : { fetch: doFetch }),
    }),
    [handle, server, doFetch],
  );

  useEffect(() => {
    let live = true;
    void keyStatus(handle.client.userId, vault, io).then(
      (s) => {
        if (!live) return;
        // A read that lands clears the wall. Without this the screen was
        // one-way: `failed` was only ever set to true, so a device that came
        // back online — and whose next read succeeded — kept the "could not
        // reach the server" notice on the glass with nothing behind it.
        setFailed(false);
        if (s.kind === "ready") onSecured();
        else setStatus(s);
      },
      () => {
        if (live) setFailed(true);
      },
    );
    return () => {
      live = false;
    };
  }, [handle, vault, io, onSecured, attempt]);

  if (failed) {
    return (
      /*
       * A refusal with a way out of it, on the same screen.
       *
       * This branch used to render a title and a `Notice` and nothing else — no
       * footer, no skip (the recovery step is deliberately not skippable), no
       * sign-out. The only escape was force-quitting the app, which is what the
       * copy asked for. The product principles name this exact shape: "Never let
       * a security rule become a dead end. Every refusal needs a next action on
       * the same screen." The sibling ceremony in `RecoveryPhrase` already gives
       * the identical failure a "Try again"; this is the same button.
       */
      <Step
        title="Setting up encryption"
        testId="onboarding-recovery-unavailable"
        footer={
          <Button
            variant="primary"
            onClick={() => {
              setFailed(false);
              setAttempt((n) => n + 1);
            }}
          >
            Try again
          </Button>
        }
      >
        <Notice tone="danger" announce title="ledger could not reach the server">
          <p>
            Setting up encryption needs one call to the server, and this device could not make it. Nothing is lost —
            try again when you have a connection, or reopen ledger later and this step will pick up where it left off.
          </p>
        </Notice>
      </Step>
    );
  }

  if (status === null) {
    return (
      <Step title="Setting up encryption" testId="onboarding-recovery">
        <div className="flex items-center gap-3 text-muted" role="status">
          <PixelSpinner size={12} />
          <span className="text-sm">One moment…</span>
        </div>
      </Step>
    );
  }

  return (
    <RecoveryPhrase
      accountId={handle.client.userId}
      vault={vault}
      io={io}
      published={status.kind === "needs_recovery" ? status.published : null}
      onSecured={onSecured}
    />
  );
}

/**
 * The hand-off, and the reason `setupSeen` is a fact at all.
 *
 * Mail is now the last thing the walk arranges, and the milestone behind this
 * screen goes true the instant the user says the forward is set up — so without
 * `setupSeen` the screen explaining what happens next would be skipped in the
 * same frame it appeared. It is in-memory because it is about what this person
 * has been shown in this session, not about the account; on a device that has
 * never seen it for an account that is already set up, `resumeFacts` treats the
 * prerequisites being met as answer enough, so a second phone opens the app.
 *
 * # What used to be on this screen and is not any more
 *
 * A `BudgetSplitStep` and a statement importer. Neither is setup — both are
 * reversible, both are in Settings, and one of them AUTHORS `budget_split_set`,
 * an op that REPLACES the plan. That is how a locked device walked onto this
 * screen and wiped a monthly total set on another phone (`onboarding.ts`'s
 * `accountSetupComplete`). The plan is offered by the app shell's banner
 * instead, where a person is not mid-ceremony and a mis-tap costs nothing.
 *
 * # The confirmation is a task here, not a gate
 *
 * A provider that emails a code before it will forward anything leaves one
 * thing to do that ledger cannot do for the user, and §3.2 holds that message
 * rather than filing it — the provider signed it, not the bank. So this screen
 * reads Held mail and offers the link when there is one to offer. It offers
 * NOTHING when the chosen provider sends no confirmation (iCloud), and it never
 * blocks: "Open ledger" is always the primary action, present from first paint,
 * whatever the read does.
 */
function Finish({
  facts,
  client,
  server,
  fetch: doFetch,
  onFinish,
}: {
  facts: OnboardingFacts;
  client: TokenSource;
  server?: string;
  fetch?: typeof fetch;
  onFinish: () => void;
}) {
  /*
    Whether to look for a confirmation at all.

    Three conditions, and every one of them removes a promise the screen would
    otherwise be making. The mailbox lane has no forwarder and therefore no
    confirmation. A provider the user never picked (a skipped step, a resumed
    device) is `providerFor(null)` — the GENERIC set, whose conservative `true`
    would put a "your provider sent you something" heading in front of somebody
    who set nothing up. And a provider we have evidence sends none is iCloud.
  */
  const expectsConfirmation =
    !facts.mailboxConnected && facts.mailProvider !== null && providerFor(facts.mailProvider).needsConfirmation;
  const [confirmation, setConfirmation] = useState<ConfirmationTask | null>(null);

  useEffect(() => {
    if (!expectsConfirmation) return;
    let cancelled = false;
    void (async () => {
      try {
        const page = await readQuarantine(
          client,
          { includeBlob: true },
          {
            ...(server === undefined ? {} : { server }),
            ...(doFetch === undefined ? {} : { fetch: doFetch }),
          },
        );
        if (!cancelled) setConfirmation(confirmationTask(page.items));
      } catch {
        // The hand-off stands on its own; a task that cannot be built is simply
        // not offered. It is never a reason to keep the user on this screen.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [expectsConfirmation, client, server, doFetch]);

  return (
    <Step
      testId="onboarding-finish"
      title={HANDOFF_COPY.title}
      intro={HANDOFF_COPY.intro}
      footer={
        <Button variant="primary" onClick={onFinish}>
          {HANDOFF_COPY.action}
        </Button>
      }
    >
      {/*
        The provider's confirmation, when there is one in the lane: the rule is
        already made and the tap is all that is left. Same words as the setup
        list — imported, not forked. A status, never an error. The verified
        domain is shown verbatim, as evidence.
      */}
      {confirmation !== null && (
        <Notice title={OPEN_CONFIRMATION_COPY.title} testId="finish-confirmation">
          <p>{OPEN_CONFIRMATION_COPY.body}</p>
          {confirmation.url !== null && (
            <Button
              variant="secondary"
              onClick={() => void window.open(confirmation.url ?? "", "_blank", "noopener")}
            >
              {OPEN_CONFIRMATION_COPY.action}
            </Button>
          )}
          <p data-testid="finish-confirmation-domain" className="text-xs text-muted">
            {confirmation.domain}
          </p>
        </Notice>
      )}

      <Notice title="What happens now">
        {/*
          The two lanes make DIFFERENT promises about how fast mail lands, and
          collapsing them into one sentence is how the mailbox lane would end up
          claiming a minute it cannot deliver (spec D8: it fetches while the app
          is open, and never in the background).
        */}
        <p>
          {facts.mailboxConnected
            ? HANDOFF_COPY.mailbox
            : HANDOFF_COPY.forwarding(facts.inboundAddress ?? "your ledger address")}
        </p>
        <p>{HANDOFF_COPY.held}</p>
      </Notice>
    </Step>
  );
}
