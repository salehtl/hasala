/**
 * The wall a device that could not be registered as a writer stands behind —
 * and the one way off it.
 *
 * # It still renders INSTEAD of the app, and the way out is OUT
 *
 * `BootGate`'s header comment states the invariant this must not break: a
 * half-set-up device that let you into the product would look fine until the
 * first edit. So the back affordance here does not dismiss the wall onto the
 * app. It signs this device out and returns to Welcome, which is the thing a
 * person actually needs when they have signed in to the wrong account — the
 * state that made every one of these six kinds a dead end with nothing to
 * press.
 *
 * Signing out is `V2Handle.signOut`: the bearer token and nothing else. The op
 * log, the projection, the writer key and the key vault all stay, so coming
 * back is one passkey tap and costs no re-sync.
 *
 * # One confirm, two ways in
 *
 * The header arrow and the edge-back swipe both open the same `Dialog`. A
 * gesture that silently signed you out would be a surprise, and a gesture that
 * did something *different* from the button beside it would be worse — so
 * neither acts, both ask. The gesture itself comes from `hooks/useEdgeBack`,
 * the same wiring every Settings drill-in uses; there is one implementation.
 */

import { useCallback, useMemo, useState } from "react";
import { m } from "motion/react";

import { Button } from "../components/ui/Button";
import { Dialog, DialogFooter } from "../components/ui/Dialog";
import { IconButton } from "../components/ui/IconButton";
import { ArrowLeft } from "../components/ui/PixelIcon";
import { SectionLabel } from "../components/ui/SectionLabel";
import { useEdgeBack } from "../hooks/useEdgeBack";
import { PendingDevicePanel } from "../screens/settings/PendingDevicePanel";
import { RecoverWritePanel } from "../screens/settings/RecoverWritePanel";

import type { EnrollmentCopy } from "./enrollment";
import type { EnrollmentKind, V2Handle } from "./session";

export interface UnenrolledWallProps {
  kind: EnrollmentKind;
  copy: EnrollmentCopy;
  /** Null only before `open()` has resolved, which this state cannot be reached before. */
  handle: V2Handle | null;
  /** Re-runs boot: the retry, and the recheck after another device approves. */
  onRetry: () => void;
  /** Drops the session and re-runs boot, landing on sign-in. */
  onLeave: () => Promise<void>;
  profile: string;
  server: string;
}

export function UnenrolledWall({ kind, copy, handle, onRetry, onLeave, profile, server }: UnenrolledWallProps) {
  const [asking, setAsking] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  const ask = useCallback(() => {
    setProblem(null);
    setAsking(true);
  }, []);
  const { dragProps, stripProps } = useEdgeBack(ask);

  const leave = useCallback(async () => {
    setLeaving(true);
    setProblem(null);
    try {
      await onLeave();
      // No reset on the success path: `onLeave` re-runs boot, which replaces
      // this tree with the sign-in slot.
    } catch {
      setProblem("ledger could not sign this device out. Try again.");
      setLeaving(false);
    }
  }, [onLeave]);

  return (
    <>
      {/*
        The `Dialog` is a SIBLING of the dragged surface, not a child of it.
        Framer puts a `transform` on a draggable element, and a transformed
        ancestor becomes the containing block for `position: fixed` descendants
        — so a sheet rendered inside would be positioned against the wall
        rather than against the viewport, and would slide with it.
      */}
      <m.div {...dragProps} className="relative h-[100svh] bg-bg text-fg flex flex-col">
        <div {...stripProps} />
        {/* `relative z-20` keeps the header above the activation strip, so the
            back arrow takes a tap on its own left edge — the same rule, and the
            same measured bug, as `SettingsPage`. */}
        <header className="relative z-20 flex items-center gap-3 px-4 pt-[max(1rem,env(safe-area-inset-top))] pb-3 border-b border-border">
          <IconButton label="Back to sign in" className="-ml-2" onClick={ask}>
            <ArrowLeft size={20} />
          </IconButton>
          {/* An eyebrow, not a heading: the page's one <h1> is the state's own
              title, below, and a header <h2> ahead of it would put the document
              outline out of order for no gain. */}
          <SectionLabel className="flex-1">Device setup</SectionLabel>
        </header>

        <div className="flex-1 overflow-y-auto w-full max-w-screen-sm mx-auto px-4 py-6 pb-[max(1.5rem,env(safe-area-inset-bottom))] space-y-6">
          <div className="space-y-2">
            <h1 className="text-xl font-semibold tracking-[-0.015em]">{copy.title}</h1>
            <p className="text-sm leading-relaxed text-muted">{copy.body}</p>
          </div>

          {/*
            `rejected` is the one kind that is not a dead end: the server refuses
            a second device precisely because no already-enrolled key signed for
            it (spec §3.4), and the fix is a device that can. The panel is what
            lets the person provide that proof, so it belongs on the wall rather
            than behind a Settings screen this device cannot reach.
          */}
          {kind === "rejected" && handle !== null && <PendingDevice handle={handle} onRecheck={onRetry} />}

          {copy.retry && (
            <div>
              <Button variant="primary" onClick={onRetry}>
                Try again
              </Button>
            </div>
          )}

          {/*
            And the way out for a device with NO other device: the recovery
            phrase. A cleared browser is a new writer whose self-signature the
            server refuses, and before `RecoverWritePanel` it was permanently
            read-only — holding the phrase that was supposed to make it whole.

            It is one press away rather than open, because it is the SECOND path:
            a phrase entry box sitting under the approval flow at equal weight
            reads as two things to do at once, and this one asks for the account's
            most sensitive secret.
          */}
          {kind === "rejected" && handle !== null && (
            <RecoveryEscape handle={handle} onRecovered={onRetry} profile={profile} server={server} />
          )}
        </div>
      </m.div>

      {asking && (
        <Dialog title="Back to sign in?" onClose={() => setAsking(false)}>
          <p className="text-sm leading-relaxed">
            This device stays unapproved and ledger signs it out — nothing on it is deleted, and signing back in
            is one passkey tap.
          </p>
          {problem !== null && (
            <p role="alert" className="mt-3 text-sm text-bad">
              {problem}
            </p>
          )}
          <DialogFooter>
            <Button variant="ghost" onClick={() => setAsking(false)}>
              Stay here
            </Button>
            <Button variant="primary" disabled={leaving} onClick={() => void leave()}>
              {leaving ? "Signing out…" : "Back to sign in"}
            </Button>
          </DialogFooter>
        </Dialog>
      )}
    </>
  );
}

/**
 * The recovery phrase, demoted to a disclosure.
 *
 * The sentence under the trigger is the one that decides whether a person
 * presses it, so it stays on the screen rather than inside the panel — the same
 * rule `InfoTip` states: what changes a decision is never hidden.
 */
function RecoveryEscape({
  handle,
  onRecovered,
  profile,
  server,
}: {
  handle: V2Handle;
  onRecovered: () => void;
  profile: string;
  server: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <section className="border-t border-border pt-5 space-y-3">
      <Button
        variant="ghost"
        data-testid="recover-write-open"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        Use your recovery phrase instead
      </Button>
      {!open && (
        <p className="text-xs leading-relaxed text-muted">
          If no other device is signed in to this account, the twelve words ledger gave you are the only way to
          approve this one.
        </p>
      )}
      {open && <RecoverWritePanel handle={handle} onRecovered={onRecovered} profile={profile} server={server} />}
    </section>
  );
}

/**
 * The enrolment request this device would have another device approve.
 *
 * A component of its own so `enrolmentRequest()` — which mints and persists a
 * writer id and an Ed25519 key on first call — runs once, in a memo, rather
 * than on every render of the wall. It can throw (a stored writer id that is no
 * longer a legal one is a refusal, not a re-mint), and a throw here must not
 * take the wall down with it: the copy above the panel is still the truth, so
 * the panel is simply absent.
 */
function PendingDevice({ handle, onRecheck }: { handle: V2Handle; onRecheck: () => void }) {
  const request = useMemo(() => {
    try {
      return handle.enrolmentRequest();
    } catch {
      return null;
    }
  }, [handle]);
  const loadKeyHistory = useCallback(() => handle.keyHistory(), [handle]);
  if (request === null) return null;
  return <PendingDevicePanel request={request} loadKeyHistory={loadKeyHistory} onRecheck={onRecheck} />;
}
