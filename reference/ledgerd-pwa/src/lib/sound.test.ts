import { beforeEach, describe, expect, it } from "vitest";

import { isSoundEnabled, loadSoundEnabled, setSoundEnabled } from "./sound";

describe("enabled flag", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it("defaults to enabled when nothing is stored", () => {
    expect(loadSoundEnabled()).toBe(true);
    expect(isSoundEnabled()).toBe(true);
  });

  it("persists and reloads the flag", () => {
    setSoundEnabled(false);
    expect(isSoundEnabled()).toBe(false);
    expect(loadSoundEnabled()).toBe(false);
    setSoundEnabled(true);
    expect(loadSoundEnabled()).toBe(true);
  });

  // The default flipped from off to on. A user who had already opted in — or
  // deliberately stayed out — keeps that choice; only the absence of a stored
  // value moves.
  it("keeps an explicit choice made under the previous default", () => {
    localStorage.setItem("ledger-sound", "false");
    expect(loadSoundEnabled()).toBe(false);

    localStorage.setItem("ledger-sound", "true");
    expect(loadSoundEnabled()).toBe(true);
  });

  it("treats an unreadable stored value as the default, not as disabled", () => {
    localStorage.setItem("ledger-sound", "off");
    expect(loadSoundEnabled()).toBe(true);
  });
});
