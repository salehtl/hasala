import worker, { type Env } from "../src/index";

export const OK_ANSWER = {
  model: "clef",
  answers: {
    category: {
      type: "choice",
      choice: "dining",
      probabilities: { groceries: 0.0095, dining: 0.9725, unknown: 0.012 },
      confidence: 0.928,
    },
  },
  usage: { prompt_tokens: 10, completion_tokens: 1 },
};

export const BODY = {
  subject: "CAFE EXAMPLE JBR",
  categories: [
    { id: "groceries", name: "Groceries", hint: "supermarkets and grocery stores" },
    { id: "dining", name: "Dining", hint: null },
  ],
};

export interface Fakes {
  env: Env;
  aiCalls: { model: string; input: unknown }[];
  limitCalls: { binding: string; key: string }[];
}

export function fakes(
  opts: {
    answer?: unknown;
    aiThrows?: boolean;
    perIp?: boolean;
    global?: boolean;
    refused?: string;
  } = {},
): Fakes {
  const aiCalls: Fakes["aiCalls"] = [];
  const limitCalls: Fakes["limitCalls"] = [];
  const env: Env = {
    AI: {
      async run(model, input) {
        aiCalls.push({ model, input });
        if (opts.aiThrows) throw new Error("model down");
        return opts.answer === undefined ? OK_ANSWER : opts.answer;
      },
    },
    PER_IP: {
      async limit({ key }) {
        limitCalls.push({ binding: "PER_IP", key });
        return { success: opts.perIp ?? true };
      },
    },
    GLOBAL: {
      async limit({ key }) {
        limitCalls.push({ binding: "GLOBAL", key });
        return { success: opts.global ?? true };
      },
    },
    REFUSED_CLIENTS: opts.refused ?? "",
  };
  return { env, aiCalls, limitCalls };
}

export function request(
  body: unknown,
  opts: { headers?: Record<string, string | null>; method?: string; path?: string; raw?: string } = {},
): Request {
  const headers: Record<string, string> = {
    "hasala-client": "ios/1.4.0",
    "content-type": "application/json",
    "cf-connecting-ip": "192.0.2.10",
  };
  for (const [k, v] of Object.entries(opts.headers ?? {})) {
    if (v === null) delete headers[k];
    else headers[k] = v;
  }
  const method = opts.method ?? "POST";
  const init: RequestInit = { method, headers };
  if (method !== "GET" && method !== "HEAD") init.body = opts.raw ?? JSON.stringify(body);
  return new Request(`https://assist.hasala.app${opts.path ?? "/v1/category"}`, init);
}

export async function call(f: Fakes, req: Request): Promise<{ status: number; body: any; res: Response }> {
  const res = await worker.fetch(req, f.env);
  const text = await res.text();
  return { status: res.status, body: JSON.parse(text), res };
}
