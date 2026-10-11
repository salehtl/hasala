/**
 * The shell: four tabs, one gear, two drill-ins, and nothing that talks to v1.
 *
 * # What came out of the nav in Task 10, and why most of it was not deleted
 *
 * Plan, Reports, Accounts, Recurring and Projects are **unrouted, not deleted**.
 * Every one of them reads an HTTP route `ledgerd` does not serve, and that is
 * the dangerous kind of broken: the request 404s, react-query holds an error
 * nobody renders, and the screen sits there looking like it is loading. The
 * files stay because each comes back the moment its data grows a projection —
 * `client/src/replay/state.ts` holds `txns`, `rules`, `homeCurrency`, `rates`,
 * `forks` and `anomalies`, and the missing screens are exactly the ones needing
 * an op that does not exist yet. A "coming soon" placeholder would be a promise
 * with no schedule behind it; an absent screen is honest.
 *
 * v1's Settings hub, and the rules and category managers behind it, are the one
 * part that IS deleted (2026-08-10, owner's call). They did not wait for a
 * projection — they came back on one, as `settings/V2Settings.tsx` and
 * `settings/V2CategoriesPanel.tsx`, which read the projection instead of
 * `/api/settings`. Keeping the v1 originals next to their replacements bought
 * nothing but a second answer to the same question; git history has them.
 *
 * Three things left with them, and their absence is deliberate:
 *
 *  - **`IngestHealthBanner`** polls `/api/health`. There is no ingest worker in
 *    v2 — mail arrives over SMTP into the server's own log — and the health this
 *    shell can actually report is the sync row in Settings.
 *  - **`useLiveEvents`** opens an SSE stream at `/api/events` and invalidates a
 *    list of v1 query keys. v2's equivalent is a sync, and the projection moves
 *    only when one lands.
 *  - **The review badge's `/api/transactions?status=needs_review` query**, now
 *    the projection's own `needs_review` lane — the same query key the Review
 *    screen reads, so the badge and the deck can never disagree.
 *
 * # `useV2OrThrow`, and why the shell is the right place for it
 *
 * This component is unconditionally inside `<BootGate>` (see `main.tsx`), takes
 * no injected source, and used to carry a v1 fallback in `refresh` that quietly
 * invalidated HTTP queries when the gate was missing. That fallback existed
 * because this test file mounted the shell bare; the warning it logged said so.
 *
 * The screens below keep their nullable sources — those exist for their
 * injection seams, and their `null` branch is an explicit disconnected state
 * that makes no HTTP call, not a silent degradation. Asserting the invariant
 * once, here at the root, is what makes those branches unreachable in
 * production: if the gate is missing you never get as far as Review's empty
 * state, you get a stack trace naming the cause.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";

import type { SecretStore } from "@ledger/client/store/store";

import { PROFILE, useV2OrThrow } from "../v2/BootGate";
import { webSecretStore } from "../v2/session";
import { SetupStatus, type MailboxSetupState } from "../screens/onboarding/SetupStatus";
import { mailStatus, PLAN_BANNER_COPY } from "../v2/onboarding";
import { usablePlan } from "../v2/sources/budget";
import { useBudgetSnapshot, useBudgetSource } from "../v2/queries";
import { Banner } from "../components/ui/Banner";
import { browserKeyVault, type KeyVault } from "../v2/keys";
import { mailboxConfigured, readGrantStatus } from "../v2/mailboxConnect";
import { startAppShellLiveness } from "../v2/mailbox/runtime";
import { useWriter } from "../v2/writer";
import { readQuarantine } from "../v2/onboardingIO";
import { confirmationTask } from "../v2/verificationCode";
import { invalidateAfterSync, useReviewFeed, useReviewSource, v2Keys } from "../v2/queries";
import { DECK_LANES } from "../v2/sources/review";
import { BottomNav } from "../components/ui/BottomNav";
import { TopBar } from "../components/ui/TopBar";
import { type TabId } from "./nav";
import { type Scope, clampScope, scopeBounds } from "../lib/scope";
import { currentPeriod } from "../lib/insights";
import { useOnline } from "../hooks/useOnline";
import { usePullToRefresh } from "../hooks/usePullToRefresh";
import { PullToRefreshIndicator } from "../components/PullToRefreshIndicator";
import { Home } from "../screens/Home";
import { Transactions } from "../screens/Transactions";
import { Insights } from "../screens/Insights";
import { Review } from "../screens/Review";
import { Quarantine } from "../screens/Quarantine";
import { PwaUpdatePrompt } from "./PwaUpdatePrompt";
import { SettingsPage } from "../screens/settings/SettingsPage";
import { V2Settings, type Sub as SettingsSub } from "../screens/settings/V2Settings";

const TITLES: Record<TabId, string> = {
  home: "Home",
  transactions: "Transactions",
  insights: "Insights",
  review: "Review",
};

/**
 * The two surfaces hosted above the tabs as full-screen drill-ins.
 *
 * They STACK, and held mail is why: it is reachable both from Review (where its
 * count is already stated) and from Settings (where onboarding now hands off an
 * unfiled remainder). Backing out of it must reveal whichever of the two opened
 * it, which a stack gives for free and a single "current overlay" does not.
 */
type Overlay = { kind: "settings"; sub?: SettingsSub } | { kind: "quarantine" };

/**
 * Where the plan banner's dismissal is kept.
 *
 * The {@link SecretStore}, for the reason `SETUP_DISMISSED_KEY` and
 * `ONBOARDING_LOCAL_KEY` use it: it is the one durable key-value store the app
 * already has, and a dismissal that did not survive a reload would be no
 * dismissal at all. Nothing secret goes in it — it is a boolean about a strip.
 *
 * A second device does not inherit it and is offered the plan once, which is
 * correct: the banner hides itself the moment the account HAS a plan, so the
 * second device sees it only if there is genuinely nothing set.
 */
export const PLAN_BANNER_DISMISSED_KEY = "plan_banner_dismissed";

export interface AppShellProps {
  /** Test seam: where the setup list's dismissal is kept. */
  secrets?: Pick<SecretStore, "get" | "set">;
  /**
   * Test seams for the mailbox liveness scheduler (see the effect below). The
   * defaults are the real scheduler and the browser key vault; a test injects a
   * fake vault (so the effect actually fires under jsdom, which has no real one)
   * and a fake `startLiveness` to assert the scheduler starts exactly once.
   */
  startLiveness?: typeof startAppShellLiveness;
  vault?: KeyVault;
}

export function AppShell({
  secrets = webSecretStore(PROFILE),
  startLiveness = startAppShellLiveness,
  vault,
}: AppShellProps = {}) {
  const v2 = useV2OrThrow();
  const [tab, setTab] = useState<TabId>("home");
  const [overlays, setOverlays] = useState<Overlay[]>([]);
  /** Settings has one of its own drill-ins open over it. See its `onDrillChange`. */
  const [settingsDrill, setSettingsDrill] = useState(false);
  const pushOverlay = (o: Overlay) => setOverlays((s) => [...s, o]);
  const popOverlay = () => setOverlays((s) => s.slice(0, -1));

  // Lazy initializer so the default month reflects the day the app opens,
  // not the day this module was first imported.
  const [scope, setScopeState] = useState<Scope>(() => ({ kind: "month", period: currentPeriod() }));
  /**
   * The one door every scope change goes through, and it clamps.
   *
   * `TopBar` and `PeriodSheet` both clamp already, so this is the third gate on
   * the same rule — deliberately. This is the state a screen, a deep link or a
   * restored session can also write, and a scope pointing at next month frames
   * every surface in the app with a heading nothing can be under. The clock is
   * read here, at the edge; `clampScope` itself is pure.
   */
  const setScope = useCallback((next: Scope) => {
    setScopeState(clampScope(next, currentPeriod()));
  }, []);
  const online = useOnline();

  const qc = useQueryClient();
  const mainRef = useRef<HTMLElement>(null);

  /**
   * Each tab starts at its own top, and the tab you are on scrolls back to it.
   *
   * All four tabs share ONE `<main>` scroller and their children swap without a
   * key, so the scroll offset was shared between screens rather than belonging
   * to any of them: scroll a third of the way down Transactions, tap Home, and
   * Home opens a third of the way down — usually past its hero, occasionally
   * on blank space when the new screen is shorter. Nothing anywhere zeroed it.
   *
   * The second half is the convention every iOS app has: **tapping the tab you
   * are already on returns you to the top.** Without it the only way back up a
   * long transaction list is to drag it there, and the gesture people reach for
   * first does nothing at all.
   *
   * Smooth for the deliberate tap, instant for the switch — a switch is a
   * different screen, and animating the scroll of content that is being
   * replaced is motion with nothing behind it. Reduced motion is asked directly
   * because this is a native scroll, not a Framer animation: `MotionConfig`
   * does not reach it.
   */
  const navigate = useCallback(
    (next: TabId) => {
      if (next !== tab) {
        setTab(next);
        return;
      }
      const calm = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
      mainRef.current?.scrollTo({ top: 0, behavior: calm ? "auto" : "smooth" });
    },
    [tab],
  );

  useEffect(() => {
    if (mainRef.current !== null) mainRef.current.scrollTop = 0;
  }, [tab]);

  /**
   * A pull is a SYNC, not a refetch.
   *
   * The screens read the local projection, so invalidating without syncing
   * first would re-read the same rows and look broken. `run("refresh")` joins
   * whatever sync is already in flight (`SyncEngine`'s rule-3 guard), and the
   * invalidation afterwards is what tells the tree the projection moved.
   *
   * `sync.run` rather than the coordinator directly, because it never rejects: a
   * halt raised by a pull is recorded as a fault on the gate's own status and
   * reaches its wall, instead of being swallowed here.
   */
  const refresh = useCallback(async () => {
    await v2.sync.run("refresh");
    await invalidateAfterSync(qc);
  }, [v2, qc]);
  // Disabled while offline: a pull would haptic-confirm a refresh that can't fetch.
  const { pullDistance, refreshing } = usePullToRefresh(mainRef, refresh, online);

  const bounds = scopeBounds(scope);

  // The same key AND the same lanes the Review screen reads, so the badge and
  // the deck are one pass of the projection rather than two that can disagree.
  // The badge counts what the deck can answer — flagged rows and rows with no
  // category — and nothing else: a badge that counted a lane with no control
  // behind it would send the user to a screen that cannot clear it.
  // The window too, so this is literally the same query key the Review screen
  // reads and not a second pass that could disagree with it. The BADGE is still
  // whole-log: `counts` is deliberately unwindowed inside the feed, because
  // "needs a decision" is a state and not a date.
  const reviewFeed = useReviewFeed(useReviewSource(), DECK_LANES, bounds);
  const counts = reviewFeed.data?.counts;
  const reviewCount = (counts?.needs_review ?? 0) + (counts?.uncategorized ?? 0);

  // The provider's held confirmation, composed for the setup list's one-tap
  // row. Gated on mail not having arrived: once bank mail flows the forward
  // provably works, and this read would be a fetch spent answering a question
  // nobody is asking. Blobs are fetched because the link is read out of one —
  // scanned by `confirmationTask`, never rendered here.
  const mailArrived = mailStatus(v2.facts).kind === "arrived";
  const held = useQuery({
    queryKey: [...v2Keys.quarantine(), "confirmation"] as const,
    queryFn: () => readQuarantine(v2.handle.client, { includeBlob: true }),
    enabled: !mailArrived,
    staleTime: 60_000,
    refetchOnWindowFocus: false,
    // Poll while the forward is still being set up, so the confirmation card
    // surfaces as the provider's email lands rather than only on the next
    // refocus. Off the moment mail has arrived — a set-up account has answered
    // the question this read asks and must not poll forever.
    refetchInterval: mailArrived ? false : 5000,
  });
  const confirmation = useMemo(
    () => (held.data === undefined ? null : confirmationTask(held.data.items)),
    [held.data],
  );

  const writer = useWriter();

  /**
   * The plan banner: the money setup that used to be the last two things in the
   * onboarding walk, offered here instead.
   *
   * # Why it is here and not a step
   *
   * A plan is reversible and optional — an account that never sets one keeps
   * 50/30/20 and works — so it never needed a gate, and the screen it sat on
   * authored a `budget_split_set` that REPLACES the plan (see `Onboarding`'s
   * `Finish`). It is an offer now, at the top of the app, dismissible.
   *
   * # Three conditions, and every one of them is a reason not to nag
   *
   *   - `dismissed` — permanent, durable, and read once into state so a
   *     dismissal does not need a re-render of the store to take effect.
   *   - `plan === undefined` — the projection has not answered yet. A banner
   *     that flashed on every cold start before the read landed would be worse
   *     than no banner: it would appear and vanish under the user's thumb.
   *     `usablePlan` is what distinguishes "no plan" from "not read yet";
   *     `snapshot.split` cannot (`sources/budget.ts`).
   *   - `monthlyTotal !== null` — the plan IS set. The split alone cannot answer
   *     this: a usable snapshot with no plan still reports the default
   *     50/30/20, so the total is the only field that means "a person chose".
   */
  const [planBannerDismissed, setPlanBannerDismissed] = useState(
    () => secrets.get(PLAN_BANNER_DISMISSED_KEY) === "1",
  );
  const plan = usablePlan(useBudgetSnapshot(useBudgetSource()).data);
  const showPlanBanner = !planBannerDismissed && plan !== undefined && plan.monthlyTotal === null;

  /**
   * The persistent, holder-gated mailbox liveness scheduler (spec D8, Task 12/14
   * carry-forward). It belongs to the app shell, not onboarding, because
   * onboarding unmounts on "Open ledger" — the instant fetch-on-open becomes
   * useful. It re-derives the DEK + account id from the key vault exactly as
   * `MailboxSetup` does and gates every cycle on a sealed token being present, so
   * a non-holder device (or a shared-browser residual) never fetches.
   *
   * # It starts ONCE, and MUST NOT restart on a sync-progress re-render
   *
   * `v2` is the context value `BootGate` reconstructs inline on every render, and
   * it re-renders on every sync-progress phase change. An effect keyed on `[v2]`
   * would tear the scheduler down and restart it many times per sync, each
   * restart firing an immediate boot cycle whose `syncToHead` drives more
   * progress — a self-sustaining fetch/sync loop on every holder device. So this
   * depends only on `writer` (tab-lifetime-memoised on the stable handle, so it
   * transitions null→value at most once) and reads the CHANGING pieces (`sync`,
   * `handle`) live through `v2Ref`. The 60s interval is the scheduler's own.
   */
  const v2Ref = useRef(v2);
  v2Ref.current = v2;
  const activeVault = useMemo(() => vault ?? browserKeyVault(), [vault]);
  useEffect(() => {
    if (writer === null) return;
    let stop: (() => void) | null = null;
    let cancelled = false;
    void activeVault
      .read()
      .then((keys) => {
        if (cancelled || keys === null) return;
        stop = startLiveness({
          handle: v2Ref.current.handle,
          dek: keys.dek,
          accountId: keys.accountId,
          writer,
          driver: v2Ref.current.handle.driver,
          syncToHead: () => v2Ref.current.sync.run("refresh"),
        });
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
      stop?.();
    };
    // Start once per stable writer; `v2` (sync/handle) is read live via v2Ref, so
    // a sync-progress re-render must NOT re-run this. See the block comment.
  }, [writer, activeVault, startLiveness]);

  /**
   * The mailbox route's SetupStatus state (Task 15). Composed here, like the held
   * confirmation above, so `SetupStatus` stays a pure renderer: a dead grant to
   * reconnect (D10's weekly beta expiry) or a chosen-but-unconnected mailbox to
   * finish. Gated on a broker being configured — fail-closed to no row otherwise —
   * and never_connected is shown only to a device that actually chose the mailbox
   * route, so a forwarding user is never nudged toward Gmail.
   */
  // Only a device that actually took the mailbox route needs this: it chose the
  // mailbox card, or it already carries a grant. A forwarding-only user never
  // probes for a mailbox row — which is also what keeps the shell's "no HTTP on
  // an ordinary render" test true, since a fresh fixture has neither.
  const onMailboxRoute = v2.facts.mailRoute === "mailbox" || v2.facts.mailboxConnected;
  const mailbox = useQuery({
    queryKey: [...v2Keys.address(), "mailbox-setup-row"] as const,
    enabled: onMailboxRoute,
    queryFn: async (): Promise<MailboxSetupState> => {
      if (!(await mailboxConfigured(v2.handle))) return null;
      let grant: string | null;
      try {
        grant = await readGrantStatus(v2.handle);
      } catch {
        return null;
      }
      if (grant === "reconnect_required") return { kind: "reconnect_required" };
      if (grant === null && v2.facts.mailRoute === "mailbox") return { kind: "never_connected" };
      return null;
    },
    staleTime: 60_000,
    refetchOnWindowFocus: false,
  });
  const mailboxSetup = mailbox.data ?? null;

  // Drill-ins are opaque full-screen panels laid over the tabs, so everything
  // underneath is covered but still in the tab order and the screen-reader
  // cursor — Tab from the Settings back-arrow used to land on the Home rings
  // behind it. `inert` takes the covered layer out of both.
  const covered = overlays.length > 0;

  return (
    <div className="flex flex-col h-[100svh] overflow-hidden">
      <PwaUpdatePrompt />
      <div className="contents" inert={covered}>
        <TopBar
          title={TITLES[tab]}
          scope={scope}
          onScopeChange={setScope}
          /*
            The period is app-wide: all four tabs honour it, so the stepper is
            on all four. It used to be on two, because Home summed the whole log
            and the review queue was unbounded — a stepper that changed nothing
            on the tab you were looking at. Both now read it (Home windows its
            source; Review bounds the deck and counts what the period holds
            back), so the control means the same thing everywhere it appears.

            Settings is the exception the owner asked for, and it needs no flag:
            `SettingsPage` is `fixed inset-0` and covers this bar entirely.
          */
          showScope
          onOpenSettings={() => pushOverlay({ kind: "settings" })}
        />
        {!online && (
          <div role="status" className="shrink-0 bg-warn/15 text-warn text-sm text-center py-1">
            Offline — showing last loaded data
          </div>
        )}
        {/*
          Above the scroller, below the offline strip: it is chrome, and it must
          not scroll away on the screen it is offering. Its action opens Settings
          ALREADY ON the plan — a banner that dropped the user on a hub and left
          them to find the row would be a nudge that costs more than it saves.
        */}
        {showPlanBanner && (
          <Banner
            testId="plan-banner"
            title={PLAN_BANNER_COPY.title}
            body={PLAN_BANNER_COPY.body}
            action={PLAN_BANNER_COPY.action}
            dismissLabel={PLAN_BANNER_COPY.dismiss}
            onAction={() => pushOverlay({ kind: "settings", sub: "plan" })}
            onDismiss={() => {
              secrets.set(PLAN_BANNER_DISMISSED_KEY, "1");
              setPlanBannerDismissed(true);
            }}
          />
        )}
        <main ref={mainRef} className="relative flex-1 min-h-0 overflow-y-auto overscroll-contain">
          <PullToRefreshIndicator pullDistance={pullDistance} refreshing={refreshing} />
          {/* min-h-full + flex-col so a screen that wants the whole viewport can
              ask for it with flex-1 (the Review deck centres itself in the space
              rather than stranding it below the card). pb-8 gives scrollable
              screens a terminus above the nav instead of ending flush. */}
          <div className="max-w-screen-sm w-full mx-auto px-4 pt-4 pb-8 min-h-full flex flex-col">
            {tab === "home" && (
              <div className="space-y-4">
                {/*
                  The spec's "finish setting up" list and the quiet mail line,
                  on the home screen where a person actually is — Settings keeps
                  its own copy for whoever goes looking. Dismissal is shared
                  (same key, same durable store) and permanent; the `key` makes
                  this copy re-read it after the Settings overlay closes, so a
                  dismissal made there does not linger here until a remount.

                  `facts` is boot's snapshot, deliberately: everything on it that
                  can change mid-session changes through screens that re-run
                  boot or through Settings, whose own copy reads live values.
                  A task finished in Settings drops off here on the next boot,
                  and a stale extra row is the cheapest of the failure modes.
                */}
                <SetupStatus
                  key={`setup-${overlays.length}`}
                  facts={v2.facts}
                  secrets={secrets}
                  onOpenTask={() => pushOverlay({ kind: "settings" })}
                  onOpenHeldMail={() => pushOverlay({ kind: "quarantine" })}
                  confirmation={confirmation}
                  mailboxSetup={mailboxSetup}
                  onOpenMailbox={() => pushOverlay({ kind: "settings" })}
                />
                <Home scope={scope} />
              </div>
            )}
            {tab === "transactions" && <Transactions from={bounds.from} to={bounds.to} />}
            {tab === "insights" && <Insights scope={scope} />}
            {tab === "review" && (
              <Review
                scope={scope}
                onScopeChange={setScope}
                onOpenQuarantine={() => pushOverlay({ kind: "quarantine" })}
                onOpenMailboxSettings={() => pushOverlay({ kind: "settings" })}
              />
            )}
          </div>
        </main>
        <BottomNav active={tab} reviewCount={reviewCount} onNavigate={navigate} />
      </div>
      {overlays.map((o, i) => {
        // Panels stack — held mail opened from Settings leaves Settings mounted
        // beneath it — so every panel except the top one is covered too.
        const buried = i < overlays.length - 1;
        return (
          <div key={`${o.kind}-${i}`} className="contents" inert={buried}>
            {o.kind === "settings" ? (
              // `covered` is true for a panel buried by the overlay stack AND
              // for one covered by a drill-in Settings opened itself: the back
              // arrow up here stayed focusable behind those, and pressing it
              // closes the screen under the one you are looking at.
              <SettingsPage title="Settings" onClose={popOverlay} covered={buried || settingsDrill}>
                <V2Settings
                  onOpenQuarantine={() => pushOverlay({ kind: "quarantine" })}
                  onDrillChange={setSettingsDrill}
                  {...(o.sub === undefined ? {} : { initialSub: o.sub })}
                />
              </SettingsPage>
            ) : (
              <SettingsPage title="Held mail" onClose={popOverlay}>
                {/* A confirmation releases mail into the log on the SERVER; it
                    reaches this device only on a pull, so the screen is handed
                    one rather than left claiming a filing this ledger cannot
                    see yet. */}
                <Quarantine sync={refresh} />
              </SettingsPage>
            )}
          </div>
        );
      })}
    </div>
  );
}
