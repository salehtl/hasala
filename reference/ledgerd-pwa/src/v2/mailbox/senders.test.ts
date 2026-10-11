import { describe, expect, it, vi } from "vitest";

import { isMailboxError } from "../mailboxConnect";
import type { V2Handle } from "../session";
import { isForwarderDomain, listSenders, trustSender } from "./senders";

function fakeHandle(sessionToken: string | null = "session-token"): V2Handle {
  return {
    client: {
      get sessionToken(): string | null {
        return sessionToken;
      },
      get server(): string {
        return "";
      },
    },
  } as unknown as V2Handle;
}

function jsonRes(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status });
}

describe("listSenders", () => {
  it("GETs the mailbox sender list and returns the domains", async () => {
    const fetchMock = vi.fn(async () => jsonRes(200, { domains: ["dib.ae", "enbd.com"] }));
    const out = await listSenders(fakeHandle(), { fetch: fetchMock as unknown as typeof fetch });
    expect(out).toEqual(["dib.ae", "enbd.com"]);
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("/api/v1/mailbox/senders");
    expect((init as RequestInit).method).toBe("GET");
    expect((init as RequestInit).headers).toMatchObject({ Authorization: "Bearer session-token" });
  });

  it("reads a malformed body as an empty list rather than throwing", async () => {
    const fetchMock = vi.fn(async () => new Response("not json", { status: 200 }));
    expect(await listSenders(fakeHandle(), { fetch: fetchMock as unknown as typeof fetch })).toEqual([]);
  });

  it("turns a non-ok answer into a typed MailboxError", async () => {
    const fetchMock = vi.fn(async () => jsonRes(503, { error: "unavailable" }));
    const err = await listSenders(fakeHandle(), { fetch: fetchMock as unknown as typeof fetch }).catch((e) => e);
    expect(isMailboxError(err)).toBe(true);
  });
});

describe("isForwarderDomain", () => {
  it("names the mail providers, exactly and by subdomain", () => {
    for (const d of ["gmail.com", "GMAIL.COM", " icloud.com ", "google.com", "mail.gmail.com", "outlook.com"]) {
      expect(isForwarderDomain(d)).toBe(true);
    }
  });

  it("leaves a bank alone — including one whose name merely ends in a forwarder's letters", () => {
    for (const d of ["", "dib.ae", "emiratesnbd.com", "notgmail.com", "gmail.com.example.ae"]) {
      expect(isForwarderDomain(d)).toBe(false);
    }
  });
});

describe("trustSender", () => {
  it("POSTs the domain and resolves on 204", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    await trustSender(fakeHandle(), "dib.ae", { fetch: fetchMock as unknown as typeof fetch });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("/api/v1/mailbox/senders");
    expect((init as RequestInit).method).toBe("POST");
    expect(JSON.parse((init as RequestInit).body as string)).toEqual({ domain: "dib.ae" });
  });

  it("surfaces the server's 409 (too many / forwarder) as a MailboxError", async () => {
    const fetchMock = vi.fn(async () => jsonRes(409, { error: "too_many_senders" }));
    const err = await trustSender(fakeHandle(), "dib.ae", { fetch: fetchMock as unknown as typeof fetch }).catch((e) => e);
    expect(isMailboxError(err)).toBe(true);
  });

  it("refuses a forwarder domain without ever reaching the network", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    for (const d of ["gmail.com", "GMAIL.COM", "google.com", "icloud.com", "mail.gmail.com"]) {
      const err = await trustSender(fakeHandle(), d, { fetch: fetchMock as unknown as typeof fetch }).catch((e) => e);
      expect(isMailboxError(err) && err.code).toBe("forwarder_domain");
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("is offline, not unavailable, when the transport itself throws", async () => {
    const fetchMock = vi.fn(async () => {
      throw new TypeError("network down");
    });
    const err = await trustSender(fakeHandle(), "dib.ae", { fetch: fetchMock as unknown as typeof fetch }).catch((e) => e);
    expect(isMailboxError(err) && err.mailboxKind).toBe("offline");
  });
});
