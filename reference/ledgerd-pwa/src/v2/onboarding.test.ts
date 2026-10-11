import { describe, expect, it } from "vitest";

import { memSecretStore } from "@ledger/client/store/store";
import type { State, Txn } from "@ledger/client/replay/state";

import {
  BACKFILL_COPY,
  FORWARDING_INSTRUCTIONS_COPY,
  HANDOFF_COPY,
  PLAN_BANNER_COPY,
  PROVIDER_PICK_COPY,
  BURNER_GUIDANCE_COPY,
  CATCHING_UP_COPY,
  MAILBOX_CONNECT_FAILURE_COPY,
  MAILBOX_ROUTE_OVERLAP_NOTICE,
  MAILBOX_SETTINGS_COPY,
  MAILBOX_SETUP_ROW_COPY,
  MAIL_ROUTE_COPY,
  MAIL_STATUS_COPY,
  ONBOARDING_STEPS,
  QUARANTINE_HELD,
  SKIPPABLE_STEPS,
  SKIP_COPY,
  RECOVERY_ENTRY_COPY,
  RECOVERY_PHRASE_COPY,
  TRUST_ONLY_YOUR_BANK,
  connectedLabel,
  decodeLocal,
  emptyFacts,
  encodeLocal,
  firstMailAt,
  isSkipped,
  loadLocalRecord,
  mailStageScreen,
  mailStatus,
  onboardingComplete,
  onboardingReducer,
  remainingSetup,
  resumeFacts,
  saveLocalRecord,
  screenFor,
  stepFor,
  type OnboardingFacts,
} from "./onboarding";

function complete(over: Partial<OnboardingFacts> = {}): OnboardingFacts {
  return {
    hasSession: true,
    accountId: "u_1",
    keysReady: true,
    banks: ["dib"],
    inboundAddress: "u-abc@in.example.com",
    forwardingDeclared: true,
    firstMailConfirmedAt: "2026-08-01T00:00:00Z",
    mailboxConnected: false,
    homeCurrency: "AED",
    skipped: [],
    mailRoute: null,
    mailProvider: null,
    setupSeen: true,
    finishedAt: null,
    ...over,
  };
}

/** The three facts a fresh device reads out of the log and the server. */
function fromTheLog(over: Partial<Parameters<typeof resumeFacts>[0]> = {}) {
  return {
    hasSession: true,
    accountId: "u_1",
    keysReady: true,
    banks: ["dib"],
    inboundAddress: "u-abc@in.example.com",
    firstMailConfirmedAt: "2026-08-01T00:00:00Z",
    homeCurrency: "AED",
    local: null,
    ...over,
  };
}

describe("stepFor", () => {
  it("is signed_out with no session, whatever else is true", () => {
    expect(stepFor(complete({ hasSession: false }))).toBe("signed_out");
  });

  it("reaches done only when every milestone is met", () => {
    expect(stepFor(complete())).toBe("done");
    expect(stepFor(complete({ setupSeen: false }))).toBe("forwarding_configured");
  });

  it("stops at a GAP rather than at the highest true milestone", () => {
    // A reinstall: the log's facts survive, the device-local ones do not. The
    // walk must stop at the forwarding step, not skip to the currency —
    // otherwise the device lands in the product with no forwarding rule set up.
    const reinstalled = complete({ forwardingDeclared: false, setupSeen: false });
    expect(stepFor(reinstalled)).toBe("address_issued");
  });

  it("walks the declared step order", () => {
    expect([...ONBOARDING_STEPS]).toEqual([
      "signed_in",
      "invited",
      "keys_secured",
      "address_issued",
      "forwarding_configured",
      "done",
    ]);
  });

  /**
   * The home currency is a setup TASK and not a step, and the difference is the
   * whole point: it is the one irreversible choice in the product (§3.7 — the
   * only remedy is deleting the account), and it used to be asked in the last
   * stretch of a corridor a person is trying to get out of. It is still
   * offered — `remainingSetup` lists it, Settings runs the same ceremony — it
   * simply cannot stand between a new account and the app.
   */
  it("does not ask for the home currency, and reaching done never needs one", () => {
    expect([...ONBOARDING_STEPS]).not.toContain("home_currency_set");
    expect(stepFor(complete({ homeCurrency: null }))).toBe("done");
    expect(remainingSetup(complete({ homeCurrency: null })).map((t) => t.id)).toEqual(["home_currency_set"]);
  });

  it("has a screen for every position", () => {
    expect(screenFor("signed_out")).toBe("sign_in");
    expect(screenFor("done")).toBe("product");
    for (const step of ONBOARDING_STEPS) expect(typeof screenFor(step)).toBe("string");
  });
});

/**
 * "Later" is an answer, and the machine has to treat it as one — without ever
 * treating it as the thing having been done.
 */
describe("skipping", () => {
  const fresh = (over: Partial<OnboardingFacts> = {}): OnboardingFacts => ({
    ...emptyFacts(),
    hasSession: true,
    accountId: "u_1",
    keysReady: true,
    ...over,
  });

  it("walks past a skipped step instead of stopping at it", () => {
    expect(stepFor(fresh())).toBe("keys_secured");
    expect(stepFor(fresh({ skipped: ["address_issued"] }))).toBe("address_issued");
  });

  it("reaches the product with every optional step skipped, and nothing else true", () => {
    const skipped = fresh({ skipped: [...SKIPPABLE_STEPS], setupSeen: true });
    expect(stepFor(skipped)).toBe("done");
    expect(screenFor(stepFor(skipped))).toBe("product");
    // The skip made nothing true. This is the whole safety property: a skipped
    // step is an unmet milestone that no longer blocks, never a met one.
    expect(skipped.banks).toEqual([]);
    expect(skipped.inboundAddress).toBeNull();
    expect(skipped.homeCurrency).toBeNull();
  });

  it("cannot be pointed at a step that creates the account", () => {
    // The gate the design keeps. `SkippableStep` is what enforces it in the
    // type system; this is the runtime half, and it is what a `skipped` array
    // decoded from an older or hand-edited record would hit.
    expect([...SKIPPABLE_STEPS]).toEqual([
      "address_issued",
      "forwarding_configured",
      "home_currency_set",
    ]);
    for (const step of ["signed_in", "invited", "keys_secured", "done"] as const) {
      expect(isSkipped({ ...fresh(), skipped: [step as never] }, step)).toBe(false);
    }
    expect(stepFor({ ...fresh({ keysReady: false }), skipped: ["keys_secured" as never] })).toBe("invited");
  });

  it("records a skip once, and never un-records one", () => {
    const once = onboardingReducer(fresh(), { type: "step_skipped", step: "address_issued" });
    expect(once.skipped).toEqual(["address_issued"]);
    expect(onboardingReducer(once, { type: "step_skipped", step: "address_issued" })).toBe(once);
  });

  it("survives a reload, because nothing else can remember a decision not to act", () => {
    const secrets = memSecretStore();
    saveLocalRecord(secrets, fresh({ skipped: ["home_currency_set"] }));
    const resumed = resumeFacts(
      fromTheLog({
        banks: [],
        inboundAddress: "u-abc@in.example.com",
        firstMailConfirmedAt: null,
        homeCurrency: null,
        local: loadLocalRecord(secrets),
      }),
    );
    expect(resumed.skipped).toEqual(["home_currency_set"]);
    // Address issued, forwarding not declared and not skipped: the walk stops
    // there, which is the gap rule still doing its job around the skips.
    expect(stepFor(resumed)).toBe("address_issued");
  });

  it("refuses a skip an older record could not have written", () => {
    // `keys_secured` was never skippable, 7 is not a step, and `banks_declared`
    // stopped being one when the bank question left the walk.
    expect(decodeLocal({ inboundAddress: null, skipped: ["keys_secured", 7, "banks_declared"] })).toEqual({
      inboundAddress: null,
      skipped: [],
      mailRoute: null,
      mailProvider: null,
      forwardingDeclared: false,
      finishedAt: null,
    });
  });
});

/**
 * The bank question left the walk. The declared list never reaches parsing —
 * templates key on the message's verified domain — so the walk stops asking
 * what mail will prove. Banks stay manageable in Settings.
 */
describe("the bank question left the walk", () => {
  it("never asks which bank", () => {
    expect(ONBOARDING_STEPS).not.toContain("banks_declared");
    // A fresh account with keys and nothing else goes straight to the address.
    const f = { ...emptyFacts(), hasSession: true, accountId: "a", keysReady: true };
    expect(stepFor(f)).toBe("keys_secured"); // next screen: address, not bank
  });

  it("an old record that skipped the bank step still decodes and is ignored", () => {
    const r = decodeLocal({ inboundAddress: null, skipped: ["banks_declared", "home_currency_set"] });
    expect(r).not.toBeNull();
    expect(r!.skipped).toEqual(["home_currency_set"]); // unknown steps filtered, not refused
  });
});

describe("what is still outstanding", () => {
  it("lists every unmet step in the walk's order, skipped or simply not reached", () => {
    expect(remainingSetup(emptyFacts()).map((t) => t.id)).toEqual([
      "address_issued",
      "forwarding_configured",
      "home_currency_set",
    ]);
  });

  it("drops a step that was done, whatever was skipped", () => {
    // Skipped AND later done (an address minted by a boot read): the list
    // reads the fact, not the button press, so it drops off on its own.
    const f = { ...emptyFacts(), inboundAddress: "u-abc@in.example.com", homeCurrency: "AED", skipped: ["address_issued" as const] };
    expect(remainingSetup(f).map((t) => t.id)).toEqual(["forwarding_configured"]);
  });

  it("reports mail as a status, and separates 'nothing yet' from 'nowhere to arrive'", () => {
    expect(mailStatus({ inboundAddress: null, firstMailConfirmedAt: null }).kind).toBe("no_route");
    expect(mailStatus({ inboundAddress: "u-a@x", firstMailConfirmedAt: null }).kind).toBe("waiting");
    expect(mailStatus({ inboundAddress: "u-a@x", firstMailConfirmedAt: "2026-08-01T00:00:00Z" })).toEqual({
      kind: "arrived",
      at: "2026-08-01T00:00:00Z",
    });
  });

  it("never asks the user to spend money", () => {
    // The step this replaced could only finish when a bank sent an email, which
    // only happens when the user pays for something. No copy on the way out may
    // reintroduce that as an instruction.
    for (const s of [...Object.values(MAIL_STATUS_COPY), ...Object.values(SKIP_COPY)]) {
      const said = `${(s as { title?: string; action?: string }).title ?? (s as { action?: string }).action ?? ""} ${
        (s as { body?: string; consequence?: string }).body ??
        (s as { consequence?: string }).consequence ??
        ""
      }`.toLowerCase();
      expect(said).not.toMatch(/make a (purchase|payment|transaction)|spend (some )?money|buy something/);
    }
  });
});

describe("onboardingReducer", () => {
  it("refuses a second home currency, by identity", () => {
    const set = onboardingReducer(emptyFacts(), { type: "home_currency_set", currency: "aed" });
    expect(set.homeCurrency).toBe("AED");
    expect(onboardingReducer(set, { type: "home_currency_set", currency: "USD" })).toBe(set);
  });

  it("refuses a malformed currency rather than storing a partial one", () => {
    const f = emptyFacts();
    expect(onboardingReducer(f, { type: "home_currency_set", currency: "AE" })).toBe(f);
  });

  it("signing out drops the session and the account and touches nothing from the log", () => {
    const after = onboardingReducer(complete(), { type: "signed_out" });
    expect(after.hasSession).toBe(false);
    expect(after.accountId).toBeNull();
    expect(after.homeCurrency).toBe("AED");
    expect(after.firstMailConfirmedAt).not.toBeNull();
  });

  it("account_deleted clears everything, including the one-shot currency", () => {
    expect(onboardingReducer(complete(), { type: "account_deleted" })).toEqual(emptyFacts());
  });

  it("returns the same object when an event changes nothing", () => {
    const f = complete();
    expect(onboardingReducer(f, { type: "forwarding_declared" })).toBe(f);
  });
});

/**
 * The resume loop, 2026-08-09: the operator declared his forward, reloaded, and
 * the walk showed "Send your bank mail here" again — `resumeFacts` re-derived
 * the declaration from mail having arrived, so the user's answer evaporated on
 * every launch until the world happened to respond.
 */
describe("the walk remembers what the user did", () => {
  it("keeps a declared forward across a reload, before any mail arrives", () => {
    // The user declares; the device reloads; no mail has ever arrived.
    const declared = onboardingReducer(emptyFacts(), { type: "forwarding_declared" });
    const resumed = resumeFacts({
      hasSession: true,
      accountId: "acct-1",
      keysReady: true,
      banks: [],
      inboundAddress: "u-x@in.example.com",
      firstMailConfirmedAt: null, // Google's confirmation still held; nothing trusted yet
      homeCurrency: "AED",
      local: decodeLocal(JSON.parse(JSON.stringify(encodeLocal(declared)))),
    });
    expect(resumed.forwardingDeclared).toBe(true);
    // THE loop: this must never again resolve to the forwarding screen.
    expect(stepFor({ ...resumed, skipped: resumed.skipped })).not.toBe("address_issued");
  });

  it("a finished device never re-enters the walk, even if a fact regresses", () => {
    const finished = resumeFacts({
      hasSession: true,
      accountId: "acct-1",
      keysReady: true,
      banks: [],
      inboundAddress: null, // regressed: address fetch failed on this launch
      firstMailConfirmedAt: null,
      homeCurrency: null,
      local: { inboundAddress: null, skipped: [], mailRoute: null, mailProvider: null, forwardingDeclared: false, finishedAt: "2026-08-09T18:00:00Z" },
    });
    expect(onboardingComplete(finished)).toBe(true);
  });

  it("a record from the previous build (no new keys) still decodes", () => {
    const r = decodeLocal({ inboundAddress: "u-x@in.example.com", skipped: ["home_currency_set"] });
    expect(r).not.toBeNull();
    expect(r!.forwardingDeclared).toBe(false);
    expect(r!.finishedAt).toBeNull();
  });

  it("holds through the operator's whole sequence: declare, reload, finish, then every later boot regressed", () => {
    // The adversarial replay, through the REAL seams — reducer events, the
    // encoder, the store, and boot's own re-save — with mail never arriving.
    // Arrival must never be what keeps the door shut.
    const secrets = memSecretStore();
    const args = (over: Partial<Parameters<typeof resumeFacts>[0]> = {}) =>
      fromTheLog({ firstMailConfirmedAt: null, homeCurrency: null, banks: [], ...over, local: loadLocalRecord(secrets) });

    // Boot 1: the walk reaches the forwarding screen and the user declares.
    let facts = resumeFacts(args());
    expect(screenFor(stepFor(facts))).toBe("forwarding");
    facts = onboardingReducer(facts, { type: "forwarding_declared" });
    saveLocalRecord(secrets, facts); // the walk's persistence effect

    // Boot 2, the reload the loop lived in: never the forwarding screen again.
    // It is the PRODUCT now rather than a further step — with mail arranged the
    // account has met every milestone, so `resumeFacts` opens the app exactly as
    // it does for a second device. (It used to be the home-currency step; that
    // ceremony is Settings' now. The loop this test guards is the same one.)
    facts = resumeFacts(args());
    saveLocalRecord(secrets, facts); // boot re-persists what it resumed
    expect(facts.forwardingDeclared).toBe(true);
    expect(screenFor(stepFor(facts))).toBe("product");

    // The user taps "Open ledger".
    facts = onboardingReducer(facts, { type: "finished", at: "2026-08-09T18:00:00Z" });
    saveLocalRecord(secrets, facts);

    // Boot 3: the projection was evicted and the address read failed — every
    // account fact regressed at once, still no mail. The record alone holds.
    facts = resumeFacts(args({ inboundAddress: null }));
    saveLocalRecord(secrets, facts); // boot re-persists again
    expect(onboardingComplete(facts)).toBe(true);

    // Boot 4: the re-save above must not have narrowed the record. One good
    // boot erasing the finish is a belt the next regressed boot reaches for
    // and does not find.
    expect(loadLocalRecord(secrets)?.finishedAt).toBe("2026-08-09T18:00:00Z");
    facts = resumeFacts(args({ inboundAddress: null }));
    expect(onboardingComplete(facts)).toBe(true);
  });

  it("does not let a finished record past a hard gate: no keys still means the recovery step", () => {
    // `finishedAt` passes only the OPTIONAL steps. A wiped browser holds no
    // keys, and a record saying "this device finished once" must not walk it
    // into a product it cannot decrypt.
    const locked = resumeFacts({
      hasSession: true,
      accountId: "acct-1",
      keysReady: false,
      banks: [],
      inboundAddress: null,
      firstMailConfirmedAt: null,
      homeCurrency: null,
      local: { inboundAddress: null, skipped: [], mailRoute: null, mailProvider: null, forwardingDeclared: false, finishedAt: "2026-08-09T18:00:00Z" },
    });
    expect(onboardingComplete(locked)).toBe(false);
    expect(screenFor(stepFor(locked))).toBe("recovery");
  });
});

describe("resumeFacts", () => {
  it("takes the home currency from the log and from nowhere else", () => {
    const f = resumeFacts(
      fromTheLog({
        inboundAddress: null,
        firstMailConfirmedAt: null,
        homeCurrency: "SAR",
        // A record carrying a currency (an older build, a hand-edited value) is
        // ignored — the log is the only authority.
        local: { ...encodeLocal(complete()), homeCurrency: "USD" } as never,
      }),
    );
    expect(f.homeCurrency).toBe("SAR");
  });

  it("takes the declared banks from the log, and an old record's bank is not one of them", () => {
    // The device-local record used to carry the bank. A build that still read
    // it would make a browser profile the authority on a fact the account owns.
    const f = resumeFacts(
      fromTheLog({
        banks: ["enbd"],
        local: { bank: "dib", forwardingDeclared: true, finishedAt: "x", inboundAddress: null } as never,
      }),
    );
    expect(f.banks).toEqual(["enbd"]);
  });

  it("lands a device with NO record at all on done when the log and the server carry the setup", () => {
    // The second-device case, at the level of the machine. `boot.test.ts` proves
    // it end to end; this is the rule it depends on.
    expect(stepFor(resumeFacts(fromTheLog()))).toBe("done");
  });

  it("still reads mail arriving as forwarding declared, on a device that remembers nothing", () => {
    // Mail in the log is evidence a second device has too. The declaration is
    // remembered where a record exists; where none does, arrival still answers,
    // and silence on both sides still reads as not declared.
    expect(resumeFacts(fromTheLog()).forwardingDeclared).toBe(true);
    expect(resumeFacts(fromTheLog({ firstMailConfirmedAt: null })).forwardingDeclared).toBe(false);
  });

  it("does not call setup finished while a milestone behind it is missing", () => {
    // The mail milestones are the whole table now, so the missing one has to be
    // a mail one: a home currency is not a milestone any more (it is a task —
    // `SKIPPABLE_STEPS`), and asserting on it here would be a check that
    // measures nothing.
    const f = resumeFacts(fromTheLog({ inboundAddress: null, firstMailConfirmedAt: null }));
    expect(f.setupSeen).toBe(false);
    expect(stepFor(f)).toBe("keys_secured");
  });

  /**
   * The other half of the same rule, and the one this change could have broken
   * silently: an account whose mail IS arranged is finished, whatever it has or
   * has not chosen for its money. That is the point of moving the currency and
   * the plan out of the walk — neither may hold a set-up account out of its app.
   */
  it("calls setup finished on an account with mail arranged and no money settings at all", () => {
    const f = resumeFacts(fromTheLog({ homeCurrency: null }));
    expect(f.setupSeen).toBe(true);
    expect(onboardingComplete(f)).toBe(true);
  });

  /**
   * The one that destroys data.
   *
   * `keysReady` is an ACCESS gate — "does this browser hold the account's keys
   * right now" — and it is false on every second device, after cleared site
   * data, after the WebKit `CryptoKey` loss, and whenever `GET /api/v1/keys`
   * fails. Deriving `setupSeen` through the whole milestone table let that one
   * false fact read as "this account was never set up": the walk resumed at the
   * recovery step (correct), and then, the moment the phrase was accepted,
   * dropped the user on the FINISH screen — which carries `BudgetSplitStep`,
   * whose "Save plan" authors a full `budget_split_set` over the plan the log
   * already holds.
   *
   * Setup history is the ACCOUNT's; key access is this device's.
   */
  it("does not read a locked key vault as an account that was never set up", () => {
    const f = resumeFacts(fromTheLog({ keysReady: false }));
    expect(f.setupSeen).toBe(true);
    // Still gated: the device does not get into the product without keys, it
    // gets the recovery step.
    expect(stepFor(f)).toBe("invited");
    expect(screenFor(stepFor(f))).toBe("recovery");
  });

  it("re-enters the product, not the finish walk, once a locked device is unlocked", () => {
    const unlocked = onboardingReducer(resumeFacts(fromTheLog({ keysReady: false })), { type: "keys_secured" });
    expect(stepFor(unlocked)).toBe("done");
    expect(screenFor(stepFor(unlocked))).toBe("product");
  });

  it("still walks a genuinely new account through setup when its keys are not ready", () => {
    // The guard on the fix: ignoring `keysReady` must not let an account with
    // nothing in its log skip the steps that put something there. The address
    // is the milestone that carries it now — the home currency stopped being
    // one when the ceremony moved to Settings, so a null one no longer proves
    // anything about whether this account was ever set up.
    const fresh = resumeFacts(
      fromTheLog({ keysReady: false, banks: [], inboundAddress: null, firstMailConfirmedAt: null, homeCurrency: null }),
    );
    expect(fresh.setupSeen).toBe(false);
    expect(stepFor(onboardingReducer(fresh, { type: "keys_secured" }))).toBe("keys_secured");
  });

  it("prefers the server's address and falls back to the cached one when offline", () => {
    const local = encodeLocal(complete());
    expect(
      resumeFacts(fromTheLog({ inboundAddress: "u-new@in.example.com", local })).inboundAddress,
    ).toBe("u-new@in.example.com");

    expect(resumeFacts(fromTheLog({ inboundAddress: null, local })).inboundAddress).toBe("u-abc@in.example.com");
  });

  it("does not send a finished device back through onboarding just because it is offline", () => {
    // The whole reason the address is cached: without it, one failed GET at
    // boot walks a fully set-up user back to the address step.
    const local = encodeLocal(complete());
    expect(stepFor(resumeFacts(fromTheLog({ inboundAddress: null, local })))).toBe("done");
  });
});

describe("the device-local record", () => {
  it("round-trips through the secret store", () => {
    const secrets = memSecretStore();
    saveLocalRecord(secrets, complete());
    expect(loadLocalRecord(secrets)).toEqual(encodeLocal(complete()));
  });

  it("reads back as null when nothing was ever written", () => {
    expect(loadLocalRecord(memSecretStore())).toBeNull();
  });

  it("refuses a partially-readable record rather than half-applying it", () => {
    expect(decodeLocal({ inboundAddress: 7 })).toBeNull();
    expect(decodeLocal(null)).toBeNull();
    expect(decodeLocal("{}")).toBeNull();
  });

  it("reads a record from the native-port build: the bank is ignored, the answers are honoured", () => {
    // The one live account has a record with `bank`, `forwardingDeclared` and
    // `finishedAt` in it. The bank is the account's fact now and stays ignored;
    // the other two are the user's answers, which this build remembers again —
    // honouring the old record is precisely what ends that account's resume
    // loop without asking its owner to answer twice.
    expect(
      decodeLocal({ bank: "dib", forwardingDeclared: true, finishedAt: "2026-08-02T00:00:00Z", inboundAddress: "u-abc@in.example.com" }),
    ).toEqual({
      inboundAddress: "u-abc@in.example.com",
      skipped: [],
      mailRoute: null,
      mailProvider: null,
      forwardingDeclared: true,
      finishedAt: "2026-08-02T00:00:00Z",
    });
  });

  it("survives unreadable JSON by re-deriving rather than throwing", () => {
    const secrets = memSecretStore();
    secrets.set("onboarding_local", "{not json");
    expect(loadLocalRecord(secrets)).toBeNull();
  });

  it("holds the address hint and the user's answers, and NOTHING else", () => {
    // Six fields, each one earning its place: the address hint (offline
    // resume), and five facts that live nowhere but this device — the steps
    // answered "later", which mail route was taken, which provider's
    // instructions were asked for, the forwarding declaration, and when this
    // device finished the walk. What must NEVER return is a fact the ACCOUNT
    // owns: a bank or a home currency stored here is a browser profile
    // overruling the log, which is what made a second device re-run setup.
    expect(Object.keys(encodeLocal(complete())).sort()).toEqual([
      "finishedAt",
      "forwardingDeclared",
      "inboundAddress",
      "mailProvider",
      "mailRoute",
      "skipped",
    ]);
  });

  it("round-trips the route answer, and an older record without one reads as null", () => {
    const secrets = memSecretStore();
    saveLocalRecord(secrets, complete({ mailRoute: "mailbox" }));
    expect(loadLocalRecord(secrets)?.mailRoute).toBe("mailbox");
    // An older record predates the field: absent reads as null (the cards
    // again), never as a refusal of the whole record.
    expect(decodeLocal({ inboundAddress: null, skipped: [], forwardingDeclared: true })?.mailRoute).toBeNull();
    // A garbage route is dropped, not stored.
    expect(decodeLocal({ inboundAddress: null, mailRoute: "imap" })?.mailRoute).toBeNull();
  });
});

/**
 * The mail-route stage (spec §3, D11): a route choice that appears only where a
 * broker is configured, a `mailbox_connected` fact whose one authority is the
 * grant, and both routes still skippable.
 */
describe("the mail route choice", () => {
  const secured = (over: Partial<OnboardingFacts> = {}): OnboardingFacts => ({
    ...emptyFacts(),
    hasSession: true,
    accountId: "u_1",
    keysReady: true,
    ...over,
  });

  it("shows the route cards at keys_secured only when a broker is configured", () => {
    // At the keys_secured position (screen 'address'), the stage screen is the
    // cards when configured and the plain address phase when not.
    expect(stepFor(secured())).toBe("keys_secured");
    expect(mailStageScreen(secured(), { mailboxConfigured: true })).toBe("route_choice");
    expect(mailStageScreen(secured(), { mailboxConfigured: false })).toBe("address");
  });

  it("shows the chosen sub-flow once the card is tapped", () => {
    expect(mailStageScreen(secured({ mailRoute: "mailbox" }), { mailboxConfigured: true })).toBe("mailbox_setup");
    expect(mailStageScreen(secured({ mailRoute: "forward" }), { mailboxConfigured: true })).toBe("address");
    // Even with a route answer, an unconfigured build never shows the mailbox
    // flow — fail-closed. The answer is inert without a broker.
    expect(mailStageScreen(secured({ mailRoute: "mailbox" }), { mailboxConfigured: false })).toBe("address");
  });

  it("records and re-settles the route answer, by identity when unchanged", () => {
    const chosen = onboardingReducer(secured(), { type: "mail_route_chosen", route: "mailbox" });
    expect(chosen.mailRoute).toBe("mailbox");
    expect(onboardingReducer(chosen, { type: "mail_route_chosen", route: "mailbox" })).toBe(chosen);
    // Re-settable until connected: open the mailbox card, back out to forwarding.
    expect(onboardingReducer(chosen, { type: "mail_route_chosen", route: "forward" }).mailRoute).toBe("forward");
  });

  it("carries the walk past BOTH mail steps when a mailbox is connected", () => {
    // A grant satisfies address_issued and forwarding_configured at once — there
    // is no address to issue and no forward to declare on this route.
    const connected = secured({ mailboxConnected: true, homeCurrency: null });
    expect(stepFor(connected)).toBe("forwarding_configured"); // next screen: the hand-off
    expect(screenFor(stepFor(connected))).toBe("finish");
  });

  it("derives mailbox_connected from the grant, never from the local route answer", () => {
    // The one-authority rule: choosing the mailbox card (a local answer) does
    // not make the milestone true. Only a grant does.
    const chosenNotConnected = secured({ mailRoute: "mailbox", homeCurrency: null });
    expect(stepFor(chosenNotConnected)).toBe("keys_secured"); // still at the stage
    const connected = onboardingReducer(chosenNotConnected, { type: "mailbox_connected" });
    expect(stepFor(connected)).toBe("forwarding_configured");
  });

  it("resumes a second device past the mail stage from the grant alone", () => {
    // No local record at all (a fresh device), a grant present, home currency in
    // the log: the walk is already at the finish, never back on the cards.
    const resumed = resumeFacts(
      fromTheLog({ inboundAddress: null, firstMailConfirmedAt: null, mailboxConnected: true, local: null }),
    );
    expect(resumed.mailboxConnected).toBe(true);
    expect(stepFor(resumed)).toBe("done");
    // And a device that could not read the grant (default false) walks the stage
    // rather than skipping it.
    const noGrant = resumeFacts(
      fromTheLog({ inboundAddress: null, firstMailConfirmedAt: null, homeCurrency: null, local: null }),
    );
    expect(noGrant.mailboxConnected).toBe(false);
    expect(stepFor(noGrant)).toBe("keys_secured");
  });

  it("mailbox_connected never un-sets, and is same-object when already true", () => {
    const on = onboardingReducer(secured(), { type: "mailbox_connected" });
    expect(on.mailboxConnected).toBe(true);
    expect(onboardingReducer(on, { type: "mailbox_connected" })).toBe(on);
  });

  it("keeps both routes skippable at the mail stage", () => {
    // Skipping address_issued (the stage's step) still walks past — the same
    // skip both cards' SkipStep dispatches. Neither route is a wall.
    expect(stepFor(secured({ skipped: ["address_issued", "forwarding_configured"], homeCurrency: null }))).toBe(
      "forwarding_configured",
    );
  });
});

/**
 * The mailbox copy, held to the same honesty rails as the encryption copy plus
 * two of its own: no "one tap"/"one popup" shrinking of the consent flow, and
 * an honest liveness sentence that never promises near-real-time on a
 * fetch-on-open lane.
 */
describe("the mailbox copy", () => {
  const instructionSentences = [
    ...Object.values(MAIL_ROUTE_COPY.mailbox),
    ...Object.values(MAIL_ROUTE_COPY.forward),
    MAIL_ROUTE_COPY.title,
    MAIL_ROUTE_COPY.intro,
    ...Object.values(BURNER_GUIDANCE_COPY),
    ...Object.values(BACKFILL_COPY),
    ...Object.values(CATCHING_UP_COPY),
  ];
  const failureSentences = Object.values(MAILBOX_CONNECT_FAILURE_COPY).flatMap((c) => [c.title, c.body, c.action]);

  it("never claims only the user can access the mailbox, or zero-access", () => {
    for (const s of [...instructionSentences, ...failureSentences]) {
      const t = s.toLowerCase();
      expect(t).not.toMatch(/only you can (access|see|read)/);
      expect(t).not.toMatch(/zero[- ]access/);
      expect(t).not.toMatch(/we (can'?t|cannot|never) (see|read|access)/);
    }
  });

  it("never shrinks the consent flow to 'one tap' or 'one popup' — least of all in the reconnect copy", () => {
    for (const s of [...instructionSentences, ...failureSentences]) {
      expect(s.toLowerCase()).not.toMatch(/one tap|one popup|one pop-up/);
    }
    // The two reconnect kinds are distinct components with distinct claims.
    expect(MAILBOX_CONNECT_FAILURE_COPY.reconnect_incomplete.body.toLowerCase()).toMatch(/already connected/);
    expect(MAILBOX_CONNECT_FAILURE_COPY.reconnect_required.body.toLowerCase()).toMatch(/no longer honours|reconnect|connect again|start it up/);
    expect(MAILBOX_CONNECT_FAILURE_COPY.reconnect_incomplete.title).not.toBe(
      MAILBOX_CONNECT_FAILURE_COPY.reconnect_required.title,
    );
  });

  it("tells the honest liveness story — catches up on open, never 'within a minute'", () => {
    expect(CATCHING_UP_COPY.liveness.toLowerCase()).toMatch(/catches up when you open it/);
    for (const s of [...instructionSentences]) {
      expect(s.toLowerCase()).not.toMatch(/within a minute|real[- ]time|instantly/);
    }
  });

  it("gives unsupported banks D6's no-heuristic honesty", () => {
    expect(BURNER_GUIDANCE_COPY.unsupportedBank.toLowerCase()).toMatch(/review item you fill in yourself/);
  });

  it("may name Gmail on the instruction surface, and does", () => {
    expect(MAIL_ROUTE_COPY.mailbox.title.toLowerCase()).toMatch(/gmail/);
  });

  it("never renders 'Connected as' with a blank address", () => {
    expect(connectedLabel("")).toBe("Mailbox connected");
    expect(connectedLabel("burner@gmail.com")).toBe("Connected as burner@gmail.com");
  });

  it("leaves the trust and quarantine copy provider-free, unchanged", () => {
    for (const s of [TRUST_ONLY_YOUR_BANK.title, TRUST_ONLY_YOUR_BANK.body, QUARANTINE_HELD.body, QUARANTINE_HELD.why]) {
      expect(s.toLowerCase()).not.toMatch(/google|gmail|icloud|outlook|yahoo|proton/);
    }
  });
});

/**
 * The "Transaction mailbox" settings copy (Task 15, D6a). Client-authored mailbox
 * rows carry NO server-verified origin, so nothing on these surfaces may imply
 * one — the blanket forbidden word is "verified" (the source label says where a
 * row came from, not that anyone vouched). The usual encryption rails apply too.
 */
describe("the mailbox settings copy", () => {
  /** Every string these surfaces render, with the two functions evaluated. */
  function collect(v: unknown, out: string[]): void {
    if (typeof v === "string") out.push(v);
    else if (typeof v === "function") {
      // The two producers: `unreadable.label(n)` and `lastCaughtUp(since)`.
      out.push(String((v as (a: unknown) => string)(1)));
      out.push(String((v as (a: unknown) => string)("2 minutes ago")));
      out.push(String((v as (a: unknown) => string)(null)));
    } else if (v !== null && typeof v === "object") {
      for (const inner of Object.values(v as Record<string, unknown>)) collect(inner, out);
    }
  }
  const settingsStrings: string[] = [];
  collect(MAILBOX_SETTINGS_COPY, settingsStrings);
  collect(MAILBOX_ROUTE_OVERLAP_NOTICE, settingsStrings);
  collect(MAILBOX_SETUP_ROW_COPY, settingsStrings);

  it("never implies a server-verified origin: the word 'verified' appears nowhere", () => {
    for (const s of settingsStrings) expect(s.toLowerCase()).not.toMatch(/verified/i);
  });

  it("keeps the encryption rails: no 'only you', no 'zero-access', no 'we can't see'", () => {
    for (const s of settingsStrings) {
      const t = s.toLowerCase();
      expect(t).not.toMatch(/only you can (access|see|read)/);
      expect(t).not.toMatch(/zero[- ]access/);
      expect(t).not.toMatch(/we (can'?t|cannot|never) (see|read|access)/);
    }
  });

  it("keeps the reconnect copy honest: it takes about a minute, never 'one tap' / 'one popup'", () => {
    const body = MAILBOX_SETTINGS_COPY.reconnect.body.toLowerCase();
    expect(body).toMatch(/about a minute/);
    for (const s of settingsStrings) expect(s.toLowerCase()).not.toMatch(/one tap|one popup|one pop-up/);
  });

  it("says where a mailbox row came from without claiming anyone vouched for it", () => {
    const note = MAILBOX_SETTINGS_COPY.sourceNote.toLowerCase();
    expect(note).toMatch(/from the mailbox you connected/);
    expect(note).toMatch(/edit/);
  });

  it("states the durable unreadable count as health, and the last-catch-up as liveness", () => {
    expect(MAILBOX_SETTINGS_COPY.unreadable.label(1).toLowerCase()).toMatch(/couldn't be read/);
    expect(MAILBOX_SETTINGS_COPY.unreadable.label(2).toLowerCase()).toMatch(/messages couldn't be read/);
    expect(MAILBOX_SETTINGS_COPY.lastCaughtUp(null).toLowerCase()).toMatch(/not caught up yet/);
    expect(MAILBOX_SETTINGS_COPY.lastCaughtUp("2 minutes ago")).toMatch(/Last caught up 2 minutes ago/);
  });
});

describe("firstMailAt", () => {
  const txn = (posted_at: string): Txn => ({ posted_at }) as unknown as Txn;

  it("is null for an empty log", () => {
    expect(firstMailAt({ txns: new Map() } as Pick<State, "txns">)).toBeNull();
  });

  it("is the EARLIEST posting, not the first inserted", () => {
    const txns = new Map<string, Txn>([
      ["b", txn("2026-08-04T00:00:00Z")],
      ["a", txn("2026-07-30T00:00:00Z")],
      ["c", txn("2026-09-01T00:00:00Z")],
    ]);
    expect(firstMailAt({ txns } as unknown as Pick<State, "txns">)).toBe("2026-07-30T00:00:00Z");
  });
});

/**
 * The warning that was deleted rather than generalised, and which the operator
 * then hit on the live deployment: a forwarded bank alert was refused with
 * "icloud.com is a forwarder, and trusting it as an outer origin would trust
 * everything relayed through it".
 *
 * The reasoning for deleting it — "the screen now offers to trust every row, so
 * the promise is no longer honoured" — was backwards. That button is why the
 * warning is needed MORE: on a provider-confirmation row `inner_domain` is empty,
 * so `trustRequest` asks for the PROVIDER'S domain in outer scope.
 */
describe("the held-mail trust warning", () => {
  it("says what pressing it on a provider's own confirmation would ask for", () => {
    const body = TRUST_ONLY_YOUR_BANK.body.toLowerCase();
    expect(TRUST_ONLY_YOUR_BANK.title).not.toBe("");
    expect(body).toMatch(/bank/);
    expect(body).toMatch(/mail provider/);
    // The consequence, not just the instruction: everything that provider relays.
    expect(body).toMatch(/everything/);
  });

  /**
   * It is true for ANY provider, so it names none — the defect the first version
   * had, and the reason it was deleted instead of widened.
   */
  it("names no provider, in either half of the copy", () => {
    for (const s of [TRUST_ONLY_YOUR_BANK.title, TRUST_ONLY_YOUR_BANK.body, QUARANTINE_HELD.body, QUARANTINE_HELD.why]) {
      expect(s.toLowerCase()).not.toMatch(/google|gmail|icloud|outlook|yahoo|proton/);
    }
  });

  /**
   * `Onboarding.test.tsx` asserts the direct-with-the-bank route's verification
   * screen never says "forwarding rule" — that user has none.
   */
  it("does not assume the user set up a forwarding rule", () => {
    expect(TRUST_ONLY_YOUR_BANK.body.toLowerCase()).not.toMatch(/forwarding rule/);
  });
});

/**
 * The encryption copy, which is the strictest text in this product: it is a
 * privacy claim made to someone who will sign a consent document.
 *
 * Spec §"The decision that overrides the request" sets the rule and explains
 * why the operator's requested sentence — "only you can access it" — will not be
 * written: bank mail arrives over SMTP in plaintext and is read in memory before
 * it is sealed, so there is a window on our machine where the plaintext exists,
 * and a live compromised server could log it. These assertions exist because
 * that sentence is exactly what a well-meaning edit reaches for.
 */
describe("the encryption copy", () => {
  const everySentence = [
    ...Object.values(RECOVERY_PHRASE_COPY),
    ...Object.values(RECOVERY_ENTRY_COPY),
  ].filter((v): v is string => typeof v === "string");

  it("never claims only the user can access their data", () => {
    for (const s of everySentence) {
      const t = s.toLowerCase();
      expect(t).not.toMatch(/only you can (access|see|read)/);
      expect(t).not.toMatch(/zero[- ]access/);
      expect(t).not.toMatch(/we (can'?t|cannot|never) (see|read|access)/);
      expect(t).not.toMatch(/nobody (but you )?(can|could) (see|read)/);
      expect(t).not.toMatch(/end[- ]to[- ]end/);
    }
  });

  // The claim that IS true, and the one it must be said next to. Stating the
  // first without the second is how "encrypted at rest" becomes "we can't see
  // it" in a reader's head.
  it("says both what encryption protects and what it does not", () => {
    expect(RECOVERY_PHRASE_COPY.whatItProtects).toMatch(/encrypted before they are stored/);
    expect(RECOVERY_PHRASE_COPY.whatItProtects.toLowerCase()).toMatch(/ciphertext/);
    expect(RECOVERY_PHRASE_COPY.whatItDoesNot.toLowerCase()).toMatch(/does see each email/);
    expect(RECOVERY_PHRASE_COPY.whatItDoesNot.toLowerCase()).toMatch(/unencrypted/);
  });

  // The consequence of losing the phrase, said plainly and without hedging.
  // "may not be able to" and "difficult to recover" are the softenings that
  // would make this untrue by implication.
  it("says the account is unrecoverable without the phrase, in both ceremonies", () => {
    for (const s of [RECOVERY_PHRASE_COPY.noWayBack, RECOVERY_ENTRY_COPY.noWayBack]) {
      expect(s.toLowerCase()).toMatch(/no copy|nothing to reset|nobody/);
      expect(s.toLowerCase()).not.toMatch(/may not|might not|difficult|contact (us|support)/);
    }
    expect(RECOVERY_PHRASE_COPY.noWayBack.toLowerCase()).toMatch(/the account is gone/);
  });

  /*
   * The phrase became a WRITE capability when the recovery authorizer landed:
   * `auth.Writers.Register` accepts a signature from a key derived from these
   * words, so anyone holding them can enrol a device that authors into the
   * user's financial log. Every string here was written when the phrase only
   * decrypted, and "these words unlock your records" reads as read-only.
   *
   * Asserted rather than left to prose because it is the sentence a later,
   * kinder edit would drop as alarming — and it is the one that changes where a
   * person decides to keep the words.
   */
  it("says the phrase can add a device that writes, on both screens", () => {
    for (const copy of [RECOVERY_PHRASE_COPY, RECOVERY_ENTRY_COPY]) {
      expect(copy.alsoWrites.toLowerCase()).toMatch(/writes? to your records/);
      expect(copy.alsoWrites.toLowerCase()).toMatch(/not just read|as well as read/);
    }
  });

  // And the enter screen's own opening no longer describes a read-only phrase:
  // the button on that screen enrols a writer.
  it("does not describe recovery as making records merely readable", () => {
    expect(RECOVERY_ENTRY_COPY.intro.toLowerCase()).toMatch(/write/);
  });

  // There is no skip, so there is no copy for one.
  it("offers nothing that sounds like a way to defer this", () => {
    for (const s of everySentence) {
      expect(s.toLowerCase()).not.toMatch(/\bskip\b|\blater\b|not now|remind me/);
    }
  });
});


/**
 * The provider answer: device-local UI state, decoded leniently, and readable by
 * nobody in the trust path.
 *
 * The machine deliberately cannot see `providers.ts` (`providers.test.ts`
 * asserts the import is absent), so it cannot validate an id against the
 * registry and must not pretend to. What it CAN do is refuse a shape no answer
 * could have, and keep an unrecognised one rather than dropping the whole
 * record — an id from a build with a different registry resolves to the generic
 * instructions, which is a working screen, not a lost one.
 */
describe("the mail provider answer", () => {
  it("round-trips through the record, and an older record without one reads as null", () => {
    const secrets = memSecretStore();
    saveLocalRecord(secrets, complete({ mailProvider: "icloud" }));
    expect(loadLocalRecord(secrets)?.mailProvider).toBe("icloud");
    expect(decodeLocal({ inboundAddress: null, skipped: [], forwardingDeclared: true })?.mailProvider).toBeNull();
  });

  it("keeps an id this build does not recognise rather than refusing the record", () => {
    const r = decodeLocal({ inboundAddress: "u-x@in.example.com", skipped: [], mailProvider: "fastmail" });
    expect(r).not.toBeNull();
    expect(r!.mailProvider).toBe("fastmail");
    // The address hint is what keeps an offline set-up device out of onboarding;
    // an unknown provider id must never cost it.
    expect(r!.inboundAddress).toBe("u-x@in.example.com");
  });

  it("reads a blank, a non-string and an absurd id as no answer at all", () => {
    for (const bad of ["", 7, null, {}, "x".repeat(65)]) {
      expect(decodeLocal({ inboundAddress: null, skipped: [], mailProvider: bad })?.mailProvider).toBeNull();
    }
  });

  it("records the pick, is re-settable, and refuses a blank", () => {
    const picked = onboardingReducer(emptyFacts(), { type: "mail_provider_chosen", provider: "gmail" });
    expect(picked.mailProvider).toBe("gmail");
    // Same object when unchanged — a re-tap is visibly a no-op.
    expect(onboardingReducer(picked, { type: "mail_provider_chosen", provider: "gmail" })).toBe(picked);
    // Re-settable: "Pick a different provider" is a control on the screen.
    expect(onboardingReducer(picked, { type: "mail_provider_chosen", provider: "icloud" }).mailProvider).toBe("icloud");
    expect(onboardingReducer(picked, { type: "mail_provider_chosen", provider: "" })).toBe(picked);
  });

  it("makes no milestone true on its own", () => {
    // It is which instructions to show, and nothing else. A device that picked
    // a provider and did nothing about it is still on the forwarding step.
    const f = { ...emptyFacts(), hasSession: true, accountId: "a", keysReady: true, inboundAddress: "u-x@in.example.com" };
    expect(stepFor({ ...f, mailProvider: "gmail" })).toBe("address_issued");
  });
});

/**
 * The two surfaces that replaced the money steps, and the sentences they are not
 * allowed to say.
 */
describe("the money setup left the walk", () => {
  const bannerSentences = Object.values(PLAN_BANNER_COPY);

  /**
   * THE honesty constraint on this banner. **v2 has no income model** — no op
   * authors one, the replay state has no field for one, and Settings → Your plan
   * is a split and a monthly total. "Set up your budget and income" is the
   * sentence a well-meaning edit reaches for, and it would send every user who
   * pressed it to a screen without the thing they were promised.
   */
  it("never promises income setup, because there is none to set up", () => {
    for (const s of bannerSentences) expect(s.toLowerCase()).not.toMatch(/\bincome\b|\bsalary\b|\bearnings\b/);
  });

  it("names what the plan screen actually holds: a monthly total and a split", () => {
    const body = PLAN_BANNER_COPY.body.toLowerCase();
    expect(body).toMatch(/monthly total/);
    expect(body).toMatch(/needs|split/);
  });

  /**
   * It is an offer, not an unfinished task. Setup IS finished by the time this
   * renders, and an account that ignores the plan keeps 50/30/20 and works.
   */
  it("does not describe itself as unfinished setup", () => {
    for (const s of bannerSentences) expect(s.toLowerCase()).not.toMatch(/finish setting up|complete your setup/);
  });
});

/**
 * The hand-off screen. The two lanes make DIFFERENT promises about speed, and
 * the mailbox one may not borrow the forwarding one's minute (spec D8: it
 * fetches while the app is open, never in the background).
 */
describe("the hand-off copy", () => {
  it("promises a minute on the forwarding lane, where SMTP delivers", () => {
    expect(HANDOFF_COPY.forwarding("u-x@in.example.com").toLowerCase()).toMatch(/within a minute/);
    expect(HANDOFF_COPY.forwarding("u-x@in.example.com")).toContain("u-x@in.example.com");
  });

  /**
   * The minute is true for mail the RULE forwards, and for nothing else. The
   * old sentence — "every transaction email that reaches <address> becomes a
   * transaction" — promised a hand-forward would be filed, and it never can be:
   * the forward's new bytes break the bank's DKIM signature, and `origin.Decide`
   * refuses the provider that signed the result. The user hears it here rather
   * than from their own held mail.
   */
  it("does not promise that anything reaching the address becomes a transaction", () => {
    const f = HANDOFF_COPY.forwarding("u-x@in.example.com").toLowerCase();
    expect(f).not.toMatch(/every transaction email that reaches/);
    expect(f).toMatch(/forward by hand does not/);
    expect(f).toMatch(/signature/);
  });

  it("never promises a minute on the mailbox lane, and says how it does catch up", () => {
    const m = HANDOFF_COPY.mailbox.toLowerCase();
    expect(m).not.toMatch(/within a minute|real[- ]time|instantly/);
    expect(m).toMatch(/catches up when you open it/);
    expect(m).toMatch(/does not fetch in the background/);
  });

  it("keeps the encryption rails on every sentence it and the forwarding screens carry", () => {
    const sentences = [
      HANDOFF_COPY.title,
      HANDOFF_COPY.intro,
      HANDOFF_COPY.mailbox,
      HANDOFF_COPY.held,
      HANDOFF_COPY.action,
      HANDOFF_COPY.forwarding("u-x@in.example.com"),
      ...Object.values(PROVIDER_PICK_COPY),
      ...Object.values(FORWARDING_INSTRUCTIONS_COPY),
    ];
    for (const s of sentences) {
      const t = s.toLowerCase();
      expect(t).not.toMatch(/only you can (access|see|read)/);
      expect(t).not.toMatch(/zero[- ]access/);
      expect(t).not.toMatch(/we (can'?t|cannot|never) (see|read|access)/);
      expect(t).not.toMatch(/one tap|one popup|one pop-up/);
    }
  });

  /**
   * The picker's honesty, in the copy rather than only in the layout: the list
   * is a shortcut to exact taps, never a statement about which providers work.
   * The uniform row shape is the other half, and `ProviderPick.test.tsx` holds
   * that one.
   */
  it("says the provider list is a shortcut, not a compatibility claim", () => {
    const intro = PROVIDER_PICK_COPY.intro.toLowerCase();
    expect(intro).toMatch(/any provider/);
    expect(intro).toMatch(/only decides which instructions/);
  });
});
