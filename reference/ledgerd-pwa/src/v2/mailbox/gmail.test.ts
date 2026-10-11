/**
 * The live Gmail driver's REQUEST shape — the half of the lane no fake can prove.
 *
 * Every other test in this directory injects a `GmailApi` fake, so nothing there
 * can tell whether the real driver asks Gmail the right question. The
 * load-bearing proof here is the one that was missing:
 *
 *   - `messages.list` carries `includeSpamTrash=true`. Without it a bank message
 *     Gmail spam-filed is invisible to BACKFILL forever, while
 *     `users.history.list` — which surfaces spam with no flag — sees it, so the
 *     two paths disagreed about what was in the mailbox. Mail forwarded to a
 *     burner fails SPF at the forwarding hop, which is precisely the signal
 *     Gmail spam-files on, so this is the common case and not the corner.
 *
 * The CSP-shaped paths are asserted alongside it, because a driver that asked the
 * right question at a path the CSP refuses would be just as dead.
 */
import { describe, expect, it } from "vitest";

import { gmailRest } from "./gmail";

/** A `fetch` that records its URLs and answers a fixed JSON body. */
function recordingFetch(body: unknown): { fn: typeof fetch; urls: string[] } {
  const urls: string[] = [];
  const fn = (async (input: RequestInfo | URL): Promise<Response> => {
    urls.push(String(input));
    return new Response(JSON.stringify(body), { status: 200 });
  }) as typeof fetch;
  return { fn, urls };
}

describe("messages.list", () => {
  it("asks Gmail to include SPAM, so spam-filed bank mail is not invisible to backfill", async () => {
    const { fn, urls } = recordingFetch({ messages: [{ id: "m1" }] });

    const page = await gmailRest("tok", fn).messagesList("newer_than:30d -in:trash");

    expect(page.messages).toEqual([{ id: "m1" }]);
    const url = new URL(urls[0]!);
    // The whole defect: this parameter absent means Gmail searches the inbox
    // only, and a spam-filed message can never be backfilled.
    expect(url.searchParams.get("includeSpamTrash")).toBe("true");
    expect(url.searchParams.get("q")).toBe("newer_than:30d -in:trash");
  });

  it("keeps the flag when paging, so page two is not narrower than page one", async () => {
    const { fn, urls } = recordingFetch({ messages: [], nextPageToken: undefined });

    await gmailRest("tok", fn).messagesList("newer_than:30d -in:trash", "page-2");

    const url = new URL(urls[0]!);
    expect(url.searchParams.get("includeSpamTrash")).toBe("true");
    expect(url.searchParams.get("pageToken")).toBe("page-2");
  });

  it("stays on the one path the CSP admits", async () => {
    const { fn, urls } = recordingFetch({ messages: [] });

    await gmailRest("tok", fn).messagesList("newer_than:30d");

    expect(urls[0]!.startsWith("https://gmail.googleapis.com/gmail/v1/users/me/messages?")).toBe(true);
  });
});

describe("history.list", () => {
  it("needs no spam flag — it is the flat path, and it already surfaces spam", async () => {
    const { fn, urls } = recordingFetch({ historyId: "42", history: [] });

    const page = await gmailRest("tok", fn).historyList("41");

    expect(page.historyId).toBe("42");
    // FLAT, no trailing slash: CSP3 prefix matching would never let `.../history/`
    // match this, and this is the one fetch that drives catch-up.
    expect(urls[0]!.startsWith("https://gmail.googleapis.com/gmail/v1/users/me/history?")).toBe(true);
  });
});
