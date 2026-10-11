import { beforeAll, describe, expect, it, vi } from "vitest";

import { setPlatform } from "@ledger/client/platform.registry";
import { webPlatform } from "@ledger/client/platform.web";
import type { Definition } from "@ledger/client/tmpl/exec";

import { MailboxError } from "../mailboxConnect";
import type { GmailApi, GmailRawMessage } from "./gmail";
import { loadMailboxReviewContent, type MailboxReviewContentDeps } from "./reviewContent";

// A tiny RFC822 message, verbatim bytes. The tests inject `decodeBase64Url` so
// the base64 layer is never in the way — `getRaw` hands back an opaque marker
// and the decoder returns exactly these bytes.
function messageBytes(headers: string, body: string): Uint8Array {
  return new TextEncoder().encode(`${headers}\r\n\r\n${body}`);
}

const PASSING_HEADERS = ["Authentication-Results: mx.google.com; dkim=pass header.d=dib.ae", "From: alerts@dib.ae", "Subject: Card purchase"].join(
  "\r\n",
);
const UNSIGNED_HEADERS = ["From: alerts@dib.ae", "Subject: Card purchase"].join("\r\n");

/** A published template for `dib.ae`, shaped like a real one. */
const DIB_TEMPLATE: Definition = {
  id: "dib.card.v1",
  version: 1,
  bank: "dib",
  normalizer_version: 1,
  match: { sender_domain: ["dib.ae"], subject_contains: ["purchase"] },
  default_currency: "AED",
  date_from: "email",
  extract: [
    { field: "amount", type: "amount", source: "body", patterns: ["AED (?P<amt>[0-9,]+\\.[0-9]{2})"] },
    { field: "merchant", type: "text", source: "body", patterns: ["at (?P<v>[A-Z ]+) on"] },
    { field: "direction", type: "const", source: "body", value: "debit" },
  ],
  required: ["amount", "merchant"],
};

function fakeGmail(raw: GmailRawMessage, spy?: (id: string) => void): GmailApi {
  return {
    profile: async () => ({ historyId: "1" }),
    historyList: async () => ({ added: [], historyId: "1" }),
    messagesList: async () => ({ messages: [] }),
    getRaw: async (id: string) => {
      spy?.(id);
      return raw;
    },
  };
}

function baseDeps(over: Partial<MailboxReviewContentDeps> = {}): MailboxReviewContentDeps {
  return {
    provenance: { message_id: "m-1" },
    receivedAt: "2026-08-01T00:00:00.000Z",
    hasSealedToken: async () => true,
    mintAccessToken: async () => "access-token",
    loadTemplates: async () => [],
    makeGmail: () => fakeGmail({ id: "m-1", rawBase64Url: "IGNORED", internalDate: "" }),
    decodeBase64Url: () => messageBytes(UNSIGNED_HEADERS, "You spent AED 50 at Corner Shop"),
    ...over,
  };
}

beforeAll(() => {
  setPlatform(webPlatform);
});

describe("loadMailboxReviewContent — device states", () => {
  it("non-holder device: no sealed token, and it NEVER attempts a re-fetch", async () => {
    const mint = vi.fn(async () => "access-token");
    const getRaw = vi.fn();
    const result = await loadMailboxReviewContent(
      baseDeps({
        hasSealedToken: async () => false,
        mintAccessToken: mint,
        makeGmail: () => fakeGmail({ id: "m-1", rawBase64Url: "x", internalDate: "" }, getRaw),
      }),
    );
    expect(result.state).toBe("non_holder");
    expect(mint).not.toHaveBeenCalled();
    expect(getRaw).not.toHaveBeenCalled();
  });

  it("a residual/unreadable token (hasSealedToken throws) is treated as non-holder, never a crash", async () => {
    const result = await loadMailboxReviewContent(
      baseDeps({
        hasSealedToken: async () => {
          throw new Error("residual row");
        },
      }),
    );
    expect(result.state).toBe("non_holder");
  });

  it("dead token: mintAccessToken throws reconnect_required → reconnect_required (not an error)", async () => {
    const result = await loadMailboxReviewContent(
      baseDeps({
        mintAccessToken: async () => {
          throw new MailboxError("reconnect_required", "reconnect the mailbox");
        },
      }),
    );
    expect(result.state).toBe("reconnect_required");
  });

  it("a non-reconnect mint failure is unavailable, distinct from reconnect", async () => {
    const result = await loadMailboxReviewContent(
      baseDeps({
        mintAccessToken: async () => {
          throw new MailboxError("offline", "no answer");
        },
      }),
    );
    expect(result.state).toBe("unavailable");
  });

  it("holder + live token: re-fetches by message_id and returns a normalized text preview", async () => {
    const getRaw = vi.fn((id: string) => {
      expect(id).toBe("m-42");
    });
    const result = await loadMailboxReviewContent(
      baseDeps({
        provenance: { message_id: "m-42" },
        makeGmail: () => fakeGmail({ id: "m-42", rawBase64Url: "x", internalDate: "" }, getRaw),
      }),
    );
    expect(getRaw).toHaveBeenCalledTimes(1);
    if (result.state !== "ready") throw new Error(`want ready, got ${result.state}`);
    expect(result.prefill.body).toContain("Corner Shop");
  });

  it("no A-R pass ⇒ no trust domain offered (trusting it could not enable auto-import)", async () => {
    const result = await loadMailboxReviewContent(baseDeps());
    if (result.state !== "ready") throw new Error(`want ready, got ${result.state}`);
    expect(result.trustDomain).toBeNull();
  });

  it("a passing Gmail A-R ⇒ the verified signing domain is offered for trust", async () => {
    const result = await loadMailboxReviewContent(
      baseDeps({
        decodeBase64Url: () => messageBytes(PASSING_HEADERS, "You spent AED 50 at Corner Shop"),
      }),
    );
    if (result.state !== "ready") throw new Error(`want ready, got ${result.state}`);
    expect(result.trustDomain).toBe("dib.ae");
  });

  /**
   * A hand-forward verifies — Gmail really did sign it — but the domain it
   * vouches for is the FORWARDER. Offering that for trust would auto-file every
   * message relayed through the mailbox, as permanent ops on every device, and
   * the server refuses it anyway (409 `forwarder_domain`). The card must still
   * load and still prefill from the forwarded body; it is only the trust offer
   * that is withheld.
   */
  it("a passing A-R for a FORWARDER offers nothing to trust, though the card still loads", async () => {
    const forwarded = [
      "Authentication-Results: mx.google.com; dkim=pass header.d=gmail.com",
      "From: me@gmail.com",
      "Subject: Fwd: Card purchase",
    ].join("\r\n");
    const result = await loadMailboxReviewContent(
      baseDeps({
        decodeBase64Url: () => messageBytes(forwarded, "You spent AED 50 at Corner Shop"),
      }),
    );
    if (result.state !== "ready") throw new Error(`want ready, got ${result.state}`);
    expect(result.trustDomain).toBeNull();
  });

  it("a fetch failure at Gmail is unavailable, never a throw out of the loader", async () => {
    const result = await loadMailboxReviewContent(
      baseDeps({
        makeGmail: () => ({
          profile: async () => ({ historyId: "1" }),
          historyList: async () => ({ added: [], historyId: "1" }),
          messagesList: async () => ({ messages: [] }),
          getRaw: async () => {
            throw new Error("gmail 500");
          },
        }),
      }),
    );
    expect(result.state).toBe("unavailable");
  });

  it("tries the VERIFIED domain's template, not only the claimed From's", async () => {
    // The two paths must agree about one message. `fetch.ts` tries the verified
    // domain first and the claimed `From:` second; this used to try the claimed
    // From alone, so a bank that signs as `dib.ae` but sends from another domain
    // got a prefilled card on the fetch path and a bare "no reader for this
    // sender" here — the same message, two answers.
    const headers = [
      "Authentication-Results: mx.google.com; dkim=pass header.d=dib.ae",
      "From: no-reply@alerts.dibmail.example",
      "Subject: Card purchase",
    ].join("\r\n");
    const result = await loadMailboxReviewContent(
      baseDeps({
        loadTemplates: async () => [DIB_TEMPLATE],
        decodeBase64Url: () => messageBytes(headers, "You spent AED 50.00 at CORNER SHOP on 01/08/2026."),
      }),
    );
    if (result.state !== "ready") throw new Error(`want ready, got ${result.state}`);
    expect(result.prefill.templateId).toBe("dib.card.v1");
    expect(result.prefill.draft).not.toBeNull();
  });

  it("still tries the claimed From when there is no verified domain at all", async () => {
    // The pre-existing behaviour, kept: an unsigned message still narrows by its
    // own claim. Matching is not believing — nothing here files anything.
    const result = await loadMailboxReviewContent(
      baseDeps({
        loadTemplates: async () => [DIB_TEMPLATE],
        decodeBase64Url: () => messageBytes(UNSIGNED_HEADERS, "You spent AED 50.00 at CORNER SHOP on 01/08/2026."),
      }),
    );
    if (result.state !== "ready") throw new Error(`want ready, got ${result.state}`);
    expect(result.prefill.templateId).toBe("dib.card.v1");
    expect(result.trustDomain).toBeNull(); // and it is still not trusted
  });

  it("reads the A-R out of a message far larger than the parser's 256 KiB ceiling", async () => {
    // The ceiling bounds a HEADER BLOCK. Handed the whole message it made every
    // mail over 256 KiB a parse_error on size alone, so no big HTML bank alert
    // could ever offer its verified domain for trust.
    const body = "You spent AED 50 at Corner Shop\r\n" + "y".repeat(300 * 1024);
    const result = await loadMailboxReviewContent(
      baseDeps({ decodeBase64Url: () => messageBytes(PASSING_HEADERS, body) }),
    );
    if (result.state !== "ready") throw new Error(`want ready, got ${result.state}`);
    expect(result.trustDomain).toBe("dib.ae");
  });

  it("an undecodable body is unavailable, not a crash", async () => {
    const result = await loadMailboxReviewContent(
      baseDeps({
        decodeBase64Url: () => {
          throw new Error("strict decoder refused it");
        },
      }),
    );
    expect(result.state).toBe("unavailable");
  });
});
