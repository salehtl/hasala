/**
 * What the device being ADDED shows: the code it hands over, the code the two
 * devices compare, and the one instruction that can actually get it enrolled.
 *
 * It lives under `screens/settings/` beside its other half
 * ({@link ApproveDevicePanel}) rather than under `v2/`, because the two are one
 * flow read from two sides and the copy on them has to be kept in step. It is
 * rendered by `v2/UnenrolledWall`, not by Settings — this device cannot reach
 * Settings; it cannot reach anything until it is enrolled.
 *
 * # The shape, and why it is not "Step 1 / Step 2 / Step 3"
 *
 * It was three equally-weighted cards with numbered eyebrows, which read as a
 * form to be filled in rather than as a thing to do on another device. There
 * are only two objects here — a code you send, and a code you compare — and
 * exactly one of them is read aloud. So the comparison code is the hero: it is
 * the largest thing on the screen, alone in its own surface, while the code it
 * belongs to sits above it as the small monospace payload it actually is. The
 * numbering went with the cards: the order is already carried by "on your other
 * device" preceding "both devices must show".
 *
 * # Why there is no "waiting" spinner
 *
 * Nothing on the server holds a pending request (see `deviceEnrolment.ts`), so
 * there is nothing to poll and no event to wait for. The approval happens on
 * the other device, and the only way this one learns of it is by asking the
 * roster again — which is exactly what "Check again" does. A spinner labelled
 * "waiting for approval" would be an animation over a socket that does not
 * exist.
 */

import { useCallback, useEffect, useState } from "react";

import { Button } from "../../components/ui/Button";
import { Card } from "../../components/ui/Card";
import { PixelSpinner } from "../../components/ui/PixelSpinner";
import { SectionLabel } from "../../components/ui/SectionLabel";
import {
  comparisonCode,
  encodeEnrolmentRequest,
  type EnrolmentRequest,
  type KeyHistoryEntry,
} from "../../v2/deviceEnrolment";

export interface PendingDevicePanelProps {
  request: EnrolmentRequest;
  /** `V2Handle.keyHistory`. Its result is hashed into the comparison code. */
  loadKeyHistory: () => Promise<KeyHistoryEntry[]>;
  /** Re-runs boot, which re-reads the roster. The only way this device learns it was approved. */
  onRecheck: () => void;
  /** Test seam. Defaults to the Clipboard API. */
  copy?: (text: string) => Promise<void>;
}

async function writeClipboard(text: string): Promise<void> {
  if (typeof navigator === "undefined" || navigator.clipboard === undefined) {
    throw new Error("this browser has no clipboard access");
  }
  await navigator.clipboard.writeText(text);
}

export function PendingDevicePanel({ request, loadKeyHistory, onRecheck, copy = writeClipboard }: PendingDevicePanelProps) {
  const code = encodeEnrolmentRequest(request);
  const [check, setCheck] = useState<{ code: string } | { error: true } | null>(null);
  const [copied, setCopied] = useState<boolean | null>(null);

  useEffect(() => {
    let live = true;
    void (async () => {
      try {
        const entries = await loadKeyHistory();
        if (live) setCheck({ code: comparisonCode(request, entries) });
      } catch {
        // Nothing is shown in place of it. A comparison code that could not be
        // derived is not "—" and not a spinner that never ends: it is a check
        // that did not happen, and saying so is the only honest option. See
        // `deviceEnrolment.ts`.
        if (live) setCheck({ error: true });
      }
    })();
    return () => {
      live = false;
    };
  }, [loadKeyHistory, request]);

  const onCopy = useCallback(async () => {
    try {
      await copy(code);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }, [copy, code]);

  return (
    <div className="w-full space-y-6 text-left">
      <section className="space-y-2">
        <SectionLabel as="h2">On your other device</SectionLabel>
        <Card className="space-y-3">
          <p className="text-sm leading-relaxed">
            Open <strong>Settings &rsaquo; Add a device</strong> and paste this code.
          </p>
          <p
            data-testid="enrolment-code"
            className="font-mono text-xs select-all break-all leading-relaxed text-muted"
          >
            {code}
          </p>
          <Button variant="secondary" onClick={() => void onCopy()}>
            {copied === true ? "Copied" : "Copy code"}
          </Button>
          {copied === false && (
            <p role="status" className="text-xs text-bad">
              This browser would not let ledger use the clipboard. The code above can be selected by hand.
            </p>
          )}
          <p className="text-xs leading-relaxed text-muted">
            It holds this device&rsquo;s name and public key. It is not a secret and cannot read your ledger —
            but whoever you send it to can add this device.
          </p>
        </Card>
      </section>

      {/*
        The hero. It is the one string a person reads out loud, and the only
        thing on this screen that a mismatch makes dangerous — so it gets the
        size, the space and a surface of its own, and the sentence under it
        says what a mismatch means rather than merely asking for a comparison.
      */}
      <section className="space-y-2">
        <SectionLabel as="h2">Both devices must show</SectionLabel>
        <Card className="space-y-3 text-center">
          <div data-testid="comparison-code">
            {check === null ? (
              <span className="flex items-center justify-center gap-2 py-3 text-sm text-muted" role="status">
                <PixelSpinner size={12} />
                Working out the check code…
              </span>
            ) : "code" in check ? (
              <p
                data-testid="comparison-code-value"
                className="font-mono text-3xl font-semibold tracking-[0.18em] tnum py-2 break-all"
              >
                {check.code}
              </p>
            ) : (
              <p className="text-sm leading-relaxed text-warn text-left">
                ledger could not work out the check code here — it could not read the account&rsquo;s key history.
                Nothing is shown in its place, because a code that was not computed is not a check. Your other
                device will refuse to approve without one too.
              </p>
            )}
          </div>
          {check !== null && "code" in check && (
            <p className="text-xs leading-relaxed text-muted">
              Each device works this out for itself. If the two do not match, do not approve — something changed
              the code on its way over.
            </p>
          )}
        </Card>
      </section>

      <section className="space-y-2">
        <Button variant="primary" onClick={onRecheck}>
          Check again
        </Button>
        <p className="text-xs leading-relaxed text-muted">
          ledger is not told when the other device approves, so this one has to look. Press this once you have
          approved it there.
        </p>
      </section>
    </div>
  );
}
