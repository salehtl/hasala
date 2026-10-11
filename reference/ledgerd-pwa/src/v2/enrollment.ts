/**
 * What a person is told when this device could not be registered as one that
 * may make changes. Ported from the retired Expo client's
 * `app/src/auth/enrollment.ts` (removed 2026-08-10, preserved at tag
 * `app-expo-final`).
 *
 * Kept out of any screen because two surfaces render it — the boot gate's wall
 * and (Task 7) the sign-in banner — and because the honesty of each sentence is
 * the part worth testing. Nothing here names a CLI, a writer id, or an
 * endpoint.
 *
 * `rejected` is the one that has to be careful: the server answers every
 * registration refusal with the same bodyless `403`, so the copy may not claim
 * to know WHY. What it may say — and now does — is the one thing that is true
 * of every refusal a working build can reach: this device is not enrolled, and
 * only a device already enrolled on the account can enrol it (spec §3.4). It
 * points at the code the wall shows rather than at a reason it cannot know, and
 * it still offers no retry, because pressing again cannot change the answer.
 *
 * None of these six is a dead end any more, and none of them says so: the wall
 * that renders them (`UnenrolledWall`) carries a back affordance that signs the
 * device out and returns to Welcome. That is a property of the screen, not of a
 * sentence, so no copy here mentions it — a body that promised a way out would
 * be one more sentence to keep honest.
 *
 * The wording says "this device" rather than the native port's "this phone":
 * the same account is reachable from a laptop here.
 */

import { isEnrollmentError, type EnrollmentKind } from "./session";

export interface EnrollmentCopy {
  title: string;
  body: string;
  /** Whether pressing the same button again could plausibly work. */
  retry: boolean;
}

export function enrollmentCopy(kind: EnrollmentKind): EnrollmentCopy {
  switch (kind) {
    case "offline":
      return {
        title: "ledger could not finish setting up this device",
        body: "You're signed in. Setting this device up needs a connection. Nothing was lost — try again when you are online.",
        retry: true,
      };
    case "unavailable":
      return {
        title: "ledger could not finish setting up this device",
        body: "You're signed in. The server could not set this device up. Nothing was lost — try again in a moment.",
        retry: true,
      };
    case "misconfigured":
      // Says "this copy of ledger", not "your connection" and not "the
      // server": the one thing that is certainly true is that the fault is on
      // our side of the line, and the one thing a person must not be told is
      // to keep pressing a button that cannot work.
      return {
        title: "ledger could not finish setting up this device",
        body:
          "You're signed in, but this copy of ledger is not set up correctly, so this device cannot make changes. " +
          "Nothing was lost, and nothing you do here will fix it — this is ours to repair.",
        retry: false,
      };
    case "rate_limited":
      return {
        title: "Too many attempts",
        body: "Setting this device up was tried too many times. Wait a minute and try again.",
        retry: true,
      };
    case "rejected":
      // The likeliest cause by far, now that it can be acted on: a SECOND
      // device. The server requires an already-enrolled device to sign for a
      // new one (spec §3.4), and refuses without saying why — so this says what
      // is certainly true and stops short of claiming to know the reason.
      //
      // It no longer ends with "use the code below, or your recovery phrase
      // here". The wall's own section headings carry that now ("On your other
      // device", "Both devices must show", "Use your recovery phrase
      // instead"), and a paragraph that narrates the layout underneath it is
      // the thing that made this screen read as a wall of text. What stays is
      // the pair a person needs before they read anything else: nothing was
      // lost, and this device cannot write until it is approved.
      return {
        title: "This device needs approval",
        body:
          "You're signed in and nothing was lost. This device cannot make changes until a device already on " +
          "this account approves it.",
        retry: false,
      };
    case "revoked":
      return {
        title: "This device's access was withdrawn",
        body:
          "This device was removed from this account. It can still read what it already has, but it cannot make " +
          "changes. Signing in again will not restore it.",
        retry: false,
      };
    case "key_lost":
      return {
        title: "This device can no longer prove who it is",
        body:
          "You're signed in and this account knows this device, but the key that signed for it is gone from this " +
          "browser. Clearing site data does not carry it. Nothing on the server was lost. This device cannot " +
          "make changes until a device that still has its key adds it back, which this beta cannot do yet.",
        retry: false,
      };
  }
}

/** The copy for an error, whatever shape it arrived in. */
export function enrollmentFailureCopy(err: unknown): EnrollmentCopy {
  return enrollmentCopy(isEnrollmentError(err) ? err.enrollmentKind : "unavailable");
}
