import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { PendingDevicePanel } from "./PendingDevicePanel";
import { comparisonCode, type EnrolmentRequest, type KeyHistoryEntry } from "../../v2/deviceEnrolment";

const REQ: EnrolmentRequest = {
  writerId: "web-second",
  publicKey: new Uint8Array(32).map((_, i) => (i * 5 + 1) & 0xff),
};
const LOG: KeyHistoryEntry[] = [
  { id: 1, writer_id: "ingest", pubkey: "", event: "registered", at: "2026-08-01T00:00:00Z" },
];

describe("PendingDevicePanel", () => {
  it("shows a code that carries only the writer id and the public key", async () => {
    render(<PendingDevicePanel request={REQ} loadKeyHistory={async () => LOG} onRecheck={() => {}} copy={async () => {}} />);
    expect(screen.getByTestId("enrolment-code")).toHaveTextContent("ledger-device-1:web-second:");
    expect(await screen.findByText(comparisonCode(REQ, LOG))).toBeInTheDocument();
  });

  it("copies the code", async () => {
    const copy = vi.fn(async () => {});
    render(<PendingDevicePanel request={REQ} loadKeyHistory={async () => LOG} onRecheck={() => {}} copy={copy} />);
    await userEvent.click(screen.getByRole("button", { name: /copy code/i }));
    expect(copy).toHaveBeenCalledWith(screen.getByTestId("enrolment-code").textContent);
    expect(await screen.findByRole("button", { name: /copied/i })).toBeInTheDocument();
  });

  /**
   * A comparison code that could not be derived shows NOTHING in its place. A
   * placeholder where a security check belongs is worse than an absent one:
   * the person compares two dashes and concludes they match.
   */
  it("shows no code at all when it could not derive one, and says why", async () => {
    render(
      <PendingDevicePanel
        request={REQ}
        loadKeyHistory={async () => {
          throw new Error("offline");
        }}
        onRecheck={() => {}}
        copy={async () => {}}
      />,
    );
    expect(await screen.findByText(/could not work out the check code/i)).toBeInTheDocument();
    expect(screen.queryByText(comparisonCode(REQ, LOG))).not.toBeInTheDocument();
    expect(screen.queryByText("—")).not.toBeInTheDocument();
  });

  /**
   * The comparison code is the HERO: it is the one string a person reads aloud
   * to someone holding the other device, and the only thing here that a
   * mismatch makes dangerous. It is bigger than the code it belongs to, which
   * is the payload you paste rather than the thing you read.
   *
   * jsdom has no layout, so this pins the type step rather than measuring
   * anything — it bites on a swap of the two treatments, which is the
   * regression that matters.
   */
  it("prints the check code larger than the code it belongs to", async () => {
    render(<PendingDevicePanel request={REQ} loadKeyHistory={async () => LOG} onRecheck={() => {}} copy={async () => {}} />);
    const hero = await screen.findByTestId("comparison-code-value");
    expect(hero.className).toContain("text-3xl");
    expect(screen.getByTestId("enrolment-code").className).toContain("text-xs");
  });

  /**
   * The numbering is gone with the three equal cards. There are two objects on
   * this screen, not three steps, and the order is carried by the headings.
   */
  it("does not number its sections as steps", async () => {
    render(<PendingDevicePanel request={REQ} loadKeyHistory={async () => LOG} onRecheck={() => {}} copy={async () => {}} />);
    await screen.findByTestId("comparison-code-value");
    expect(screen.queryByText(/^Step \d/)).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: /on your other device/i })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: /both devices must show/i })).toBeInTheDocument();
  });

  it("re-checks the roster on demand, because nothing tells this device it was approved", async () => {
    const onRecheck = vi.fn();
    render(<PendingDevicePanel request={REQ} loadKeyHistory={async () => LOG} onRecheck={onRecheck} copy={async () => {}} />);
    await userEvent.click(screen.getByRole("button", { name: /check again/i }));
    expect(onRecheck).toHaveBeenCalledTimes(1);
  });
});
