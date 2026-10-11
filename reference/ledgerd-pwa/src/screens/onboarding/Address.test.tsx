/**
 * The address step, and the forwarding step that follows it.
 *
 * These tests exist because the forwarding half shipped as four hardcoded Gmail
 * sentences. Anybody on iCloud, Outlook or Fastmail was reading instructions for
 * a product they do not use, and the one provider whose flow has no confirmation
 * code at all was being told to wait for one.
 *
 * The second finding: the fix became a fork. A picker stood between the user
 * and the instructions with {@link GENERIC} demoted to a fallback row under a
 * rule, which made the pickable five look like the supported set. The answer to
 * THAT was the generic steps leading for everyone with per-provider disclosures
 * behind them — honest, and a wall of text.
 *
 * The shape now is the operator's: **pick the provider, then read only that
 * provider's steps.** The honesty is kept structurally instead of by ordering —
 * "Another provider" is a peer row in the same list, in the same shape, at the
 * same weight — and these tests assert that uniformity rather than the ordering,
 * because it is the property that actually stops the list reading as a
 * compatibility claim.
 */

import { describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

import { MotionProvider } from "../../app/MotionProvider";
import { GENERIC, PROVIDERS, providerFor } from "../../v2/providers";
import { enablePush, isPushSubscribed, type PushEnvironment } from "../../v2/webpush";
import { Address } from "./Address";
import { OPEN_CONFIRMATION_COPY } from "./SetupStatus";

const ADDRESS = "u-7f3a@in.ledger.example";

function mountForwarding(
  over: {
    onForwardingDeclared?: (expectConfirmation: boolean) => void;
    onProviderChosen?: (id: string) => void;
    directRoute?: boolean;
    /** Skips the picker, as a resumed device does — see `LocalOnboardingRecord.mailProvider`. */
    provider?: string;
  } = {},
) {
  const onForwardingDeclared = over.onForwardingDeclared ?? vi.fn();
  const onProviderChosen = over.onProviderChosen ?? vi.fn();
  render(
    <MotionProvider>
      <Address
        client={{ sessionToken: "tok" }}
        phase="forwarding"
        known={ADDRESS}
        onIssued={vi.fn()}
        onForwardingDeclared={onForwardingDeclared}
        onProviderChosen={onProviderChosen}
        copy={async () => {}}
        fetch={(async () => new Response("no route", { status: 404 })) as unknown as typeof fetch}
        {...(over.directRoute === undefined ? {} : { directRoute: over.directRoute })}
        {...(over.provider === undefined ? {} : { provider: over.provider })}
      />
    </MotionProvider>,
  );
  return { onForwardingDeclared, onProviderChosen };
}

/**
 * Answer the picker and land on one provider's steps.
 *
 * Defaults to the generic set, because that is the row every provider the
 * registry does not name resolves to — and because a helper that always picked
 * Gmail would leave the peer row exercised by nothing.
 */
async function intoForwarding(user: ReturnType<typeof userEvent.setup>, id = "other"): Promise<void> {
  await user.click(await screen.findByTestId(`provider-pick-${id}`));
  await screen.findByTestId(`provider-steps-${id}`);
}

/**
 * The route the operator retired, still built and still tested.
 *
 * It is off by default (`DIRECT_BANK_ROUTE`) because a bank's alert address is
 * also where that bank sends security alerts and one-time codes, and most banks
 * keep only one — so taking it costs the user their own bank. These tests pass
 * `directRoute` explicitly, which is the point of the flag: the retired route
 * must not rot while it is off, or turning it back on ships something nobody
 * has run.
 */
describe("the retired direct route, behind its flag", () => {
  it("offers both routes before any forwarding instructions appear", async () => {
    mountForwarding({ directRoute: true });
    const picker = await screen.findByTestId("route-picker");
    expect(within(picker).getByRole("button", { name: /with your bank directly/i })).toBeTruthy();
    expect(within(picker).getByRole("button", { name: /forward it from my email/i })).toBeTruthy();
    // Nothing about forwarding — not even the provider question — until the
    // route is chosen.
    expect(screen.queryByTestId("provider-pick-list")).toBeNull();
    expect(screen.queryByTestId("provider-steps-other")).toBeNull();
  });

  it("takes the direct route without a word about forwarding or confirmation codes", async () => {
    const user = userEvent.setup();
    mountForwarding({ directRoute: true });
    await user.click(await screen.findByRole("button", { name: /with your bank directly/i }));

    const steps = await screen.findByTestId("direct-steps");
    expect(steps.textContent).not.toMatch(/forward/i);
    expect(steps.textContent).not.toMatch(/confirmation code/i);
    expect(screen.queryByTestId("provider-pick-list")).toBeNull();
    expect(screen.getByTestId("inbound-address").textContent).toBe(ADDRESS);
  });

  it("reaches the same waiting state, expecting no confirmation code", async () => {
    const user = userEvent.setup();
    const onForwardingDeclared = vi.fn();
    mountForwarding({ onForwardingDeclared, directRoute: true });

    await user.click(await screen.findByRole("button", { name: /with your bank directly/i }));
    await user.click(screen.getByRole("button", { name: /i have set this address with my bank/i }));
    expect(onForwardingDeclared).toHaveBeenCalledWith(false);
  });

  /**
   * Not every bank lets a customer change the address, and some have only one.
   * Said on the route that would otherwise strand them.
   */
  it("says what to do when the bank will not let the address be changed", async () => {
    const user = userEvent.setup();
    mountForwarding({ directRoute: true });
    await user.click(await screen.findByRole("button", { name: /with your bank directly/i }));
    expect(screen.getByTestId("direct-caveat").textContent).toMatch(/only one|cannot be changed/i);
    // And the way out is on the same screen, not a step backwards. It lands on
    // the provider question, which is the forwarding route's first screen.
    await user.click(screen.getByRole("button", { name: /forward it from my email/i }));
    expect(await screen.findByTestId("provider-pick-list")).toBeTruthy();
  });
});

/**
 * The sunset, asserted on the DEFAULT — i.e. on what a real user gets, with no
 * prop passed. Everything above this describes the route with the flag forced
 * on, which is exactly the arrangement that would otherwise let it quietly come
 * back: a test that always passes `directRoute: true` cannot notice that the
 * default changed.
 */
describe("the bank-side route is not offered", () => {
  it("lands straight on the forwarding route, with no route to pick", async () => {
    mountForwarding();
    expect(await screen.findByTestId("provider-pick-list")).toBeTruthy();
    expect(screen.queryByTestId("route-picker")).toBeNull();
    expect(screen.queryByTestId("direct-steps")).toBeNull();
  });

  it("offers no way into it, from anywhere on either forwarding screen", async () => {
    const user = userEvent.setup();
    mountForwarding();
    await screen.findByTestId("provider-pick-list");
    await intoForwarding(user);
    for (const button of screen.getAllByRole("button")) {
      expect(button.textContent ?? "").not.toMatch(/with my bank directly|with your bank directly/i);
    }
    expect(screen.queryByRole("button", { name: /i have set this address with my bank/i })).toBeNull();
  });

  /**
   * It was "one rule … works with a bank that will not change the address" —
   * this route described as the consolation prize for a route that is gone.
   * What stays is the privacy claim, which is not a tooltip candidate: it is
   * what a careful person weighs before writing the rule.
   */
  /**
   * The one thing this route cannot do, on the screen where the user decides
   * how to route their mail.
   *
   * A hand-forward is refused permanently and by design — the new bytes break
   * the bank's DKIM signature and `origin.Decide` refuses the provider that
   * signed the result — so a user who presses Forward gets a held message and
   * no explanation until they open it. This says so BEFORE the rule is made,
   * for every provider, generic row included.
   */
  it("says a rule is required and that forwarding by hand cannot work", async () => {
    const user = userEvent.setup();
    for (const id of ["other", ...PROVIDERS.map((p) => p.id)]) {
      mountForwarding();
      await intoForwarding(user, id);
      const notice = screen.getByTestId("forwarding-manual-forward").textContent ?? "";
      expect(notice).toMatch(/pressing forward will not work/i);
      // The WHY, not just the refusal: a rule that says "no" and stops is the
      // sentence users work around.
      expect(notice).toMatch(/signature/i);
      cleanup();
    }
  });

  it("no longer presents forwarding as the second-best option", async () => {
    const user = userEvent.setup();
    mountForwarding();
    await intoForwarding(user);
    const page = document.body.textContent ?? "";
    expect(page).not.toMatch(/instead|the first one is steadier|recommended/i);
    // The privacy claim survived every rewrite of this screen, because it is
    // what a careful person weighs before writing the rule — not a tip.
    expect(page).toMatch(/never holds a password to it and is never sent the rest/i);
  });

  /**
   * Sunset, not deleted. The caveat that admits the route's own failure is the
   * record of why it was retired, so it travels WITH the route rather than
   * being tidied away first.
   */
  it("keeps the route, its copy and its caveat intact behind the flag", async () => {
    const user = userEvent.setup();
    mountForwarding({ directRoute: true });
    await user.click(await screen.findByRole("button", { name: /with your bank directly/i }));
    expect(screen.getByTestId("direct-caveat").textContent).toMatch(/only one alert address/i);
  });
});

/**
 * Pick a provider, then read that provider's steps.
 *
 * The question this describe exists to keep answered is not "does the picker
 * work" — it is **"does the picker lie"**. A list of five named providers plus a
 * demoted "other" tells a Fastmail user their provider is unsupported, which is
 * false: nothing downstream knows a provider, and anything with a forwarding
 * setting works. So the assertions are about the SHAPE of the generic row
 * against the named ones, not about the wording of a disclaimer.
 */
describe("the provider picker", () => {
  it("asks the provider before showing any instructions", async () => {
    mountForwarding();
    expect(await screen.findByTestId("provider-pick-list")).toBeInTheDocument();
    for (const p of PROVIDERS) expect(screen.queryByTestId(`provider-steps-${p.id}`)).toBeNull();
    expect(screen.queryByTestId("provider-steps-other")).toBeNull();
    expect(screen.queryByRole("button", { name: /i have set up forwarding/i })).toBeNull();
  });

  it("lists every named provider and the generic set, each once", async () => {
    mountForwarding();
    const list = await screen.findByTestId("provider-pick-list");
    for (const p of PROVIDERS) {
      expect(within(list).getByTestId(`provider-pick-${p.id}`)).toHaveTextContent(p.label);
    }
    expect(within(list).getByTestId("provider-pick-other")).toHaveTextContent(GENERIC.label);
  });

  /**
   * THE honesty assertion, and the reason the first version of this picker was
   * deleted. "Another provider" is IN the list, not under it; it is the same
   * element type with the same classes as every named row; and it opens the
   * generic steps in full rather than a shortened version of them.
   *
   * Asserted on the DOM rather than on a sentence, because a disclaimer under a
   * visually-demoted row is exactly the arrangement that got deleted.
   */
  it("renders the generic set as a peer row, not as a fallback under a rule", async () => {
    mountForwarding();
    const list = await screen.findByTestId("provider-pick-list");
    const generic = within(list).getByTestId("provider-pick-other");
    const named = within(list).getByTestId("provider-pick-gmail");
    // Same parent: one list, not a list plus an afterthought.
    expect(generic.parentElement).toBe(named.parentElement);
    // Same shape: identical classes, so it cannot be quietly made smaller,
    // dimmer or borderless without this failing.
    expect(generic.className).toBe(named.className);
    expect(generic.tagName).toBe(named.tagName);
  });

  it("gives the generic set every step it has, not a trimmed version", async () => {
    const user = userEvent.setup();
    mountForwarding();
    await intoForwarding(user, "other");
    const steps = screen.getByTestId("provider-steps-other");
    expect(within(steps).getAllByRole("listitem")).toHaveLength(GENERIC.steps.length);
    for (const step of GENERIC.steps) expect(steps.textContent).toContain(step);
  });

  it("reports the pick so the walk can remember it", async () => {
    const user = userEvent.setup();
    const onProviderChosen = vi.fn();
    mountForwarding({ onProviderChosen });
    await intoForwarding(user, "icloud");
    expect(onProviderChosen).toHaveBeenCalledWith("icloud");
  });

  /**
   * A resumed device (`LocalOnboardingRecord.mailProvider`) lands on the steps
   * it was reading, not back on the list it already answered.
   */
  it("skips the list for a device that already answered it", async () => {
    mountForwarding({ provider: "gmail" });
    expect(await screen.findByTestId("provider-steps-gmail")).toBeInTheDocument();
    expect(screen.queryByTestId("provider-pick-list")).toBeNull();
  });

  it("lets the answer be changed, without leaving the route", async () => {
    const user = userEvent.setup();
    mountForwarding({ provider: "gmail" });
    await screen.findByTestId("provider-steps-gmail");
    await user.click(screen.getByTestId("forwarding-change-provider"));
    expect(await screen.findByTestId("provider-pick-list")).toBeInTheDocument();
    await intoForwarding(user, "proton");
    expect(screen.getByTestId("provider-steps-proton")).toBeInTheDocument();
    expect(screen.queryByTestId("provider-steps-gmail")).toBeNull();
  });
});

describe("one provider's instructions", () => {
  it("shows only the chosen provider's steps, with the address to paste", async () => {
    const user = userEvent.setup();
    mountForwarding();
    await intoForwarding(user, "gmail");
    expect(screen.getByTestId("provider-steps-gmail").textContent).toMatch(/forwarding and pop\/imap/i);
    // No other provider's steps are anywhere on the screen.
    for (const p of PROVIDERS.filter((x) => x.id !== "gmail")) {
      expect(screen.queryByTestId(`provider-steps-${p.id}`)).toBeNull();
    }
    expect(screen.getByTestId("inbound-address").textContent).toBe(ADDRESS);
  });

  it("numbers the steps as an ordered list, and prints one numeral per step", async () => {
    const user = userEvent.setup();
    mountForwarding();
    await intoForwarding(user, "gmail");
    const steps = screen.getByTestId("provider-steps-gmail");
    expect(steps.tagName).toBe("OL");
    const items = within(steps).getAllByRole("listitem");
    expect(items).toHaveLength(providerFor("gmail").steps.length);
    // The numerals are decoration over a list that already numbers itself to a
    // screen reader, so they are hidden from it — two numbers per row is how a
    // screen reader reads "one one, two two".
    for (const item of items) {
      const numeral = item.querySelector('[aria-hidden="true"]');
      expect(numeral).not.toBeNull();
    }
    expect(items[0]?.querySelector('[aria-hidden="true"]')?.textContent).toBe("01");
  });

  it("says iCloud sends no confirmation code, rather than leaving the user waiting for one", async () => {
    const user = userEvent.setup();
    mountForwarding();
    await intoForwarding(user, "icloud");
    expect(screen.getByTestId("provider-steps-icloud").textContent).toMatch(/does not send a confirmation code/i);
  });

  /**
   * The Microsoft 365 default. Said before the user spends ten minutes finding
   * out that the setting will not save — and still a `Notice`, still above the
   * steps it may invalidate: "before the user tries" is a position on the page,
   * not a tone of voice.
   */
  it("keeps the work-account caveat as a Notice above the Outlook steps", async () => {
    const user = userEvent.setup();
    mountForwarding();
    await intoForwarding(user, "outlook");
    const caveat = screen.getByTestId("provider-caveat-outlook");
    expect(caveat.textContent).toMatch(/administrator/i);
    expect(caveat.textContent).toMatch(/work or school/i);
    const steps = screen.getByTestId("provider-steps-outlook");
    expect(caveat.compareDocumentPosition(steps) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("shows no caveat for a provider that has none", async () => {
    const user = userEvent.setup();
    mountForwarding();
    await intoForwarding(user, "gmail");
    expect(screen.getByTestId("provider-steps-gmail")).toBeInTheDocument();
    expect(screen.queryByTestId("provider-caveat-gmail")).toBeNull();
  });

  /**
   * The declaration carries the CHOSEN provider's `needsConfirmation`, which is
   * what decides whether the hand-off screen offers a confirmation affordance at
   * all. iCloud is the one `false` and the one case that matters: a user who
   * followed its steps has nothing left to do, and a screen telling them to wait
   * for a code would be waiting for a message that is never sent.
   */
  it("reports whether the chosen provider sends a confirmation", async () => {
    const user = userEvent.setup();
    const onForwardingDeclared = vi.fn();
    mountForwarding({ onForwardingDeclared, provider: "icloud" });
    await screen.findByTestId("provider-steps-icloud");
    await user.click(screen.getByRole("button", { name: /i have set up forwarding/i }));
    expect(onForwardingDeclared).toHaveBeenCalledWith(false);
  });

  it("expects a confirmation from every provider the evidence does not exempt", async () => {
    for (const id of ["gmail", "outlook", "yahoo", "proton", "other"]) {
      const user = userEvent.setup();
      const onForwardingDeclared = vi.fn();
      mountForwarding({ onForwardingDeclared, provider: id });
      await screen.findByTestId(`provider-steps-${id}`);
      await user.click(screen.getByRole("button", { name: /i have set up forwarding/i }));
      expect(onForwardingDeclared).toHaveBeenCalledWith(true);
      cleanup();
    }
  });
});

/**
 * The provider's held confirmation, surfaced where the user is.
 *
 * `SetupStatus` shows the same one-tap task on the home screen, but the person
 * who just made the rule is standing HERE, and the confirmation arrives while
 * this screen is up. Same words (imported from `SetupStatus`, not forked), same
 * pinned link, same fallback to held mail.
 */
describe("the held confirmation, as one tap on the forwarding screen", () => {
  /** The live Gmail confirmation's shape — the same body `verificationCode.test.ts` scans. */
  const CONFIRM_BODY = [
    "Return-Path: <forwarding-noreply@google.com>",
    "From: Gmail Team <forwarding-noreply@google.com>",
    "Subject: (#123456789) Gmail Forwarding Confirmation - Receive Mail from you@example.com",
    "Content-Type: text/plain; charset=UTF-8",
    "",
    "you@example.com has requested to automatically forward mail to your email address.",
    "",
    "Confirmation code: 123456789",
    "",
    "To allow it, click the link below:",
    "https://mail-settings.google.com/mail/vf-%5BANGjdJ8abcDEF123%5D-XyZ0",
    "",
  ].join("\r\n");
  const CONFIRM_URL = "https://mail-settings.google.com/mail/vf-%5BANGjdJ8abcDEF123%5D-XyZ0";

  /** A quarantine page as the wire sends it, holding one verified candidate. */
  const HELD_PAGE = {
    items: [
      {
        id: "held-1",
        ingest_id: "ing-1",
        received_at: "2026-08-09T15:15:34Z",
        expires_at: "2026-09-08T15:15:34Z",
        outer_domain: "google.com",
        inner_domain: "",
        attested: false,
        attested_by: "",
        dkim: "pass",
        arc: "pass",
        size_bucket: 1,
        blob: Buffer.from(CONFIRM_BODY, "utf8").toString("base64"),
      },
    ],
    action_needed: 1,
    expiring_soon: 0,
  };

  it("renders the notice for a held candidate, and its action opens the pinned url", async () => {
    const user = userEvent.setup();
    const openUrl = vi.fn();
    const quarantineCalls: string[] = [];
    const doFetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/api/v1/quarantine")) {
        quarantineCalls.push(url);
        return new Response(JSON.stringify(HELD_PAGE), { status: 200 });
      }
      return new Response("no route", { status: 404 });
    }) as unknown as typeof fetch;

    render(
      <MotionProvider>
        <Address
          client={{ sessionToken: "tok" }}
          phase="forwarding"
          known={ADDRESS}
          onIssued={vi.fn()}
          onForwardingDeclared={vi.fn()}
          provider="gmail"
          copy={async () => {}}
          fetch={doFetch}
          openUrl={openUrl}
          onOpenHeldMail={vi.fn()}
        />
      </MotionProvider>,
    );

    // The same notice SetupStatus shows: same title, same body, the verified
    // domain verbatim as evidence — the copy imported, not forked.
    const notice = await screen.findByTestId("forwarding-confirmation");
    expect(notice.textContent).toContain(OPEN_CONFIRMATION_COPY.title);
    expect(notice.textContent).toContain(OPEN_CONFIRMATION_COPY.body);
    expect(screen.getByTestId("forwarding-confirmation-domain").textContent).toBe("google.com");
    // The blob was actually asked for — the link is read out of it.
    expect(quarantineCalls[0]).toContain("include_blob=1");

    await user.click(screen.getByRole("button", { name: OPEN_CONFIRMATION_COPY.action }));
    expect(openUrl).toHaveBeenCalledWith(CONFIRM_URL);
  });
});

/**
 * "Get a notification when it arrives" — the optional, skippable opt-in.
 *
 * The confirmation can land long after the rule is made, so this offers to buzz
 * the phone when it does. It gates nothing (the confirmation surfaces in-app
 * regardless), it is offered only where push can actually work, and it never
 * re-asks a browser that already holds a subscription. Support and subscription
 * are probed through the same seams the Settings panel uses, so the control is
 * exercised here without a real service worker.
 */
describe("the optional notification opt-in on the forwarding screen", () => {
  const NOTIFY_ACTION = /get a notification when it arrives/i;

  /** A supported browser, exactly as `PushNotificationsPanel.test` builds one. */
  function supportedEnv(permission: NotificationPermission = "default"): PushEnvironment {
    return {
      navigator: { serviceWorker: {} } as unknown as Navigator,
      notification: { permission, requestPermission: vi.fn() },
      secureContext: true,
    };
  }

  function renderNotify(over: {
    env?: PushEnvironment;
    enable?: typeof enablePush;
    subscribed?: typeof isPushSubscribed;
  }) {
    render(
      <MotionProvider>
        <Address
          client={{ sessionToken: "tok" }}
          phase="forwarding"
          known={ADDRESS}
          onIssued={vi.fn()}
          onForwardingDeclared={vi.fn()}
          provider="gmail"
          copy={async () => {}}
          // 404s the held-mail read, so no confirmation is in hand and the
          // opt-in is on screen.
          fetch={(async () => new Response("no route", { status: 404 })) as unknown as typeof fetch}
          {...(over.env === undefined ? {} : { env: over.env })}
          {...(over.enable === undefined ? {} : { enable: over.enable })}
          {...(over.subscribed === undefined ? {} : { subscribed: over.subscribed })}
        />
      </MotionProvider>,
    );
  }

  it("offers the control when push is supported and unsubscribed, and tapping it enables push", async () => {
    vi.stubGlobal("PushManager", function PushManager() {});
    const user = userEvent.setup();
    const enable = vi.fn(async () => ({ kind: "on" }) as const);
    renderNotify({ env: supportedEnv(), enable, subscribed: async () => false });

    const button = await screen.findByRole("button", { name: NOTIFY_ACTION });
    await user.click(button);

    expect(enable).toHaveBeenCalledTimes(1);
    // Once it is on, the honest confirmation takes the button's place.
    await screen.findByTestId("notify-on");
    expect(screen.queryByRole("button", { name: NOTIFY_ACTION })).toBeNull();
  });

  it("shows the honest iOS reason instead of a button when push needs a Home Screen install", async () => {
    // Supported in every other respect, but no PushManager — the iOS-Safari-tab
    // case, whose fix is the one the reason string names.
    vi.stubGlobal("PushManager", undefined);
    const enable = vi.fn(async () => ({ kind: "on" }) as const);
    renderNotify({ env: supportedEnv(), enable, subscribed: async () => false });

    const reason = await screen.findByTestId("notify-unsupported");
    expect(reason).toHaveTextContent(/add ledger to your Home Screen/i);
    expect(screen.queryByRole("button", { name: NOTIFY_ACTION })).toBeNull();
    expect(enable).not.toHaveBeenCalled();
  });

  it("stays out of the way when this browser already holds a subscription", async () => {
    vi.stubGlobal("PushManager", function PushManager() {});
    renderNotify({ env: supportedEnv(), subscribed: async () => true, enable: vi.fn(async () => ({ kind: "on" }) as const) });

    // The screen is up; the opt-in resolves to nothing — no offer, no reason.
    await screen.findByTestId("provider-steps-gmail");
    await waitFor(() => {
      expect(screen.queryByTestId("notify-opt-in")).toBeNull();
      expect(screen.queryByRole("button", { name: NOTIFY_ACTION })).toBeNull();
      expect(screen.queryByTestId("notify-unsupported")).toBeNull();
    });
  });
});
