import { describe, expect, test } from "bun:test";
import { BODY, OK_ANSWER, call, fakes, request } from "./helpers";

const ARABIC = "مطعم الياسمين الشعبي";
const UNKNOWN_ANSWER = { answers: { category: { choice: "unknown", probabilities: { unknown: 1 } } } };

function withCategories(categories: unknown): unknown {
  return { subject: "CAFE EXAMPLE JBR", categories };
}

function cats(n: number): { id: string; name: string; hint: null }[] {
  return Array.from({ length: n }, (_, i) => ({ id: `c${i}`, name: `Cat ${i}`, hint: null }));
}

async function expectBad(body: unknown, opts: Parameters<typeof request>[1] = {}): Promise<void> {
  const f = fakes();
  const r = await call(f, request(body, opts));
  expect(r.status).toBe(400);
  expect(r.body).toEqual({ error: "bad_request" });
  expect(f.aiCalls.length).toBe(0);
}

describe("success", () => {
  test("returns the mapped answer", async () => {
    const f = fakes();
    const r = await call(f, request(BODY));
    expect(r.status).toBe(200);
    expect(r.body).toEqual({
      tag: "cf-clef/1",
      choice: "dining",
      probabilities: { groceries: 0.0095, dining: 0.9725, unknown: 0.012 },
    });
  });

  test("builds the exact Clef body", async () => {
    const f = fakes();
    await call(f, request(BODY));
    expect(f.aiCalls.length).toBe(1);
    expect(f.aiCalls[0]!.model).toBe("@cf/cloudflare/clef");
    expect(JSON.stringify(f.aiCalls[0]!.input)).toBe(
      JSON.stringify({
        model: "clef",
        state:
          'The merchant name on a card payment from a bank in the United Arab Emirates: "CAFE EXAMPLE JBR"',
        questions: {
          category: {
            type: "choice",
            instructions: "Which spending category does a payment to this merchant belong to?",
            criteria: {
              groceries: "supermarkets and grocery stores",
              dining: "Dining",
              unknown: "the name alone does not say what kind of business this is",
            },
          },
        },
      }),
    );
  });

  test("trims the subject and strips control characters", async () => {
    const f = fakes();
    await call(f, request({ ...BODY, subject: "  CAFE\u0000 EXAMPLE\u001f\u007f JBR\n " }));
    const input = f.aiCalls[0]!.input as { state: string };
    expect(input.state).toBe(
      'The merchant name on a card payment from a bank in the United Arab Emirates: "CAFE EXAMPLE JBR"',
    );
  });

  test("quotes in the subject stay JSON-safe", async () => {
    const f = fakes();
    await call(f, request({ ...BODY, subject: 'CAFE "EXAMPLE" \\ JBR' }));
    const input = f.aiCalls[0]!.input as { state: string };
    expect(input.state.endsWith(': "CAFE "EXAMPLE" \\ JBR"')).toBe(true);
    expect(JSON.parse(JSON.stringify(f.aiCalls[0]!.input))).toEqual(f.aiCalls[0]!.input);
  });

  test("Arabic subject is accepted", async () => {
    const f = fakes();
    const r = await call(f, request({ ...BODY, subject: ARABIC }));
    expect(r.status).toBe(200);
    expect((f.aiCalls[0]!.input as { state: string }).state).toContain(`"${ARABIC}"`);
  });

  test("a missing hint is treated as null", async () => {
    const f = fakes();
    const r = await call(f, request(withCategories([{ id: "dining", name: "Dining" }])));
    expect(r.status).toBe(200);
    const input = f.aiCalls[0]!.input as { questions: { category: { criteria: Record<string, string> } } };
    expect(input.questions.category.criteria.dining).toBe("Dining");
  });

  test("content type with charset is accepted", async () => {
    const r = await call(fakes(), request(BODY, { headers: { "content-type": "application/json; charset=utf-8" } }));
    expect(r.status).toBe(200);
  });
});

describe("validation", () => {
  test("missing Hasala-Client", () => expectBad(BODY, { headers: { "hasala-client": null } }));
  test("malformed Hasala-Client", async () => {
    for (const v of ["ios", "ios/", "android/1.0", "ios/1.4.0-beta", "IOS/1.4.0", "ios/1..4", " ios/1.4.0x"]) {
      await expectBad(BODY, { headers: { "hasala-client": v } });
    }
  });
  test("wrong content type", async () => {
    await expectBad(BODY, { headers: { "content-type": "text/plain" } });
    await expectBad(BODY, { headers: { "content-type": null } });
    await expectBad(BODY, { headers: { "content-type": "application/json; charset=latin1" } });
  });
  test("not JSON", () => expectBad(null, { raw: "{" }));
  test("JSON that is not an object", async () => {
    await expectBad(null, { raw: "[]" });
    await expectBad(null, { raw: '"x"' });
    await expectBad(null, { raw: "null" });
  });
  test("unknown top-level field", () => expectBad({ ...BODY, extra: 1 }));
  test("missing subject", () => expectBad({ categories: BODY.categories }));
  test("missing categories", () => expectBad({ subject: "CAFE EXAMPLE JBR" }));
  test("subject not a string", () => expectBad({ ...BODY, subject: 42 }));
  test("subject empty after trim", async () => {
    await expectBad({ ...BODY, subject: "   " });
    await expectBad({ ...BODY, subject: "\u0001\u0002 " });
  });
  test("subject length counts scalars", async () => {
    const ok = await call(fakes(), request({ ...BODY, subject: "😀".repeat(128) }));
    expect(ok.status).toBe(200);
    await expectBad({ ...BODY, subject: "a".repeat(129) });
    await expectBad({ ...BODY, subject: "😀".repeat(129) });
  });
  test("subject with a lone surrogate", () => expectBad(null, { raw: '{"subject":"A\\ud800B","categories":[{"id":"a","name":"A","hint":null}]}' }));
  test("categories not an array", () => expectBad(withCategories({})));
  test("categories empty", () => expectBad(withCategories([])));
  test("categories count", async () => {
    expect((await call(fakes({ answer: UNKNOWN_ANSWER }), request(withCategories(cats(32))))).status).toBe(200);
    await expectBad(withCategories(cats(33)));
  });
  test("category not an object", () => expectBad(withCategories(["dining"])));
  test("category unknown field", () => expectBad(withCategories([{ id: "dining", name: "Dining", hint: null, x: 1 }])));
  test("category id pattern", async () => {
    for (const id of ["", "Dining", "1dining", "_d", "din-ing", "a".repeat(33), "dining ", 7]) {
      await expectBad(withCategories([{ id, name: "Dining", hint: null }]));
    }
    expect((await call(fakes({ answer: UNKNOWN_ANSWER }), request(withCategories([{ id: "a".repeat(32), name: "A", hint: null }])))).status).toBe(200);
  });
  test("category id unknown is reserved", () => expectBad(withCategories([{ id: "unknown", name: "Unknown", hint: null }])));
  test("category ids unique", () =>
    expectBad(
      withCategories([
        { id: "dining", name: "Dining", hint: null },
        { id: "dining", name: "Food", hint: null },
      ]),
    ));
  test("category name bounds", async () => {
    await expectBad(withCategories([{ id: "dining", hint: null }]));
    await expectBad(withCategories([{ id: "dining", name: "", hint: null }]));
    await expectBad(withCategories([{ id: "dining", name: "n".repeat(65), hint: null }]));
    await expectBad(withCategories([{ id: "dining", name: 3, hint: null }]));
    expect((await call(fakes(), request(withCategories([{ id: "dining", name: "n".repeat(64), hint: null }])))).status).toBe(200);
  });
  test("category hint bounds", async () => {
    await expectBad(withCategories([{ id: "dining", name: "Dining", hint: "" }]));
    await expectBad(withCategories([{ id: "dining", name: "Dining", hint: "h".repeat(201) }]));
    await expectBad(withCategories([{ id: "dining", name: "Dining", hint: 5 }]));
    expect((await call(fakes(), request(withCategories([{ id: "dining", name: "Dining", hint: "h".repeat(200) }])))).status).toBe(200);
  });
  test("invalid UTF-8", async () => {
    const f = fakes();
    const bytes = new Uint8Array([0x7b, 0x22, 0xff, 0x22, 0x7d]);
    const req = new Request("https://assist.hasala.app/v1/category", {
      method: "POST",
      headers: { "hasala-client": "ios/1.4.0", "content-type": "application/json" },
      body: bytes,
    });
    const r = await call(f, req);
    expect(r.status).toBe(400);
  });
});

describe("size", () => {
  test("body over 8 KiB is 413", async () => {
    const f = fakes();
    const raw = JSON.stringify({ ...BODY, subject: "x".repeat(9000) });
    const r = await call(f, request(null, { raw }));
    expect(r.status).toBe(413);
    expect(r.body).toEqual({ error: "too_large" });
    expect(f.aiCalls.length).toBe(0);
  });
  test("streamed body over 8 KiB without content-length is 413", async () => {
    const chunk = new TextEncoder().encode(" ".repeat(4096));
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(chunk);
        c.enqueue(chunk);
        c.enqueue(chunk);
        c.close();
      },
    });
    const req = new Request("https://assist.hasala.app/v1/category", {
      method: "POST",
      headers: { "hasala-client": "ios/1.4.0", "content-type": "application/json" },
      body: stream,
    });
    const r = await call(fakes(), req);
    expect(r.status).toBe(413);
  });
  test("declared content-length over 8 KiB is 413", async () => {
    const r = await call(fakes(), request(BODY, { headers: { "content-length": "8193" } }));
    expect(r.status).toBe(413);
  });
});

describe("response mapping", () => {
  test("drops keys that are not request ids or unknown", async () => {
    const answer = {
      answers: {
        category: {
          type: "choice",
          choice: "groceries",
          probabilities: { groceries: 0.7, dining: 0.2, unknown: 0.05, transport: 0.05, __proto__x: 1 },
          confidence: 0.6,
        },
      },
    };
    const r = await call(fakes({ answer }), request(BODY));
    expect(r.status).toBe(200);
    expect(r.body).toEqual({
      tag: "cf-clef/1",
      choice: "groceries",
      probabilities: { groceries: 0.7, dining: 0.2, unknown: 0.05 },
    });
  });
  test("drops probabilities that are not numbers in [0, 1]", async () => {
    const answer = {
      answers: { category: { choice: "dining", probabilities: { groceries: "0.1", dining: 1.5, unknown: 0.3 } } },
    };
    const r = await call(fakes({ answer }), request(BODY));
    expect(r.body.probabilities).toEqual({ unknown: 0.3 });
  });
  test("handles a result wrapper", async () => {
    const r = await call(fakes({ answer: { result: OK_ANSWER } }), request(BODY));
    expect(r.status).toBe(200);
    expect(r.body.choice).toBe("dining");
  });
  test("choice unknown is allowed", async () => {
    const answer = { answers: { category: { choice: "unknown", probabilities: { unknown: 0.9 } } } };
    const r = await call(fakes({ answer }), request(BODY));
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ tag: "cf-clef/1", choice: "unknown", probabilities: { unknown: 0.9 } });
  });
  test("a choice outside the request is 502", async () => {
    const answer = { answers: { category: { choice: "transport", probabilities: { transport: 1 } } } };
    const r = await call(fakes({ answer }), request(BODY));
    expect(r.status).toBe(502);
    expect(r.body).toEqual({ error: "bad_model_answer" });
  });
  test("a malformed answer is 502", async () => {
    for (const answer of [null, "dining", {}, { answers: {} }, { answers: { category: { choice: 3 } } }, { answers: { category: { choice: "dining" } } }]) {
      const r = await call(fakes({ answer }), request(BODY));
      expect(r.status).toBe(502);
    }
  });
});

describe("errors", () => {
  test("AI throws is 503", async () => {
    const r = await call(fakes({ aiThrows: true }), request(BODY));
    expect(r.status).toBe(503);
    expect(r.body).toEqual({ error: "model_unavailable" });
  });
  test("other path is 404", async () => {
    for (const path of ["/", "/v1", "/v1/category/", "/v2/category"]) {
      const r = await call(fakes(), request(BODY, { path }));
      expect(r.status).toBe(404);
    }
    const r = await call(fakes(), request(null, { path: "/x", method: "GET" }));
    expect(r.status).toBe(404);
  });
  test("non-POST on the path is 405", async () => {
    for (const method of ["GET", "PUT", "DELETE", "PATCH"]) {
      const r = await call(fakes(), request(BODY, { method }));
      expect(r.status).toBe(405);
      expect(r.body).toEqual({ error: "method_not_allowed" });
    }
  });
});

describe("refused clients", () => {
  test("an exact listed version is 403", async () => {
    const f = fakes({ refused: "ios/1.2.0, ios/1.4.0" });
    const r = await call(f, request(BODY));
    expect(r.status).toBe(403);
    expect(r.body).toEqual({ error: "client_refused" });
    expect(f.aiCalls.length).toBe(0);
  });
  test("a prefix does not match", async () => {
    const r = await call(fakes({ refused: "ios/1.4" }), request(BODY));
    expect(r.status).toBe(200);
  });
  test("an empty list refuses nothing", async () => {
    expect((await call(fakes({ refused: "" }), request(BODY))).status).toBe(200);
    expect((await call(fakes({ refused: " , " }), request(BODY))).status).toBe(200);
  });
});

describe("rate limits", () => {
  test("GLOBAL then PER_IP, with the right keys", async () => {
    const f = fakes();
    await call(f, request(BODY));
    expect(f.limitCalls).toEqual([
      { binding: "GLOBAL", key: "global" },
      { binding: "PER_IP", key: "192.0.2.10" },
    ]);
  });
  test("global limit is 429 and PER_IP is not asked", async () => {
    const f = fakes({ global: false });
    const r = await call(f, request(BODY));
    expect(r.status).toBe(429);
    expect(r.body).toEqual({ error: "rate_limited" });
    expect(f.limitCalls.map((c) => c.binding)).toEqual(["GLOBAL"]);
    expect(f.aiCalls.length).toBe(0);
  });
  test("per-IP limit is 429", async () => {
    const f = fakes({ perIp: false });
    const r = await call(f, request(BODY));
    expect(r.status).toBe(429);
    expect(f.aiCalls.length).toBe(0);
  });
  test("a limiter that throws fails closed", async () => {
    const f = fakes();
    f.env.PER_IP = {
      async limit() {
        throw new Error("down");
      },
    };
    const r = await call(f, request(BODY));
    expect(r.status).toBe(429);
  });
  test("the IP never appears in a response", async () => {
    for (const opts of [{}, { perIp: false }, { aiThrows: true }]) {
      const r = await call(fakes(opts), request(BODY));
      expect(JSON.stringify(r.body)).not.toContain("192.0.2.10");
      for (const [, v] of r.res.headers) expect(v).not.toContain("192.0.2.10");
    }
  });
});

describe("headers", () => {
  test("every response has no-store and JSON, and no CORS", async () => {
    const cases = [
      request(BODY),
      request(BODY, { headers: { "hasala-client": null } }),
      request(BODY, { path: "/nope" }),
      request(BODY, { method: "PUT" }),
      request(null, { raw: JSON.stringify({ ...BODY, subject: "x".repeat(9000) }) }),
    ];
    const envs = [fakes(), fakes({ refused: "ios/1.4.0" }), fakes({ global: false }), fakes({ aiThrows: true }), fakes({ answer: {} })];
    for (const req of cases) {
      const r = await call(fakes(), req);
      expect(r.res.headers.get("cache-control")).toBe("no-store");
      expect(r.res.headers.get("content-type")).toBe("application/json");
      for (const [k] of r.res.headers) expect(k.startsWith("access-control-")).toBe(false);
    }
    for (const f of envs) {
      const r = await call(f, request(BODY));
      expect(r.res.headers.get("cache-control")).toBe("no-store");
      expect(r.res.headers.get("content-type")).toBe("application/json");
      for (const [k] of r.res.headers) expect(k.startsWith("access-control-")).toBe(false);
    }
  });
});
