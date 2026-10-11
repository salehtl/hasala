import { describe, it, expect, vi } from "vitest";
// jsdom has no layout, so Framer's spring/tween scheduler needs real timers
// to settle. These tests assert lifecycle (did onClose fire), never geometry.
import { render, screen, fireEvent, waitFor, within, type RenderOptions } from "@testing-library/react";
import { useState, type ReactNode } from "react";
import { MotionProvider } from "../../app/MotionProvider";
import { Dialog, DialogFooter } from "./Dialog";

// Every m.* needs a LazyMotion ancestor. Without one `strict` does not throw —
// the component just renders with no features loaded, so `exit` and `drag` are
// silently inert and a test would pass while covering none of the behaviour it
// looks like it covers.
function renderInMotion(ui: ReactNode, options?: RenderOptions) {
  return render(<MotionProvider>{ui}</MotionProvider>, options);
}

/**
 * Resolve once LazyMotion's feature bundle is actually live: the panel has
 * moved off the seeded `translateY(100%)` start, so the enter animation is
 * running for real. Gating on this is what stops the lifecycle tests below
 * from being vacuous — with no features loaded the sheet still renders, but
 * `exit` never runs and onClose fires synchronously on click.
 */
async function motionReady() {
  const panel = screen.getByRole("dialog");
  await waitFor(() => expect(panel.style.transform).not.toBe("translateY(100%)"));
}

describe("Dialog", () => {
  it("renders the title and children", () => {
    renderInMotion(<Dialog title="Choose period" onClose={vi.fn()}>body</Dialog>);
    expect(screen.getByRole("dialog", { name: "Choose period" })).toBeInTheDocument();
    expect(screen.getByText("body")).toBeInTheDocument();
  });

  it("renders the panel and scrim", () => {
    renderInMotion(<Dialog title="T" onClose={vi.fn()}>x</Dialog>);
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(screen.getByTestId("dialog-scrim")).toBeInTheDocument();
  });

  it("keeps footer actions sticky above scrolling content", () => {
    const { container } = renderInMotion(<Dialog title="T" onClose={() => {}}><div>body</div><DialogFooter><button>Save</button></DialogFooter></Dialog>);
    const footer = container.querySelector("[data-dialog-footer]");
    expect(footer).toHaveClass("sticky", "bottom-0", "z-20", "bg-surface");
  });

  it("lets the footer own the bottom inset instead of the panel", () => {
    // `sticky bottom: 0` resolves against the scroll container's CONTENT box, so
    // padding-bottom on the panel rides the stuck footer *up* by that much —
    // over the last row of content. A negative margin-bottom on the footer does
    // not push it back down; it shrinks the content box, which is what caused
    // the overlap in the first place. On a phone with a 34px home-indicator
    // inset the footer ate 18px of the row above it.
    const { container } = renderInMotion(
      <Dialog title="T" onClose={() => {}}><div>body</div><DialogFooter><button>Save</button></DialogFooter></Dialog>,
    );
    const panel = screen.getByRole("dialog");
    const footer = container.querySelector("[data-dialog-footer]")!;
    expect(panel).toHaveClass("sheet-panel");            // CSS zeroes its padding when a footer is present
    expect(panel.style.paddingBottom).toBe("");           // never inline — that would outrank the rule
    expect(footer.className).not.toMatch(/-mb-/);         // no negative-margin compensation
    expect(footer.className).toContain("pb-[var(--sheet-inset-bottom)]");
  });

  it("drops the home-indicator inset while the keyboard is up", () => {
    renderInMotion(<Dialog title="T" onClose={() => {}}><DialogFooter><button>Save</button></DialogFooter></Dialog>);
    // No visualViewport in jsdom → keyboard closed → the shared inset var is
    // left to the stylesheet rather than pinned inline.
    expect(screen.getByRole("dialog").style.getPropertyValue("--sheet-inset-bottom")).toBe("");
  });

  it("freezes scrollable ancestors so the page cannot scroll behind the sheet", () => {
    // A fixed overlay's touch-scroll chains to the root scroller, not to its DOM
    // ancestor, so the ancestor's own overscroll-contain never sees the gesture.
    // The background must be frozen outright.
    const host = document.createElement("div");
    host.style.overflowY = "auto";
    document.body.appendChild(host);
    const { unmount } = renderInMotion(<Dialog title="T" onClose={() => {}}>x</Dialog>, { container: host });
    expect(host.style.overflow).toBe("hidden");
    unmount();
    expect(host.style.overflow).toBe("");
    host.remove();
  });

  it("restores a scroll position it froze", () => {
    const host = document.createElement("div");
    host.style.overflowY = "scroll";
    document.body.appendChild(host);
    Object.defineProperty(host, "scrollTop", { value: 120, writable: true, configurable: true });
    const { unmount } = renderInMotion(<Dialog title="T" onClose={() => {}}>x</Dialog>, { container: host });
    unmount();
    expect(host.scrollTop).toBe(120);
    host.remove();
  });

  it("makes the scrim swallow touch gestures rather than pass them to the page", () => {
    renderInMotion(<Dialog title="T" onClose={() => {}}>x</Dialog>);
    expect(screen.getByTestId("dialog-scrim")).toHaveClass("touch-none");
  });

  it("calls onClose after the exit animation completes", async () => {
    const onClose = vi.fn();
    renderInMotion(<Dialog title="T" onClose={onClose}>x</Dialog>);
    await motionReady();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    expect(onClose).not.toHaveBeenCalled();          // exit in flight, parent still mounted
    await waitFor(() => expect(onClose).toHaveBeenCalledOnce());
  });

  it("calls onClose when the scrim is tapped", async () => {
    const onClose = vi.fn();
    renderInMotion(<Dialog title="T" onClose={onClose}>x</Dialog>);
    await motionReady();
    fireEvent.click(screen.getByTestId("dialog-scrim"));
    expect(onClose).not.toHaveBeenCalled();
    await waitFor(() => expect(onClose).toHaveBeenCalledOnce());
  });

  it("does not double-fire onClose when closed twice quickly", async () => {
    // There is no double-close guard any more: closing is `setOpen(false)`,
    // which is idempotent, and AnimatePresence fires onExitComplete once per
    // exit. This test is what makes dropping the guard safe.
    const onClose = vi.fn();
    renderInMotion(<Dialog title="T" onClose={onClose}>x</Dialog>);
    await motionReady();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    fireEvent.keyDown(document, { key: "Escape" });
    await waitFor(() => expect(onClose).toHaveBeenCalledOnce());
    await new Promise((r) => setTimeout(r, 50));   // nothing arrives late either
    expect(onClose).toHaveBeenCalledOnce();
  });

  /**
   * The two-tap bug, pinned.
   *
   * The guard that was supposed to prevent it queried `[autofocus]`, and React
   * renders no such attribute — it focuses the node during commit and leaves
   * nothing behind, so the query matched on no sheet in the app and every one of
   * them took the caret back out of the field it had just opened onto.
   */
  it("leaves the caret in a field that asked for it", async () => {
    renderInMotion(
      <Dialog title="Search" onClose={() => {}}>
        <input autoFocus aria-label="Search merchants" />
      </Dialog>,
    );
    await waitFor(() => expect(document.activeElement).toBe(screen.getByLabelText("Search merchants")));
  });

  it("focuses the panel itself when nothing inside asked for the caret", async () => {
    renderInMotion(
      <Dialog title="Plain" onClose={() => {}}>
        <p>no fields here</p>
      </Dialog>,
    );
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole("dialog")));
  });

  /**
   * `background-layer-not-inert`, pinned.
   *
   * `harness/audit.mjs` measures exactly this: with an overlay up, every
   * focusable element outside it must sit under an `[inert]` ancestor (or an
   * `aria-hidden="true"` one), or Tab and VoiceOver walk into the screen the
   * sheet is covering. It reported the finding on all seven Settings dialogs.
   */
  it("takes the layer beneath it out of the tab order while it is open", async () => {
    const { unmount } = renderInMotion(
      <div>
        <button data-testid="behind">buried</button>
        <Dialog title="T" onClose={() => {}}>x</Dialog>
      </div>,
    );
    await motionReady();
    expect(screen.getByTestId("behind").closest("[inert]")).not.toBeNull();
    unmount();
    // Restored, not cleared blindly: the screen underneath is usable again.
    expect(document.querySelector("[inert]")).toBeNull();
  });

  it("gives the inert back once the sheet has finished leaving", async () => {
    const onClose = vi.fn();
    function Host() {
      const [open, setOpen] = useState(true);
      return (
        <div>
          <button data-testid="behind">buried</button>
          {open && <Dialog title="T" onClose={() => { setOpen(false); onClose(); }}>x</Dialog>}
        </div>
      );
    }
    renderInMotion(<Host />);
    await motionReady();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    // Still inert mid-exit — the sheet is on screen until the slide finishes.
    expect(screen.getByTestId("behind").closest("[inert]")).not.toBeNull();
    await waitFor(() => expect(onClose).toHaveBeenCalledOnce());
    await waitFor(() => expect(screen.getByTestId("behind").closest("[inert]")).toBeNull());
  });

  /**
   * Sheets stack, so the restore has to be a stack too: the inner sheet inerts
   * the outer sheet's own body, and closing it must hand the outer sheet back
   * — without handing back the page underneath, which the outer sheet still
   * owns. A blanket "clear every inert on close" passes the single-sheet test
   * above and unlocks the whole page here.
   */
  it("inerts the sheet underneath a nested sheet, and only that one comes back", async () => {
    function Host() {
      const [inner, setInner] = useState(false);
      return (
        <div>
          <button data-testid="behind">buried</button>
          <Dialog title="Outer" onClose={() => {}}>
            <button data-testid="outer-body" onClick={() => setInner(true)}>open the inner sheet</button>
            {inner && <Dialog title="Inner" onClose={() => setInner(false)}>inner</Dialog>}
          </Dialog>
        </div>
      );
    }
    renderInMotion(<Host />);
    await motionReady();
    expect(screen.getByTestId("behind").closest("[inert]")).not.toBeNull();
    expect(screen.getByTestId("outer-body").closest("[inert]")).toBeNull();

    fireEvent.click(screen.getByTestId("outer-body"));
    await waitFor(() => expect(screen.getByRole("dialog", { name: "Inner" })).toBeInTheDocument());
    await waitFor(() => expect(screen.getByTestId("outer-body").closest("[inert]")).not.toBeNull());
    expect(screen.getByTestId("behind").closest("[inert]")).not.toBeNull();

    // The inner sheet's OWN close button. Escape would not do here: both sheets
    // listen on `document`, so one press closes the stack — a separate defect,
    // and one that would make this test pass without proving anything.
    fireEvent.click(within(screen.getByRole("dialog", { name: "Inner" })).getByRole("button", { name: "Close" }));
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Inner" })).toBeNull());
    await waitFor(() => expect(screen.getByTestId("outer-body").closest("[inert]")).toBeNull());
    // The outer sheet is still up, so the page it covers stays inert.
    expect(screen.getByTestId("behind").closest("[inert]")).not.toBeNull();
  });

  it("renders a title adornment and applies titleStyle to the heading", () => {
    renderInMotion(
      <Dialog
        title="Wants"
        titleAdornment={<span data-testid="dot" />}
        titleStyle={{ color: "rgb(123, 53, 184)" }}
        onClose={() => {}}
      >
        body
      </Dialog>,
    );
    expect(screen.getByTestId("dot")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Wants" })).toHaveStyle({ color: "rgb(123, 53, 184)" });
  });
});
