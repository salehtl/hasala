/**
 * The onboarding screens, driven the way a person drives them.
 *
 * Everything here mounts a REAL screen against a scripted `fetch` and a stub
 * {@link V2Handle}, because the decisions these screens make are the ones a
 * pure test cannot reach: which path a `not_invited` takes, whether the address
 * a walk lands on is the one the server minted, and whether confirming a
 * currency actually puts ops in the outbox rather than merely advancing a step.
 *
 * There is no bank screen: the bank question left the walk (templates key on
 * the message's verified domain, so mail proves the bank). Banks are managed
 * in Settings, and `V2Settings.test.tsx` covers that surface.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { SqlDriver } from "@ledger/client/store/driver";

import { MotionProvider } from "../../app/MotionProvider";
import { projectionWith } from "../../test/projectionFixture";
import { emptyFacts, loadLocalRecord, type OnboardingFacts } from "../../v2/onboarding";
import { AccountMismatchError, EnrollmentError, PasskeyError, type V2Handle } from "../../v2/session";
import type { SecretStore } from "@ledger/client/store/store";

import { Onboarding } from "./Onboarding";
import { OPEN_CONFIRMATION_COPY } from "./SetupStatus";
import { Welcome } from "./Welcome";

// ---------------------------------------------------------------------------
// Rigs
// ---------------------------------------------------------------------------

const ADDRESS = "u-7f3a91c4@in.example.com";

/**
 * A REAL projection behind every rig, because the finish screen reads one.
 *
 * The stub `{} as never` that used to sit in `driver` was fine while no step
 * touched the database, and stopped being fine the moment the plan control had
 * to read the plan the account already holds before offering to replace it —
 * which is the whole of Task 1. A stub there fails as a thrown render, not as a
 * quiet wrong answer, but the walk that reaches the finish screen is driven by
 * several tests here and all of them need it.
 */
let db: SqlDriver;

beforeEach(async () => {
  db = await projectionWith();
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

interface HandleRig {
  handle: V2Handle;
  /** Every op spec `emitMany` was handed, flattened. */
  emitted: { type: string; payload: unknown }[];
  /** What `Client.pending` reports — the outbox depth. */
  pending: { op_id: string; type: string }[];
}

function handleRig(over: { signUp?: () => Promise<void>; signIn?: () => Promise<void> } = {}): HandleRig {
  const out: HandleRig = {
    emitted: [],
    pending: [],
    handle: null as unknown as V2Handle,
  };
  out.handle = {
    signedIn: () => true,
    signUp: over.signUp ?? (async () => {}),
    signIn: over.signIn ?? (async () => {}),
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
        return out.pending;
      },
      emitMany(specs: readonly { type: string; payload: unknown }[]) {
        for (const s of specs) {
          out.emitted.push({ type: s.type, payload: s.payload });
          out.pending.push({ op_id: `op_${String(out.pending.length)}`, type: s.type });
        }
        return [];
      },
      state: () => ({ txns: new Map(), homeCurrency: null }),
    },
  } as unknown as V2Handle;
  return out;
}

/** A `fetch` that answers exactly the routes onboarding calls, and 404s the rest. */
function scriptedFetch(
  over: { quarantine?: unknown; waitlistStatus?: number; waitlistBody?: unknown; hostileTemplates?: boolean } = {},
) {
  const calls: { url: string; method: string; body: unknown }[] = [];
  const doFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? "GET";
    let body: unknown = null;
    if (typeof init?.body === "string") body = JSON.parse(init.body) as unknown;
    calls.push({ url, method, body });

    const ok = (value: unknown, status = 200): Response =>
      new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });

    if (url.includes("/api/v1/templates")) {
      return ok({
        version: "7",
        removed: [],
        templates: [
          // A template's `bank` is a free JSON string set by whoever published
          // it. Nothing on the wire holds it to the grammar `bank_declared` is
          // keyed on, so the picker has to survive both an id it cannot store
          // and one that only survives by being changed.
          ...(over.hostileTemplates === true
            ? [
                { id: "adib.card.v1", bank: "adib_uae", version: 1, normalizer_version: 1, definition: {}, status: "published" },
                { id: "dib.upper.v1", bank: "DIB", version: 1, normalizer_version: 1, definition: {}, status: "published" },
              ]
            : []),
          { id: "dib.card.v1", bank: "dib", version: 1, normalizer_version: 1, definition: {}, status: "published" },
          { id: "dib.account.v1", bank: "dib", version: 1, normalizer_version: 1, definition: {}, status: "published" },
          { id: "enbd.alert.v1", bank: "enbd", version: 1, normalizer_version: 1, definition: {}, status: "published" },
        ],
      });
    }
    if (url.includes("/api/v1/waitlist")) {
      const status = over.waitlistStatus ?? 204;
      if (status === 204) return new Response(null, { status: 204 });
      return ok(over.waitlistBody ?? { error: "invalid_bank", detail: "no" }, status);
    }
    if (url.includes("/api/v1/address")) {
      return ok({ address: ADDRESS, created_at: "2026-08-07T00:00:00Z" });
    }
    if (url.includes("/api/v1/quarantine")) {
      return ok(over.quarantine ?? { items: [], removed: [], action_needed: 0, expiring_soon: 0, complete: true });
    }
    return new Response("no route", { status: 404 });
  });
  return { doFetch: doFetch as unknown as typeof fetch, calls };
}

function mount(facts: OnboardingFacts, rig: HandleRig, doFetch: typeof fetch, done = vi.fn()) {
  const secrets = memorySecrets();
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <MotionProvider>
      <QueryClientProvider client={qc}>
        <Onboarding handle={rig.handle} facts={facts} done={done} fetch={doFetch} secrets={secrets} />
      </QueryClientProvider>
    </MotionProvider>,
  );
  return { done, secrets };
}

/**
 * Signed in, invited, and this device already holds the account keys.
 *
 * `keysReady` is true because the recovery step is covered by its own file:
 * every test here is about a step BEHIND it, and a fixture that left it false
 * would put the recovery screen on the glass for all of them.
 */
function invited(): OnboardingFacts {
  return { ...emptyFacts(), hasSession: true, accountId: "u_1", keysReady: true };
}

// ---------------------------------------------------------------------------
// Welcome
// ---------------------------------------------------------------------------

describe("Welcome", () => {
  function mountWelcome(over: Parameters<typeof handleRig>[0] = {}) {
    const rig = handleRig(over);
    const done = vi.fn();
    render(
      <MotionProvider>
        <Welcome handle={rig.handle} done={done} />
      </MotionProvider>,
    );
    return { rig, done };
  }

  it("offers both paths: an invite code to create an account, and one button to sign in", () => {
    mountWelcome();
    expect(screen.getByLabelText("Invite code")).toBeTruthy();
    expect(screen.getByRole("button", { name: /create my account/i })).toBeTruthy();
    expect(screen.getByRole("button", { name: /^sign in$/i })).toBeTruthy();
  });

  it("has no email, username or password field anywhere — sign-in is username-less", () => {
    const { container } = render(
      <MotionProvider>
        <Welcome handle={handleRig().handle} done={vi.fn()} />
      </MotionProvider>,
    );
    for (const input of Array.from(container.querySelectorAll("input"))) {
      expect(input.type).not.toBe("password");
      expect(input.type).not.toBe("email");
      expect(`${input.name} ${input.getAttribute("autocomplete") ?? ""}`.toLowerCase()).not.toMatch(
        /username|email|password/,
      );
    }
  });

  // The sign-in phase is clean now: the warning moved to the `created` phase on
  // 2026-08-14, where the second-passkey offer it points at actually is. The
  // full assertion of the warning's wording lives in `qualifications.test.tsx`;
  // this one holds the sign-in screen to NOT carrying it, so the removal cannot
  // be quietly undone.
  it("does not put the recovery warning on the sign-in screen", () => {
    mountWelcome();
    expect(screen.queryByTestId("recovery-warning")).toBeNull();
  });

  it("renders the not-invited copy when the server refuses the code, and keeps the field", async () => {
    const user = userEvent.setup();
    const { rig } = mountWelcome({
      signUp: () => Promise.reject(new PasskeyError("not_invited", "403 not_invited", { status: 403, code: "not_invited" })),
    });
    await user.type(screen.getByLabelText("Invite code"), "ABC123");
    await user.click(screen.getByRole("button", { name: /create my account/i }));

    await waitFor(() => {
      expect(screen.getByTestId("not-invited")).toBeTruthy();
    });
    expect(screen.getByTestId("not-invited").textContent).toMatch(/single use|one at a time/i);
    // The code is still there to correct rather than retyped from scratch.
    expect((screen.getByLabelText("Invite code") as HTMLInputElement).value).toBe("ABC123");
    expect(rig.handle).toBeTruthy();
  });

  it("keeps a later failure on the not-invited screen instead of bouncing to the front door", async () => {
    const user = userEvent.setup();
    let attempt = 0;
    mountWelcome({
      signUp: () => {
        attempt += 1;
        return Promise.reject(
          attempt === 1
            ? new PasskeyError("not_invited", "403", { status: 403, code: "not_invited" })
            : new PasskeyError("rate_limited", "429", { status: 429, code: "rate_limited" }),
        );
      },
    });

    await user.type(screen.getByLabelText("Invite code"), "ABC123");
    await user.click(screen.getByRole("button", { name: /create my account/i }));
    await screen.findByTestId("not-invited");

    await user.click(screen.getByRole("button", { name: /try this code/i }));

    // Still here, with the code intact and the real reason on screen.
    expect(await screen.findByTestId("not-invited-failure")).toBeTruthy();
    expect(screen.getByTestId("welcome-not-invited")).toBeTruthy();
    expect((screen.getByLabelText("Invite code") as HTMLInputElement).value).toBe("ABC123");
  });

  /** Signs in as a different account than this browser profile is bound to. */
  function mountMismatch(pending: { op_id: string; type: string }[]) {
    const rig = handleRig({ signIn: () => Promise.reject(new AccountMismatchError("u_old", "u_new")) });
    rig.pending = pending;
    const wipe = vi.fn(async () => {});
    render(
      <MotionProvider>
        <Welcome handle={rig.handle} done={vi.fn()} wipe={wipe} />
      </MotionProvider>,
    );
    return { rig, wipe };
  }

  it("offers to clear the browser when this profile holds another account", async () => {
    const user = userEvent.setup();
    const { rig, wipe } = mountMismatch([]);

    await user.click(screen.getByRole("button", { name: /^sign in$/i }));

    const notice = await screen.findByTestId("account-mismatch");
    // The reassurance, in its narrow and true form.
    expect(notice.textContent).toMatch(/already.*synced.*safe on the server/is);
    // With nothing unsynced there is no warning and no arming step.
    expect(screen.queryByTestId("unsynced-warning")).toBeNull();

    await user.click(screen.getByRole("button", { name: /clear this browser's data/i }));
    await waitFor(() => {
      expect(wipe).toHaveBeenCalledWith(rig.handle);
    });
  });

  it("never promises nothing was lost when unsynced work would be destroyed", async () => {
    const user = userEvent.setup();
    const { wipe } = mountMismatch([
      { op_id: "o1", type: "txn_add" },
      { op_id: "o2", type: "txn_categorize" },
    ]);

    await user.click(screen.getByRole("button", { name: /^sign in$/i }));

    const warning = await screen.findByTestId("unsynced-warning");
    expect(warning.textContent).toMatch(/2 changes have never been sent/i);
    expect(warning.textContent).toMatch(/permanently/i);
    // The old, false blanket reassurance must not be anywhere on the screen.
    expect(document.body.textContent).not.toMatch(/untouched on the server/i);

    // Destructive and unrecoverable, so it is inert until acknowledged.
    const clear = screen.getByRole("button", { name: /clear this browser's data/i });
    expect(clear).toHaveProperty("disabled", true);
    await user.click(clear);
    expect(wipe).not.toHaveBeenCalled();

    await user.click(screen.getByRole("checkbox", { name: /unsent work will be destroyed/i }));
    await user.click(clear);
    await waitFor(() => {
      expect(wipe).toHaveBeenCalled();
    });
  });

  it("treats an unreadable outbox as risky rather than as empty", async () => {
    const user = userEvent.setup();
    const rig = handleRig({ signIn: () => Promise.reject(new AccountMismatchError("u_old", "u_new")) });
    Object.defineProperty(rig.handle.client, "pending", {
      get() {
        throw new Error("store is degraded");
      },
    });
    render(
      <MotionProvider>
        <Welcome handle={rig.handle} done={vi.fn()} wipe={vi.fn(async () => {})} />
      </MotionProvider>,
    );

    await user.click(screen.getByRole("button", { name: /^sign in$/i }));

    const warning = await screen.findByTestId("unsynced-warning");
    expect(warning.textContent).toMatch(/cannot tell whether/i);
    expect(screen.getByRole("button", { name: /clear this browser's data/i })).toHaveProperty("disabled", true);
  });

  it("signs in with one button and no argument at all", async () => {
    const user = userEvent.setup();
    const signIn = vi.fn(async () => {});
    const { done } = mountWelcome({ signIn });
    await user.click(screen.getByRole("button", { name: /^sign in$/i }));
    await waitFor(() => {
      expect(done).toHaveBeenCalled();
    });
    expect(signIn).toHaveBeenCalledWith();
  });

  /**
   * A SECOND device: the passkey works, the session lands, and only the writer
   * enrolment is refused (spec §3.4 — no enrolled key signed for it). Reporting
   * that as "the server refused the request, nothing was created on this
   * device" is false twice over, and it is what made a second device a dead
   * end. The gate owns this state, so the screen hands off.
   */
  it("hands an enrolment refusal to the boot gate instead of calling sign-in failed", async () => {
    const user = userEvent.setup();
    const signIn = vi.fn(async () => {
      throw new EnrollmentError("rejected", "403 registration_rejected");
    });
    const { done } = mountWelcome({ signIn });
    await user.click(screen.getByRole("button", { name: /^sign in$/i }));
    await waitFor(() => {
      expect(done).toHaveBeenCalled();
    });
    expect(screen.queryByTestId("welcome-failure")).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// The recovery step, when the one call it needs does not land
// ---------------------------------------------------------------------------

/**
 * This step is NOT skippable — `SKIPPABLE_STEPS` deliberately leaves it out,
 * because an account with no keys has nowhere to put data. That makes it the one
 * screen in the walk where a refusal with no next action is a locked door rather
 * than an inconvenience: the only way off it was force-quitting the app, which
 * is what its own copy asked the user to do.
 */
describe("the recovery step when the server cannot be reached", () => {
  /** No stored handles, so `keyStatus` has nothing to fall back on and rethrows. */
  const emptyVault = () => ({ read: async () => null, write: async () => {}, clear: async () => {} });

  function mountOffline(over: { keys?: () => Response } = {}) {
    const rig = handleRig();
    let keyReads = 0;
    const doFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url.includes("/api/v1/keys")) {
        keyReads += 1;
        if (over.keys !== undefined) return over.keys();
        throw new TypeError("Failed to fetch");
      }
      return new Response("no route", { status: 404 });
    });
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    render(
      <MotionProvider>
        <QueryClientProvider client={qc}>
          <Onboarding
            handle={rig.handle}
            facts={{ ...emptyFacts(), hasSession: true, accountId: "u_1", keysReady: false }}
            done={vi.fn()}
            fetch={doFetch as unknown as typeof fetch}
            secrets={memorySecrets()}
            vault={emptyVault()}
          />
        </QueryClientProvider>
      </MotionProvider>,
    );
    return { reads: () => keyReads };
  }

  it("offers a way forward on the same screen instead of asking the user to quit the app", async () => {
    mountOffline();
    await screen.findByTestId("onboarding-recovery-unavailable");
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });

  it("actually retries the read when that button is pressed", async () => {
    const user = userEvent.setup();
    const { reads } = mountOffline();
    await screen.findByTestId("onboarding-recovery-unavailable");
    const before = reads();
    await user.click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => expect(reads()).toBeGreaterThan(before));
  });

  it("does not tell the user to reopen the app as their only option", async () => {
    mountOffline();
    const wall = await screen.findByTestId("onboarding-recovery-unavailable");
    // The sentence may still OFFER a relaunch; what it may not do is be the only
    // thing on the screen. Guarded by the button assertion above, this one keeps
    // the copy honest about there being something to press.
    expect(within(wall).getByText(/try again when you have a connection/i)).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Address → forwarding
// ---------------------------------------------------------------------------

describe("the address walk", () => {
  it("goes straight from the key ceremony to the address — no bank question", async () => {
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    mount(invited(), rig, doFetch);

    await waitFor(() => {
      expect(screen.getByTestId("inbound-address").textContent).toBe(ADDRESS);
    });
    expect(screen.queryByTestId("bank")).toBeNull();
    // Nothing was asked, so nothing was authored on the way here.
    expect(rig.emitted).toEqual([]);
  });

  /**
   * The forwarding route, end to end through the real machine — and the step
   * that used to sit at the end of it.
   *
   * This walked the DIRECT route until that route was retired
   * (`Address.DIRECT_BANK_ROUTE`). It is the same walk either way: both routes
   * always ended at the one `forwarding_declared` fact, which is what this test
   * is actually about.
   *
   * Declaring the forward once walked the user onto a screen that waited for a
   * real bank alert, i.e. for them to spend money. Nothing about the product
   * needed that, and two unrelated bugs in that one screen locked the operator
   * out of his own app in a day. The walk now carries on, and whether mail is
   * actually arriving is reported as a status the user can read whenever they
   * like.
   */
  it("carries on past the forwarding step instead of waiting for a bank email", async () => {
    const user = userEvent.setup();
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    mount({ ...invited(), inboundAddress: ADDRESS, mailProvider: "gmail" }, rig, doFetch);

    await user.click(await screen.findByRole("button", { name: /i have set up forwarding/i }));

    // No waiting screen, on a log with no transaction in it.
    expect(screen.queryByTestId("verification")).toBeNull();
    expect(document.body.textContent).not.toMatch(/waiting for your first bank email/i);
    // The hand-off, which is the last screen now: the home-currency ceremony
    // moved to Settings, so nothing stands between a declared forward and the
    // app but one button.
    expect(await screen.findByTestId("onboarding-finish")).toBeInTheDocument();
    expect(rig.emitted).toEqual([]);
  });

  /**
   * The provider question, in the production wiring: the walk asks it, and the
   * answer is written to the device-local record — which is what stops a reload
   * asking it again.
   */
  it("asks which provider, and remembers the answer on disk", async () => {
    const user = userEvent.setup();
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    const { secrets } = mount({ ...invited(), inboundAddress: ADDRESS }, rig, doFetch);

    await user.click(await screen.findByTestId("provider-pick-icloud"));
    await screen.findByTestId("provider-steps-icloud");
    await waitFor(() => {
      expect(loadLocalRecord(secrets)?.mailProvider).toBe("icloud");
    });
  });
});

// ---------------------------------------------------------------------------
// The hand-off
// ---------------------------------------------------------------------------

/**
 * The last screen of the walk, and the two things it stopped doing.
 *
 * It carried a `BudgetSplitStep` whose "Save plan" authors a `budget_split_set`
 * — an op that REPLACES the plan — and a statement importer. Every device that
 * had to secure keys used to land here: a second phone, a cleared browser, a
 * failing `GET /api/v1/keys`. `resumeFacts` stopped routing them here, and this
 * is the other half: there is now nothing on this screen that can author
 * anything at all, so the class of bug cannot recur through a third route.
 *
 * The home-currency ceremony left the walk with them, for a different reason:
 * it is the one IRREVERSIBLE choice in the product (§3.7), and the end of a
 * corridor somebody is trying to get out of is the worst place to ask for one.
 * It is Settings' now, and `V2Settings.test.tsx` covers it there.
 */
describe("the hand-off screen", () => {
  function atFinish(over: Partial<OnboardingFacts> = {}): OnboardingFacts {
    return {
      ...invited(),
      banks: ["dib"],
      inboundAddress: ADDRESS,
      forwardingDeclared: true,
      firstMailConfirmedAt: "2026-08-01T00:00:00Z",
      homeCurrency: "AED",
      ...over,
    };
  }

  it("asks for no money settings, and offers no control that authors an op", async () => {
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    mount(atFinish(), rig, doFetch);
    await screen.findByTestId("onboarding-finish");

    expect(screen.queryByLabelText(/Needs/)).toBeNull();
    expect(screen.queryByLabelText(/monthly budget/i)).toBeNull();
    expect(screen.queryByRole("button", { name: /save plan/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /import a statement/i })).toBeNull();
    expect(rig.emitted).toEqual([]);
  });

  /**
   * The whole walk authors nothing now. Asserted on the OUTBOX rather than on
   * the absence of a particular control, because that is the property that
   * matters: a corridor that appends nothing cannot mint a malformed op, and on
   * this repo op authoring is the highest-risk code there is.
   */
  it("reaches the app from a fresh account with an empty outbox", async () => {
    const user = userEvent.setup();
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    mount(atFinish({ homeCurrency: null }), rig, doFetch);
    await screen.findByTestId("onboarding-finish");
    await user.click(screen.getByRole("button", { name: /open ledger/i }));
    expect(rig.emitted).toEqual([]);
    expect(rig.pending).toEqual([]);
  });

  it("promises a minute on the forwarding lane and names the address", async () => {
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    mount(atFinish(), rig, doFetch);
    const step = await screen.findByTestId("onboarding-finish");
    expect(step.textContent).toContain(ADDRESS);
    expect(step.textContent).toMatch(/within a minute/i);
  });

  /**
   * The mailbox lane fetches while the app is open and never in the background
   * (spec D8), so it may not borrow the forwarding lane's minute. One screen,
   * two lanes, two different promises.
   */
  it("never promises a minute on the mailbox lane", async () => {
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    mount(atFinish({ inboundAddress: null, mailboxConnected: true, mailRoute: "mailbox" }), rig, doFetch);
    const step = await screen.findByTestId("onboarding-finish");
    expect(step.textContent).not.toMatch(/within a minute/i);
    expect(step.textContent).toMatch(/catches up when you open it/i);
  });

  /**
   * The provider's confirmation, as the operator asked for it: a link to press
   * when there is one, and NOTHING when the provider does not send one.
   *
   * The held page below is the live Gmail confirmation's shape — the same body
   * `verificationCode.test.ts` scans. §3.2 holds it rather than filing it,
   * because the provider signed it and not the bank, so this is the one thing
   * ledger cannot do on the user's behalf.
   */
  const CONFIRM_URL = "https://mail-settings.google.com/mail/vf-%5BANGjdJ8abcDEF123%5D-XyZ0";
  const HELD_PAGE = {
    items: [
      {
        id: "held-1",
        ingest_id: "ing-1",
        received_at: "2026-08-09T15:15:34Z",
        expires_at: "2026-09-08T15:15:34Z",
        outer_domain: "google.com",
        inner_domain: "",
        attested: false,
        attested_by: "",
        dkim: "pass",
        arc: "pass",
        size_bucket: 1,
        blob: Buffer.from(
          [
            "From: Gmail Team <forwarding-noreply@google.com>",
            "Subject: (#123456789) Gmail Forwarding Confirmation",
            "",
            "Confirmation code: 123456789",
            "",
            "To allow it, click the link below:",
            CONFIRM_URL,
            "",
          ].join("\r\n"),
          "utf8",
        ).toString("base64"),
      },
    ],
    action_needed: 1,
    expiring_soon: 0,
  };

  it("offers the held confirmation when the chosen provider sends one", async () => {
    const rig = handleRig();
    const { doFetch } = scriptedFetch({ quarantine: HELD_PAGE });
    mount(atFinish({ mailProvider: "gmail" }), rig, doFetch);

    const notice = await screen.findByTestId("finish-confirmation");
    expect(notice.textContent).toContain(OPEN_CONFIRMATION_COPY.title);
    // The verified signing domain, verbatim, as the evidence it is.
    expect(screen.getByTestId("finish-confirmation-domain").textContent).toBe("google.com");
    expect(screen.getByRole("button", { name: OPEN_CONFIRMATION_COPY.action })).toBeInTheDocument();
    // And it never becomes a gate: the way into the app is on screen throughout.
    expect(screen.getByRole("button", { name: /open ledger/i })).toBeInTheDocument();
  });

  /**
   * iCloud is the one provider with evidence that it sends no confirmation at
   * all. Offering a code affordance there would leave the user waiting for a
   * message nobody is going to send — the exact bug the provider registry was
   * built to end.
   */
  it("offers nothing at all when the chosen provider sends no confirmation", async () => {
    const rig = handleRig();
    const { doFetch, calls } = scriptedFetch({ quarantine: HELD_PAGE });
    mount(atFinish({ mailProvider: "icloud" }), rig, doFetch);

    await screen.findByTestId("onboarding-finish");
    await waitFor(() => {
      expect(screen.getByRole("button", { name: /open ledger/i })).toBeInTheDocument();
    });
    expect(screen.queryByTestId("finish-confirmation")).toBeNull();
    // Not merely hidden: the read is never made, so there is no fetch spent on
    // a question this lane cannot have.
    expect(calls.filter((c) => c.url.includes("/api/v1/quarantine"))).toEqual([]);
  });

  it("offers nothing on the mailbox lane, which has no forwarder to confirm", async () => {
    const rig = handleRig();
    const { doFetch, calls } = scriptedFetch({ quarantine: HELD_PAGE });
    mount(atFinish({ inboundAddress: null, mailboxConnected: true, mailProvider: "gmail" }), rig, doFetch);

    await screen.findByTestId("onboarding-finish");
    expect(screen.queryByTestId("finish-confirmation")).toBeNull();
    expect(calls.filter((c) => c.url.includes("/api/v1/quarantine"))).toEqual([]);
  });

  /**
   * A device that skipped the mail step, or resumed without a record, has no
   * provider answer. `providerFor(null)` is the GENERIC set, whose conservative
   * `true` would put "your provider sent you something" in front of somebody who
   * set nothing up — so the absence of an answer is its own answer here.
   */
  it("offers nothing when no provider was ever picked", async () => {
    const rig = handleRig();
    const { doFetch, calls } = scriptedFetch({ quarantine: HELD_PAGE });
    mount(atFinish({ mailProvider: null }), rig, doFetch);

    await screen.findByTestId("onboarding-finish");
    expect(screen.queryByTestId("finish-confirmation")).toBeNull();
    expect(calls.filter((c) => c.url.includes("/api/v1/quarantine"))).toEqual([]);
  });

  it("puts the finish on disk BEFORE handing back, so no reload can re-enter the walk", async () => {
    // The hand-off re-runs boot, and boot believes the record. A finish that
    // reached memory but not disk is a device that "finished" until the next
    // regressed launch. The spy reads the store AT THE MOMENT `done` fires,
    // which is what pins the effect order, not just the eventual write.
    const user = userEvent.setup();
    let store: SecretStore | undefined;
    const atHandback: (string | null)[] = [];
    const done = vi.fn(() => {
      atHandback.push(store === undefined ? null : (loadLocalRecord(store)?.finishedAt ?? null));
    });
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    store = mount(atFinish(), rig, doFetch, done).secrets;

    await screen.findByTestId("onboarding-finish");
    await user.click(screen.getByRole("button", { name: /open ledger/i }));

    await waitFor(() => {
      expect(done).toHaveBeenCalled();
    });
    expect(atHandback[0]).toBeTruthy(); // on disk before the walk unmounted
    const record = loadLocalRecord(store);
    expect(record?.finishedAt).toBeTruthy();
    expect(record?.forwardingDeclared).toBe(true); // the declaration rode along
  });
});

/**
 * The mail-route stage (spec §3, D11): the route cards appear at the mail step
 * only where a broker is configured, and picking a card swaps to the sub-flow.
 * The machine, copy and each screen are covered in their own files; this is the
 * wiring — `screenFor` → `MailStep` → the right screen.
 */
describe("the mail route stage", () => {
  function mountMailProbe(probe: () => Promise<boolean>, facts: Partial<OnboardingFacts> = {}) {
    const rig = handleRig();
    const { doFetch } = scriptedFetch();
    const secrets = memorySecrets();
    // retry:false is the provider default; the probe's own `retry` overrides it,
    // which is exactly what the transient-retry test relies on.
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    render(
      <MotionProvider>
        <QueryClientProvider client={qc}>
          <Onboarding
            handle={rig.handle}
            facts={{ ...invited(), ...facts }}
            done={vi.fn()}
            fetch={doFetch}
            secrets={secrets}
            mailboxConfigured={probe}
          />
        </QueryClientProvider>
      </MotionProvider>,
    );
    return { rig };
  }

  function mountMail(configured: boolean, facts: Partial<OnboardingFacts> = {}) {
    return mountMailProbe(async () => configured, facts);
  }

  it("shows the route screen when a broker is configured", async () => {
    mountMail(true);
    expect(await screen.findByTestId("mail-route")).toBeInTheDocument();
    expect(screen.getByTestId("mail-route-mailbox")).toBeInTheDocument();
    expect(screen.getByTestId("mail-route-forward")).toBeInTheDocument();
  });

  /**
   * **The route screen was unreachable on every online deployment, and every
   * test of it passed.**
   *
   * `boot` reads `GET /api/v1/address`, and that read MINTS the address
   * (`addresses.go` permits the write and says why). So `inboundAddress` is
   * non-null before the walk mounts, `address_issued` is already met, and the
   * machine is at `forwarding` in its first frame — a position that used to
   * render `Address` directly, with no route choice anywhere in front of it.
   * Every test above mounted at `keys_secured`, which is a position a real
   * device with a working network never occupies.
   *
   * Found by `v2explore.mjs` against the real stack with `--gmail-fixtures`,
   * which is the only thing in this repo that could have found it: it walks the
   * product and reports the screens it actually sees. This is the unit-level
   * guard, and it is written from the fact that CAUSES it — an address already
   * in hand — rather than from the position, so it cannot be satisfied by
   * renaming a step.
   */
  it("shows the route screen even when boot already minted an address", async () => {
    mountMail(true, { inboundAddress: ADDRESS });
    expect(await screen.findByTestId("mail-route")).toBeInTheDocument();
    expect(screen.queryByTestId("provider-pick-list")).toBeNull();
  });

  it("lands on the provider question, not the cards, once the forward route is chosen", async () => {
    mountMail(true, { inboundAddress: ADDRESS });
    await userEvent.click(await screen.findByTestId("mail-route-forward"));
    expect(await screen.findByTestId("provider-pick-list")).toBeInTheDocument();
  });

  it("asks nothing about Gmail on a build with no broker, whatever the walk has in hand", async () => {
    mountMail(false, { inboundAddress: ADDRESS });
    expect(await screen.findByTestId("provider-pick-list")).toBeInTheDocument();
    expect(screen.queryByTestId("mail-route")).toBeNull();
    expect(document.body.textContent ?? "").not.toMatch(/gmail transaction mailbox/i);
  });

  it("shows the forwarding address phase, no cards, when no broker is configured", async () => {
    mountMail(false);
    expect(await screen.findByTestId("address")).toBeInTheDocument();
    expect(screen.queryByTestId("mail-route")).not.toBeInTheDocument();
  });

  it("swaps to the burner guidance when the mailbox card is chosen", async () => {
    mountMail(true);
    await userEvent.click(await screen.findByTestId("mail-route-mailbox"));
    expect(await screen.findByTestId("mailbox-guidance")).toBeInTheDocument();
  });

  it("swaps to the address phase when the forward card is chosen", async () => {
    mountMail(true);
    await userEvent.click(await screen.findByTestId("mail-route-forward"));
    expect(await screen.findByTestId("address")).toBeInTheDocument();
  });

  // A transient first byte must not read as "no broker": the probe throws on a
  // transient failure and the stage retries it. Mutating the retry off (treating
  // the transient as authoritative) drops straight to the address phase and
  // fails this test — which is how we know the retry bites.
  it("retries a transient probe failure and still shows the route cards", async () => {
    let calls = 0;
    const probe = vi.fn(async () => {
      calls += 1;
      if (calls === 1) throw new Error("offline");
      return true;
    });
    mountMailProbe(probe);
    expect(await screen.findByTestId("mail-route")).toBeInTheDocument();
    expect(calls).toBeGreaterThanOrEqual(2);
  });

  // An AUTHORITATIVE unconfigured answer (the probe resolves false) shows no
  // card cleanly, in one round — no retry, because there is nothing transient.
  it("shows no route cards for an authoritative unconfigured answer, and does not retry", async () => {
    const probe = vi.fn(async () => false);
    mountMailProbe(probe);
    expect(await screen.findByTestId("address")).toBeInTheDocument();
    expect(screen.queryByTestId("mail-route")).not.toBeInTheDocument();
    expect(probe).toHaveBeenCalledTimes(1);
  });
});
