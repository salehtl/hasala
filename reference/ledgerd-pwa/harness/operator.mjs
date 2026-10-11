/**
 * The operator's own path, on the operator's own engine.
 *
 * # What this reproduces and then repairs
 *
 * The iPhone loop: sign up, write down the phrase, confirm it — and land back on
 * the recovery screen, forever, with no error anywhere. Its cause is WebKit
 * losing an X25519 `CryptoKey` written to IndexedDB (see
 * `.superpowers/sdd/2026-08-08-phase3-crypto/`), so it reproduces in WebKit and
 * in no other engine, which is why the Chromium-only `recovery.mjs` was green
 * throughout.
 *
 * Two phases, one browser profile:
 *
 *   bun harness/operator.mjs signup  <invite>
 *   bun harness/operator.mjs recover
 *
 * # It was written to REPRODUCE the loop; it is now the net that catches it
 *
 * The two phases were once "run against the OLD keys.ts" and "run against the
 * NEW one", and `signup` asserted the loop as a pass. The fix has been in for
 * months, so on this build there is nothing to reproduce, and a runner that
 * FAILS unless a repaired bug comes back is worthless. Both phases therefore
 * report which way the build went and fail only on the bad one:
 *
 *   `signup` walks a WebKit browser from an invite to the twelve words, presses
 *   through, and then **reloads**. Landing back on the recovery step in its
 *   ENTER form is the loop, and it says REPRODUCED. Landing past it is the
 *   healthy build. Either way the account now holds a published key set and the
 *   phrase is on disk, which is what phase two needs.
 *
 *   `recover` re-opens the same profile and requires the twelve words to work.
 *   If the healthy build has left the keys in place it **deletes the key vault
 *   and keeps the session**, which is the operator's symptom manufactured on
 *   purpose — signed in, and asked for twelve words. Then it types them and
 *   requires the account back: no re-keying, no new invite, the same session and
 *   the same published blob. Then it reloads once more and requires the screen
 *   to stay past the step.
 *
 * Manufacturing that state is the difference between a run that asserts the
 * WebKit phrase path and a run that skips it whenever the build is well. This
 * file was the second kind for months; `vault.mjs` covers the vault round trip
 * on this engine, but nothing covered phrase → keys → reload on it.
 *
 * A **persistent profile** (`--user-data-dir`) is what lets those be two
 * processes: the passkey, the session and IndexedDB all have to survive between
 * them.
 *
 * `navigator.credentials` comes from `harness/webauthn.mjs` — a real ES256
 * software authenticator — because Playwright's virtual authenticator is
 * Chromium-only and this run has to happen in WebKit.
 *
 * # What changed under it (2026-08-12)
 *
 * It filled a **type-three-words-back quiz** and pressed "Finish setting up
 * encryption" after the phrase. `0baf410` deleted both, so it hung on a screen
 * that had already moved on; the one press there now is "I have written these
 * down". It also waited for the onboarding **bank step**, removed 2026-08-10 —
 * the step after the phrase is the forwarding one. The walk here stays written
 * out rather than calling `v2nav.mjs`'s `ceremony`, and deliberately: `ceremony`
 * drives a Chromium context with a CDP virtual authenticator, and the entire
 * point of this file is the engine that cannot have one.
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { webkit } from "playwright";
import { authenticatorScript } from "./webauthn.mjs";

const ORIGIN = process.env.LEDGER_HARNESS_ORIGIN ?? "http://localhost:5177";
const RP_ID = process.env.LEDGER_HARNESS_RP_ID ?? "localhost";
const STATE_DIR = process.env.LEDGER_HARNESS_DIR ?? "/tmp/ledger-v2-harness";
const PROFILE = `${STATE_DIR}/webkit-profile`;
const PHRASE_FILE = `${STATE_DIR}/operator-phrase.txt`;

const mode = process.argv[2];
if (mode !== "signup" && mode !== "recover") {
  console.error("usage: bun harness/operator.mjs signup <invite> | recover");
  process.exit(2);
}

let failed = false;
const ok = (what, detail = "") => console.log(`  ok    ${what}${detail ? ` — ${detail}` : ""}`);
const bad = (what, detail = "") => {
  console.error(`  FAIL  ${what}${detail ? ` — ${detail}` : ""}`);
  failed = true;
};

/** Which screen is on the glass, by the test ids the walk and the gate use. */
async function screenOf(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("[data-testid]")].map((e) => e.dataset.testid).filter((t) =>
      // `forwarding` is in this list and `bank` is not: the onboarding bank step
      // was removed on 2026-08-10, and the step that follows the phrase now is
      // the forwarding one. A regex that still named `bank` reported an empty
      // screen list on every failure, which is the least useful half of the
      // story at exactly the moment the story matters.
      /^(welcome|welcome-created|onboarding-|forwarding|inbound-address|recover-write|home|app-shell)/.test(t),
    ),
  );
}

async function waitForAny(page, ids, timeout = 90_000) {
  const started = Date.now();
  for (;;) {
    const seen = await screenOf(page);
    const hit = ids.find((id) => seen.includes(id));
    if (hit !== undefined) return hit;
    if (Date.now() - started > timeout) throw new Error(`none of ${ids.join(", ")} appeared; saw ${seen.join(", ")}`);
    await page.waitForTimeout(500);
  }
}

mkdirSync(STATE_DIR, { recursive: true });
const context = await webkit.launchPersistentContext(PROFILE, { viewport: { width: 390, height: 844 } });
await context.addInitScript(authenticatorScript(RP_ID));
const page = context.pages()[0] ?? (await context.newPage());
page.on("pageerror", (e) => console.error(`  page error: ${e.message}`));

try {
  await page.goto(ORIGIN, { waitUntil: "domcontentloaded" });

  if (mode === "signup") {
    const invite = process.argv[3];
    if (!invite) throw new Error("signup needs an invite code");

    await page.getByTestId("welcome").waitFor({ timeout: 60_000 });
    await page.getByLabel("Invite code").first().fill(invite);
    await page.getByRole("button", { name: /Create my account/i }).click();
    await page.getByTestId("welcome-created").waitFor({ timeout: 60_000 });
    ok("a passkey signs this WebKit browser up", "software ES256 authenticator, verified by go-webauthn");
    await page.getByRole("button", { name: /^Not now$/i }).click();

    await page.getByTestId("recovery-phrase-words").waitFor({ timeout: 90_000 });
    const words = await page.$$eval('[data-testid="recovery-phrase-words"] li', (items) =>
      items.map((li) => li.textContent.replace(/^\d+/, "").trim()),
    );
    if (words.length !== 12) bad("the phrase is twelve words", `it had ${words.length}`);
    writeFileSync(PHRASE_FILE, words.join(" "));
    ok("the twelve words are on the glass", words.slice(0, 2).join(" ") + " …");

    // The one press this screen has. The type-back quiz that used to follow it
    // was deleted by `0baf410`; see the header.
    await page.getByRole("button", { name: /I have written these down/i }).click();

    // The walk always advances first — `onSecured` dispatches the milestone and
    // the machine moves — so a glimpse of the next step proves nothing. What
    // decides it is where the NEXT boot lands, which is what the operator sees
    // when they come back to the app.
    await waitForAny(page, ["forwarding", "inbound-address", "onboarding-recovery-entry"]);
    await page.reload({ waitUntil: "domcontentloaded" });
    const landed = await waitForAny(page, ["forwarding", "inbound-address", "onboarding-recovery-entry"], 120_000);
    if (landed === "onboarding-recovery-entry") {
      ok("REPRODUCED: the ceremony reported success and the next launch asks for the phrase again");
    } else {
      ok("the next launch stays past the recovery step", `${landed} — no loop in this build`);
    }
    console.log("\nphase one done. The account has a published key set; the phrase is in " + PHRASE_FILE);
  } else {
    const phrase = readFileSync(PHRASE_FILE, "utf8").trim();

    let landed = await waitForAny(page, ["forwarding", "inbound-address", "onboarding-recovery-entry", "welcome"]);
    if (landed === "welcome") bad("the profile is still signed in", "it landed on Welcome");

    /*
     * On a healthy build the profile still holds its keys, so the screen this
     * file exists for never appears — and a run that then asserts nothing about
     * the phrase is a run that would stay green if the WebKit phrase path rotted
     * completely. So the state is MANUFACTURED instead of waited for: the key
     * vault is deleted and the session is left alone, which is the operator's
     * symptom exactly ("I am signed in and it wants twelve words"), and it is
     * the state a lost `CryptoKey` produced on its own.
     *
     * The vault is found by name from `indexedDB.databases()` rather than
     * hardcoded, and the delete is PROVED by reading the vault back through the
     * app's own module afterwards — a rename that made this delete nothing would
     * otherwise leave the run green and testing nothing.
     */
    if (landed !== "onboarding-recovery-entry" && landed !== "welcome") {
      ok("this profile still holds usable keys", landed);
      const dropped = await page.evaluate(async () => {
        const names = (await indexedDB.databases()).map((d) => d.name).filter((n) => typeof n === "string");
        const vaults = names.filter((n) => /key/i.test(n));
        for (const n of vaults) {
          await new Promise((resolve) => {
            const r = indexedDB.deleteDatabase(n);
            r.onsuccess = r.onerror = r.onblocked = () => resolve();
          });
        }
        return { names, vaults };
      });
      if (dropped.vaults.length === 0) {
        bad("the key vault database was found and deleted", `no database matching /key/i among ${JSON.stringify(dropped.names)}`);
      }
      await page.reload({ waitUntil: "domcontentloaded" });
      const empty = await page.evaluate(async () => {
        const keys = await import("/src/v2/keys.ts");
        return (await keys.browserKeyVault().read()) === null;
      });
      if (!empty) bad("the key vault is empty after the delete", "it still reads a key set");
      else ok("the key vault is deleted while the session is left alone", dropped.vaults.join(", "));

      landed = await waitForAny(page, ["forwarding", "inbound-address", "onboarding-recovery-entry", "recover-write", "welcome"], 120_000);
      if (landed !== "onboarding-recovery-entry") {
        bad("a signed-in profile with no keys is asked for the phrase", `it showed ${landed}`);
      }
    }

    if (landed === "onboarding-recovery-entry") {
      // The signed-in note is the other half of the report: the operator read a
      // bare wall after a working sign-in as "sign-in is broken".
      const note = await page.getByTestId("signed-in-note").textContent();
      if (!/signed in/i.test(note ?? "")) bad("the screen says the sign-in worked", String(note));
      else ok("the recovery screen says the sign-in worked", note.trim());

      await page.getByTestId("recovery-entry-phrase").fill(phrase);
      await page.getByRole("button", { name: /Unlock my account/i }).click();
      // Waited for by ABSENCE of the recovery step as much as by presence of the
      // next one: the step is still on the glass while Argon2id runs, so "any of
      // these ids" would match the screen we are trying to leave.
      try {
        await page.getByTestId("onboarding-recovery-entry").waitFor({ state: "detached", timeout: 180_000 });
        const after = await waitForAny(page, ["forwarding", "inbound-address"], 120_000);
        ok("the twelve words alone get the keys back, in WebKit", after);
      } catch (err) {
        bad("the phrase gets this device past the recovery step", err.message);
      }
    }

    // The assertion the whole bug is about: a RELOAD does not go back.
    await page.reload({ waitUntil: "domcontentloaded" });
    const afterReload = await waitForAny(page, ["forwarding", "inbound-address", "onboarding-recovery-entry", "welcome"], 120_000);
    if (afterReload === "onboarding-recovery-entry") bad("a reload stays past the recovery step", "it asked for the phrase again");
    else ok("a reload stays past the recovery step", afterReload);
  }
} catch (err) {
  bad("the run completed", err.message);
  console.error("\n--- screen at failure ---");
  console.error((await page.evaluate(() => document.body.innerText)).slice(0, 1200));
  console.error(await screenOf(page));
} finally {
  await context.close();
}

process.exit(failed ? 1 : 0);
