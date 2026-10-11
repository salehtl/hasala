/**
 * The app shell's one persistent notice strip: an eyebrow, a sentence, one
 * action and a dismiss.
 *
 * # Why this is not a `Toast` and not a `Notice`
 *
 * A `Toast` is transient outcome feedback and is gone in five seconds. A
 * `Notice` (`screens/onboarding/Shell.tsx`) belongs inside a step's content
 * column. This is neither: it is chrome, it sits between the `TopBar` and the
 * scrolling `<main>`, it survives tab switches, and it is dismissed by choice
 * rather than by a timer. The app had no component for that shape, and the
 * alternative was a hand-rolled strip in `AppShell` — which is exactly how the
 * offline strip beneath it came to be a bare `div` nobody can restyle or test.
 *
 * # It is chrome, so it is quiet, and its one bright thing is the action
 *
 * `bg-surface-2` and a bottom hairline, matching every other separation in the
 * app. The `primary` Button inside it is the only full-opacity vermilion — one
 * of the five sanctioned contexts ("Red is rationed", `components/README.md`) —
 * and it is what makes the strip read as an offer rather than as a warning. No
 * tinted background, no icon, no accent text: the spot ink is a fill only.
 *
 * # Both controls are 44px, for the reason the toast's are
 *
 * The dismiss sits next to the action and spends the banner permanently. A
 * mis-tap there is not recoverable by the user — there is no undo for
 * "dismissed forever" — so it is a full `IconButton` with a real label, never a
 * glyph.
 *
 * # Motion
 *
 * None, deliberately. This mounts at first paint on the screen the user is
 * waiting for, and `components/README.md`'s first-paint rule forbids an
 * `opacity: 0` resting state there; a transform-only entrance on a strip that
 * pushes the whole page down would shove the content the user is reading. It
 * appears and it is there. `Pressable`'s `whileTap` on the two controls is the
 * only motion, and they carry it themselves.
 */

import { Button } from "./Button";
import { IconButton } from "./IconButton";
import { X } from "./PixelIcon";
import { SectionLabel } from "./SectionLabel";

export interface BannerProps {
  /** The eyebrow. Mono micro-caps — it is a label, not a sentence. */
  eyebrow?: string;
  /** What this is about, as a sentence a person reads. */
  title: string;
  /** One or two sentences. Says what pressing the action gets them. */
  body?: string;
  /** The action's label. Names what happens, in the imperative. */
  action: string;
  onAction: () => void;
  /**
   * Spends the banner. Required: a persistent strip with no way to close it is
   * a permanent tax on every screen behind it, which is why this component
   * cannot be constructed without one.
   */
  onDismiss: () => void;
  /** The dismiss control's accessible name. Defaults to "Dismiss". */
  dismissLabel?: string;
  testId?: string;
}

export function Banner({
  eyebrow,
  title,
  body,
  action,
  onAction,
  onDismiss,
  dismissLabel = "Dismiss",
  testId,
}: BannerProps) {
  return (
    <div
      {...(testId === undefined ? {} : { "data-testid": testId })}
      className="shrink-0 bg-surface-2 border-b border-border"
    >
      <div className="max-w-screen-sm w-full mx-auto px-4 py-3 flex items-start gap-3">
        <div className="flex flex-col gap-1 min-w-0 flex-1">
          {eyebrow !== undefined && <SectionLabel>{eyebrow}</SectionLabel>}
          <p className="text-sm font-medium text-fg">{title}</p>
          {body !== undefined && <p className="text-xs leading-relaxed text-muted">{body}</p>}
          <Button variant="primary" className="mt-2 self-start" onClick={onAction}>
            {action}
          </Button>
        </div>
        <IconButton label={dismissLabel} onClick={onDismiss}>
          <X size={12} aria-hidden />
        </IconButton>
      </div>
    </div>
  );
}
