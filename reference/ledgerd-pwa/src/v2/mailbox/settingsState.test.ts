import { describe, expect, it } from "vitest";

import { mailboxSettingsState } from "./settingsState";

describe("mailboxSettingsState", () => {
  it("is never_connected when there is no grant, whatever the token", () => {
    expect(mailboxSettingsState(null, false)).toBe("never_connected");
    expect(mailboxSettingsState(null, true)).toBe("never_connected");
  });

  it("is reconnect_required when the grant is dead, and it outranks holdership", () => {
    // A dead grant is dead for every device: a holder must see reconnect, not the
    // active screen whose "Catch up now" could only fail.
    expect(mailboxSettingsState("reconnect_required", true)).toBe("reconnect_required");
    expect(mailboxSettingsState("reconnect_required", false)).toBe("reconnect_required");
  });

  it("is active on a live grant when this device holds the token", () => {
    expect(mailboxSettingsState("active", true)).toBe("active");
    // Any live status string, not just the literal "active".
    expect(mailboxSettingsState("connected", true)).toBe("active");
  });

  it("is another_device on a live grant with no token here", () => {
    expect(mailboxSettingsState("active", false)).toBe("another_device");
  });
});
