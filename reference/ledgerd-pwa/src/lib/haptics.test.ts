import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  HAPTIC_PATTERNS,
  fire,
  isHapticsEnabled,
  loadHapticsEnabled,
  setHapticsEnabled,
} from "./haptics";

const nav = navigator as unknown as { vibrate?: (p: number | number[]) => boolean };

beforeEach(() => {
  localStorage.clear();
  document.querySelectorAll("[data-haptic-switch]").forEach((el) => el.remove());
  nav.vibrate = vi.fn(() => true);
  setHapticsEnabled(true);
});

describe("fire", () => {
  it("vibrates with the mapped pattern for each kind", () => {
    for (const kind of ["selection", "light", "success", "warning"] as const) {
      (nav.vibrate as ReturnType<typeof vi.fn>).mockClear();
      fire(kind);
      expect(nav.vibrate).toHaveBeenCalledWith(HAPTIC_PATTERNS[kind]);
    }
  });

  it("does nothing when disabled", () => {
    setHapticsEnabled(false);
    fire("success");
    expect(nav.vibrate).not.toHaveBeenCalled();
  });

  it("falls back to a single reused hidden switch when vibrate is unavailable", () => {
    delete nav.vibrate;
    expect(() => fire("selection")).not.toThrow();
    expect(() => fire("selection")).not.toThrow();
    // The iOS switch element is created once and reused, never duplicated.
    expect(document.querySelectorAll("[data-haptic-switch]").length).toBe(1);
  });
});

describe("enabled flag", () => {
  it("defaults to disabled when nothing is stored", () => {
    localStorage.clear();
    expect(loadHapticsEnabled()).toBe(false);
    expect(isHapticsEnabled()).toBe(false);
  });

  it("persists and reloads the flag", () => {
    setHapticsEnabled(false);
    expect(isHapticsEnabled()).toBe(false);
    expect(loadHapticsEnabled()).toBe(false);
    setHapticsEnabled(true);
    expect(loadHapticsEnabled()).toBe(true);
  });

  // The default flipped from on to off. A user who had already made a choice
  // must keep it: only the absence of a stored value moves. Both explicit
  // values are written by setHapticsEnabled as "true"/"false", so both survive.
  it("keeps an explicit choice made under the previous default", () => {
    localStorage.clear();
    localStorage.setItem("ledger-haptics", "true");
    expect(loadHapticsEnabled()).toBe(true);

    localStorage.setItem("ledger-haptics", "false");
    expect(loadHapticsEnabled()).toBe(false);
  });

  it("treats an unreadable stored value as the default, not as enabled", () => {
    localStorage.clear();
    localStorage.setItem("ledger-haptics", "yes");
    expect(loadHapticsEnabled()).toBe(false);
  });
});
