/**
 * Fresh-device recovery, driven end to end in a real browser.
 *
 * # What this proves that no unit test can
 *
 * Phase 3 rests on one claim about a browser: **a profile whose site data has
 * been cleared, given twelve words, gets its keys back.** Every layer of that is
 * a real browser behaviour — IndexedDB really being gone, a `CryptoKey` really
 * refusing to export, WebAuthn really finding a discoverable credential — and
 * jsdom simulates none of them. So this drives Chromium against the real Go
 * server, on a scratch database and scratch ports, and does the whole ceremony:
 *
 *   1. Create an account against a freshly minted, single-use invite, with a
 *      CDP virtual authenticator standing in for a platform passkey.
 *   2. Walk the recovery step: capture the twelve words, confirm that **nothing
 *      is stored while they are still on the glass**, and press through so the
 *      device publishes and stores its keys.
 *   3. **Attempt to export the stored private key material** and confirm the
 *      browser refuses. This is the non-extractability proof, in Chromium
 *      rather than in Node's WebCrypto.
 *   4. Declare a bank from Settings, so the account has content, and let it
 *      reach the server.
 *   5. **Throw the browser context away.** New context, empty IndexedDB, empty
 *      localStorage — the same authenticator, because "I cleared my site data"
 *      is not "I lost my phone".
 *   6. Sign in, meet the enrolment wall, type the phrase, and confirm the keys
 *      come back — the same ingest public key, usable handles — and that the
 *      account's existing data reads and that this device can write again.
 *
 * # Two steps this file used to walk no longer exist (2026-08-12)
 *
 * It filled a **type-three-words-back quiz** and pressed "Finish setting up
 * encryption". `0baf410` ("onboarding proposes, it never blocks") deleted both:
 * there is no `recovery-confirm-*` field and no such button anywhere in
 * `web/src` now, and the one press on that screen is "I have written these
 * down". It then declared a bank on an onboarding **bank step** that was removed
 * on 2026-08-10, when templates started keying on the verified sending domain.
 * So it timed out on the quiz, and this file was dead for two days while still
 * looking like a passing runner.
 *
 * The repair is not a new copy of the walk. **The walk now comes from
 * `v2nav.mjs`'s {@link ceremony}**, which is the one place in this directory
 * that describes onboarding, so the next screen that changes breaks one file
 * instead of four. What is left here is only what is peculiar to recovery: the
 * vault, the wipe, and the phrase. The bank moved to the path a user has today —
 * Settings › Your banks — which also proves a Settings-authored op survives the
 * wipe, a slightly stronger claim than the onboarding step made.
 *
 * The quiz's disappearance costs one assertion, and it is not replaceable: no
 * run can check that the user really wrote the words down, because the product
 * deliberately stopped asking. What replaced it is the check at step 2 — the
 * vault is empty while the words are on screen — which is the honest half that
 * IS observable: the phrase is offered before anything depends on it.
 *
 * # Running it
 *
 *   harness/v2stack.sh up                 # cluster + ledgerd + vite, prints an invite
 *   bun harness/recovery.mjs <invite>
 *   harness/v2stack.sh down
 *
 * `v2stack.sh` exists because this used to need four hand-run commands, which
 * is why this file went unrun by its own code reviewer.
 *
 * `localhost` and not `127.0.0.1`: WebAuthn requires a secure context, and
 * `localhost` is one over plain HTTP while a bare IP is not.
 *
 * # This file runs Chromium only, and that was a bug for months
 *
 * WebAuthn cannot be automated in WebKit, so the ceremony cannot be driven
 * there. That is a real limit — but it meant the ONE part of the ceremony that
 * differs by engine, the key vault, was never checked on the engine every iOS
 * device runs. `harness/vault.mjs` is the answer: it does the vault round trip
 * in Chromium AND WebKit, needs no passkey, and is the run that would have
 * caught the loop this file was green through. Run both.
 */

import { chromium } from "playwright";

import { ceremony, closeOverlay, newSignedOutContext, openSettings, ORIGIN, settle } from "./v2nav.mjs";

const INVITE = process.argv[2];
if (!INVITE) {
  console.error("usage: bun harness/recovery.mjs <invite-code>");
  process.exit(2);
}

const steps = [];
function ok(what, detail = "") {
  steps.push({ what, detail });
  console.log(`  ok  ${what}${detail ? ` — ${detail}` : ""}`);
}
function fail(what, detail) {
  console.error(`FAIL  ${what}${detail ? ` — ${detail}` : ""}`);
  process.exitCode = 1;
  throw new Error(`${what}: ${detail}`);
}

/** Is there a key set in this browser's vault at all? */
async function vaultHasKeys(page) {
  return page.evaluate(async () => {
    const keys = await import("/src/v2/keys.ts");
    return (await keys.browserKeyVault().read()) !== null;
  });
}

/**
 * Declare a bank the way a user does today: Settings › Your banks › tap one.
 *
 * The onboarding bank step this replaces was removed on 2026-08-10. The picker
 * is the same component in both places — `BankPicker`, whose rows are
 * `<idPrefix>-row-<bank>` — so the only thing that changed is which screen it is
 * on, and Settings is now the only one it is on.
 */
async function declareBank(page, bank) {
  await openSettings(page);
  await page.getByRole("button", { name: /^Your banks/ }).first().click();
  await page.getByTestId("settings-bank-picker").waitFor({ timeout: 30_000 });
  await page.getByTestId(`settings-bank-row-${bank}`).click();
  await settle(page, 400);
  await closeOverlay(page); // out of the drill-in
  await closeOverlay(page); // out of Settings
}

/**
 * Runs the app's own sync coordinator, and waits for it.
 *
 * `emitMany` is durable the moment it returns — the op is in the outbox and a
 * restart keeps it — but it does NOT upload, and the onboarding walk
 * deliberately does not block on a round trip (a step that awaited the network
 * would strand an offline user mid-setup). The next sync TRIGGER drains it,
 * and in the product that is the verification step, which this run stops short
 * of. So the harness triggers one itself, through `engineFor` — the same
 * memoised coordinator the gate uses, not a second client.
 */
async function drainOutbox(page) {
  return page.evaluate(async () => {
    const { openV2, engineFor } = await import("/src/v2/BootGate.tsx");
    const result = await engineFor(await openV2()).run("harness");
    return { pulled: result?.pulled ?? null, applied: result?.applied ?? null, halted: result?.halted ?? null };
  });
}

/** How many op rows the account's hot stream holds, read over the live session. */
async function opCount(page) {
  return page.evaluate(async () => {
    const token = Object.entries(localStorage).find(([k]) => k.includes("session"))?.[1] ?? null;
    const res = await fetch("/api/v1/sync?stream=hot&after=0", { headers: { Authorization: `Bearer ${token}` } });
    return ((await res.json()).rows ?? []).length;
  });
}

/**
 * Drains until the server actually holds `atLeast` rows, or gives up.
 *
 * ONE `run()` is not enough and assuming it was made this file flaky: the
 * coordinator serialises, so a call that lands while the gate's own launch sync
 * is still in flight returns without draining anything, and the very next
 * assertion read a log that was one row short. Polling asserts the PROPERTY —
 * the op reaches the server — rather than the mechanism that happened to
 * deliver it on the first attempt.
 */
async function waitForOps(page, atLeast, what) {
  let count = 0;
  for (let attempt = 0; attempt < 30; attempt++) {
    await drainOutbox(page);
    count = await opCount(page);
    if (count >= atLeast) return count;
    await page.waitForTimeout(1000);
  }
  fail(what, `the hot stream holds ${count} row(s), want at least ${atLeast}`);
  return count;
}

/**
 * What is actually in the key vault, and whether the browser will let it out.
 *
 * Read through the app's own module rather than through a hand-rolled
 * `indexedDB.get`, because the decode rule is part of what is being checked: a
 * row that is present but does not decode is exactly the state that used to
 * strand every iOS device, and a raw `get` would have called it "present".
 */
async function inspectVault(page) {
  return page.evaluate(async () => {
    const keys = await import("/src/v2/keys.ts");
    const row = await keys.browserKeyVault().read();
    if (!row) return { present: false };

    // The ingest key is not stored as a handle any more — it is sealed under
    // the DEK, because WebKit cannot read an X25519 `CryptoKey` back out of
    // IndexedDB. So the private half is opened the way the product opens it.
    const ingest = await keys.openIngestPrivate(row);

    const exportAttempts = [];
    for (const [name, key, format] of [
      ["ingestPrivate/pkcs8", ingest, "pkcs8"],
      ["ingestPrivate/jwk", ingest, "jwk"],
      ["dek/raw", row.dek, "raw"],
      ["dek/jwk", row.dek, "jwk"],
    ]) {
      try {
        await crypto.subtle.exportKey(format, key);
        exportAttempts.push({ name, threw: false });
      } catch (e) {
        exportAttempts.push({ name, threw: true, message: String(e).slice(0, 120) });
      }
    }

    // The handles must still WORK — a key that cannot be exported and cannot be
    // used is not custody, it is a brick.
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, row.dek, new TextEncoder().encode("probe"));
    const opened = new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv }, row.dek, sealed));
    const peer = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
    const derived = new Uint8Array(
      await crypto.subtle.deriveBits({ name: "X25519", public: peer.publicKey }, ingest, 256),
    ).length;

    return {
      present: true,
      accountId: row.accountId,
      ingestPub: [...row.ingestPub].map((b) => b.toString(16).padStart(2, "0")).join(""),
      extractable: { ingestPrivate: ingest.extractable, dek: row.dek.extractable },
      exportAttempts,
      dekRoundTrip: opened,
      derivedBytes: derived,
      // What a script on this origin can actually read out of storage: the
      // honest statement of what non-extractability buys.
      localStorageDump: JSON.stringify(localStorage).length,
    };
  });
}

const browser = await chromium.launch();
let phrase;
let firstVault;

try {
  // ---------------------------------------------------------------------
  // Device one: create the account and secure the keys.
  // ---------------------------------------------------------------------
  console.log("device one — a new account");
  const one = await newSignedOutContext(browser, {});
  one.page.on("pageerror", (e) => console.error("  page error:", e.message));

  /*
   * The walk is `v2nav.mjs`'s, not this file's. `onStep` fires while each screen
   * is still on the glass, which is the only moment the mid-ceremony facts can
   * be read — and reading the vault on the phrase screen is how this run proves
   * the ORDER of the ceremony rather than just its outcome.
   *
   * `skip: true` takes "Set this up later" wherever it is offered. This run
   * needs an account with keys and one op in it, not a configured one, and the
   * skipped answers are the ones the walk persists.
   */
  let storedWhileShowing = null;
  const walked = await ceremony(one.page, INVITE, {
    skip: true,
    onStep: async (id, p) => {
      if (id === "onb-recovery") storedWhileShowing = await vaultHasKeys(p);
      /*
       * The FIRST step after the phrase, whichever it is: reaching one means the
       * keys were published and stored, because the machine refuses to walk past
       * a gap.
       *
       * Named as a set rather than as one id on purpose. It was `onb-forwarding`
       * alone, which stopped firing when the mail stage was reworked
       * (Gmail-primary: `mail-route` on a broker stack, `onb-address` or
       * `onb-provider-pick` otherwise) — and a hook that never fires leaves
       * `firstVault` undefined, which is the check-that-cannot-fail this repo
       * keeps producing. The `undefined` guard below is what catches it, and the
       * set is what stops it needing to.
       */
      const afterThePhrase = ["mail-route", "onb-address", "onb-provider-pick", "onb-forwarding-steps"];
      if (afterThePhrase.includes(id) && firstVault === undefined) firstVault = await inspectVault(p);
    },
  });

  const words = walked.phrase;
  if (words.length !== 12) fail("the phrase is twelve words", `it had ${words.length}`);
  phrase = words.join(" ");
  ok("a twelve-word phrase is shown", words.slice(0, 2).join(" ") + " …");

  // `establishAccountKeys` awaits the press before it wraps, publishes or
  // installs anything, so an empty vault here is the observable half of "the
  // phrase is offered before anything depends on it".
  if (storedWhileShowing !== false) {
    fail("nothing is stored while the words are still on the glass", `the vault read ${JSON.stringify(storedWhileShowing)}`);
  }
  ok("nothing is stored while the words are still on the glass");

  if (firstVault === undefined) fail("the walk passed the step after the phrase", "it never reached it");
  ok("the walk reaches the next step, so the keys were published and stored");
  if (!firstVault.present) fail("the key vault holds a key set", "it was empty");
  if (firstVault.extractable.ingestPrivate || firstVault.extractable.dek) {
    fail("the stored keys are non-extractable", JSON.stringify(firstVault.extractable));
  }
  const leaked = firstVault.exportAttempts.filter((a) => !a.threw);
  if (leaked.length > 0) fail("every export attempt is refused", `these did not throw: ${leaked.map((l) => l.name).join(", ")}`);
  ok("Chromium refuses all four export attempts", firstVault.exportAttempts[0].message);
  if (firstVault.dekRoundTrip !== "probe" || firstVault.derivedBytes !== 32) {
    fail("the stored handles still work", JSON.stringify({ round: firstVault.dekRoundTrip, derived: firstVault.derivedBytes }));
  }
  ok("the handles still seal, open and derive", `ingest pub ${firstVault.ingestPub.slice(0, 16)}…`);

  // Give the account some content, so recovery has something to read back.
  const beforeBank = await opCount(one.page);
  await declareBank(one.page, "dib");

  // The op has to actually REACH the server, or the second context has nothing
  // to read back and this would prove only that a local database survived.
  // Counted as a DELTA rather than against a fixed floor: the walk itself
  // authors ops now, so "at least two" would have been satisfied before the
  // bank was touched — a check that cannot fail.
  const authored = await waitForOps(one.page, beforeBank + 1, "the declared bank reaches the server");
  ok("a bank is declared from Settings and the op reaches the server", `${beforeBank} -> ${authored} rows in the hot stream`);

  // The credential itself, lifted out of the authenticator so the second
  // context can be given it. This is what models the real situation: the
  // passkey lives in the platform's keychain and survives a browser clear, so
  // "I cleared my site data" leaves the credential and destroys everything
  // else. A second context with a second, empty authenticator would model a
  // LOST DEVICE, which is a different (and unrecoverable) story.
  const { credentials } = await one.cdp.send("WebAuthn.getCredentials", { authenticatorId: one.authenticatorId });
  if (credentials.length !== 1) fail("the authenticator holds exactly one credential", `it held ${credentials.length}`);
  await one.context.close();

  // ---------------------------------------------------------------------
  // The same device, site data cleared: a genuinely empty browser profile.
  // ---------------------------------------------------------------------
  console.log("\nthe same device, site data cleared");
  const two = await newSignedOutContext(browser, {});
  await two.cdp.send("WebAuthn.addCredential", {
    authenticatorId: two.authenticatorId,
    credential: { ...credentials[0], isResidentCredential: true },
  });
  two.page.on("pageerror", (e) => console.error("  page error:", e.message));
  await two.page.goto(ORIGIN, { waitUntil: "domcontentloaded" });

  const before = await two.page.evaluate(async () => ({
    localStorage: Object.keys(localStorage).length,
    databases: (await indexedDB.databases()).map((d) => d.name),
  }));
  if (before.localStorage !== 0 || before.databases.length !== 0) {
    fail("the second context starts empty", JSON.stringify(before));
  }
  ok("the browser starts with no localStorage and no databases");

  // The credential lives in the authenticator, not in site data — which is what
  // "I cleared my browser" means and "I lost my phone" does not.
  await two.page.getByRole("button", { name: /^Sign in$/i }).click();

  /*
   * A cleared browser is also a NEW DEVICE WRITER: the writer's Ed25519
   * identity key lived in the local database that was just destroyed, and the
   * account's one TOFU self-approval was spent by the original device. So the
   * gate raises the enrolment wall before the onboarding walk.
   *
   * The wall is where the phrase is entered, and that is the whole point of the
   * recovery authorizer: one phrase, one screen, and this device gets its keys
   * AND its ability to write back with no other device involved. Until the
   * authorizer existed this run stopped here, permanently read-only.
   */
  // The phrase panel is one press behind a disclosure on the wall, not open on
  // arrival: the approval-code flow is the first path for a person who still
  // has another device, and this asks for the account's most sensitive secret.
  // The sentence that decides which path you are on stays visible next to the
  // trigger, so the affordance is discoverable rather than merely present —
  // assert it is on the glass before pressing, or this step would pass on a
  // wall that had quietly stopped offering the phrase at all.
  await two.page
    .getByText(/twelve words ledger gave you are the only way/i)
    .waitFor({ timeout: 60_000 });
  await two.page.getByTestId("recover-write-open").click();
  await two.page.getByTestId("recover-write").waitFor({ timeout: 60_000 });
  ok("a cleared browser is offered the recovery phrase on the enrolment wall");

  // A well-formed but wrong phrase is refused, and enrolls nothing.
  await two.page.getByTestId("recover-write-phrase").fill(
    "legal winner thank year wave sausage worth useful legal winner thank yellow",
  );
  await two.page.getByRole("button", { name: /Unlock this device/i }).click();
  await two.page.getByRole("alert").waitFor({ timeout: 60_000 });
  const vaultAfterWrong = await two.page.evaluate(async () => {
    const keys = await import("/src/v2/keys.ts");
    return (await keys.browserKeyVault().read()) !== null;
  });
  if (vaultAfterWrong) fail("a wrong phrase stores nothing", "the vault holds a key set");
  ok("a wrong phrase is refused, and stores nothing");

  await two.page.getByTestId("recover-write-phrase").fill(phrase);
  await two.page.getByRole("button", { name: /Unlock this device/i }).click();

  /*
   * Waited for by the ABSENCE of the wall, not the presence of a particular
   * screen. Where the app lands afterwards depends on which milestones the
   * account has answered — this run skips them, so it is not the forwarding
   * step the old code waited for — and none of that is what is under test.
   * Getting past the wall at all is: it means the server accepted an enrolment
   * authorised by nothing but the recovery key.
   *
   * Generous, because Argon2id runs between the press and the unlock.
   */
  await two.page.getByTestId("recover-write").waitFor({ state: "detached", timeout: 180_000 });
  await settle(two.page, 1200);
  ok("the phrase alone enrolls this device and gets it past the enrolment wall");

  const secondVault = await inspectVault(two.page);
  if (!secondVault.present) fail("the recovered vault holds a key set", "it was empty");
  if (secondVault.ingestPub !== firstVault.ingestPub) {
    fail("the recovered ingest key is the SAME key", `${secondVault.ingestPub} != ${firstVault.ingestPub}`);
  }
  ok("the recovered ingest public key is byte-identical to the original", secondVault.ingestPub.slice(0, 16) + "…");
  if (secondVault.extractable.ingestPrivate || secondVault.extractable.dek) {
    fail("the recovered keys are non-extractable too", JSON.stringify(secondVault.extractable));
  }
  if (secondVault.exportAttempts.some((a) => !a.threw)) fail("every export attempt on the recovered keys is refused", "");
  ok("the recovered keys are non-extractable, and every export attempt is refused");

  // ---------------------------------------------------------------------
  // And it can WRITE. This is the half the first round could not reach.
  // ---------------------------------------------------------------------
  const beforeWrite = await opCount(two.page);

  // A second bank, authored by the writer the recovery phrase just enrolled.
  await two.page.evaluate(async () => {
    // Authored through the real client, which is what the screens use: the op
    // goes to the outbox, the coordinator drains it, and the server applies it
    // under the writer this device enrolled a moment ago.
    const { openV2 } = await import("/src/v2/BootGate.tsx");
    const handle = await openV2();
    handle.client.emitMany([{ type: "bank_declared", payload: { bank: "enbd", active: true } }]);
  });
  // The op has to reach the SERVER, not merely the outbox: an op that only ever
  // existed locally would prove nothing about the enrolment being accepted.
  const afterWrite = await waitForOps(two.page, beforeWrite + 1, "an op authored after recovery reaches the server");
  ok("an op authored after recovery lands on the server", `${beforeWrite} -> ${afterWrite} rows`);

  // And it FOLDS: a row on the server that the replay engine refused would be
  // a chain this device cannot use, which is not recovery.
  const folded = await two.page.evaluate(async () => {
    const { openV2 } = await import("/src/v2/BootGate.tsx");
    const handle = await openV2();
    return [...handle.client.state().banks.entries()];
  });
  if (!folded.some(([bank, active]) => bank === "enbd" && active)) {
    fail("the op this device authored folds into its state", JSON.stringify(folded));
  }
  // And the one authored BEFORE the wipe folds too, which is the read half of
  // recovery: this device never saw that op authored, it pulled it.
  if (!folded.some(([bank, active]) => bank === "dib" && active)) {
    fail("the op authored before the wipe folds after recovery", JSON.stringify(folded));
  }
  ok("both the pre-wipe op and the post-recovery op fold into this device's state", JSON.stringify(folded));

  // The enrolment is VISIBLE as a recovery in the key-history log, which is
  // what a peer device audits. A silent one would be a key substitution nobody
  // could tell from an approval.
  const history = await two.page.evaluate(async () => {
    const token = Object.entries(localStorage).find(([k]) => k.includes("session"))?.[1] ?? null;
    const res = await fetch("/api/v1/key-history", { headers: { Authorization: `Bearer ${token}` } });
    return (await res.json()).entries ?? [];
  });
  const recoveredEntries = history.filter((e) => e.event === "recovery_registered");
  if (recoveredEntries.length !== 1) {
    fail("the recovery-authorised enrolment is in the key-history log", JSON.stringify(history.map((e) => e.event)));
  }
  ok("key_history records it as `recovery_registered`, not as an ordinary approval");

  await two.context.close();
  console.log(`\n${steps.length} checks passed.`);
} catch (err) {
  // What was actually on the glass when it gave up. Without this a timeout says
  // only "the thing I waited for never appeared", which is the least useful
  // half of the story.
  for (const page of browser.contexts().flatMap((c) => c.pages())) {
    console.error("\n--- screen at failure ---");
    console.error((await page.evaluate(() => document.body.innerText)).slice(0, 1200));
    console.error("--- test ids ---");
    console.error(await page.evaluate(() => [...document.querySelectorAll("[data-testid]")].map((e) => e.dataset.testid)));
  }
  throw err;
} finally {
  await browser.close();
}
