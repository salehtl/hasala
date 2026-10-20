export const MODEL = "@cf/cloudflare/clef";
export const TAG = "cf-clef/1";
export const MAX_BODY_BYTES = 8192;
export const UNKNOWN = "unknown";
export const UNKNOWN_CRITERION = "the name alone does not say what kind of business this is";

const CLIENT_RE = /^ios\/[0-9]{1,4}(\.[0-9]{1,4}){0,3}$/;
const ID_RE = /^[a-z][a-z0-9_]{0,31}$/;
const CONTROL_RE = /[\u0000-\u001f\u007f]/g;
const LONE_SURROGATE_RE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;

export interface Category {
  id: string;
  name: string;
  hint: string | null;
}

export interface Suggestion {
  subject: string;
  categories: Category[];
}

export interface ClefBody {
  model: "clef";
  state: string;
  questions: {
    category: {
      type: "choice";
      instructions: string;
      criteria: Record<string, string>;
    };
  };
}

export interface Answer {
  tag: string;
  choice: string;
  probabilities: Record<string, number>;
}

export function validClient(value: string | null): value is string {
  return value !== null && CLIENT_RE.test(value);
}

export function refusedClients(list: string | undefined): Set<string> {
  return new Set(
    (list ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0),
  );
}

function scalars(s: string): number {
  let n = 0;
  for (const _ of s) n++;
  return n;
}

function clean(s: string): string | null {
  if (LONE_SURROGATE_RE.test(s)) return null;
  return s.replace(CONTROL_RE, "").trim();
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function onlyKeys(o: Record<string, unknown>, required: string[], optional: string[] = []): boolean {
  const allowed = new Set([...required, ...optional]);
  for (const k of Object.keys(o)) if (!allowed.has(k)) return false;
  for (const k of required) if (!Object.hasOwn(o, k)) return false;
  return true;
}

function boundedText(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const s = clean(v);
  if (s === null) return null;
  const n = scalars(s);
  return n >= 1 && n <= max ? s : null;
}

export function parseSuggestion(body: unknown): Suggestion | null {
  if (!isPlainObject(body) || !onlyKeys(body, ["subject", "categories"])) return null;
  const subject = boundedText(body.subject, 128);
  if (subject === null) return null;
  const raw = body.categories;
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 32) return null;
  const seen = new Set<string>();
  const categories: Category[] = [];
  for (const c of raw) {
    if (!isPlainObject(c) || !onlyKeys(c, ["id", "name"], ["hint"])) return null;
    const id = c.id;
    if (typeof id !== "string" || !ID_RE.test(id) || id === UNKNOWN || seen.has(id)) return null;
    seen.add(id);
    const name = boundedText(c.name, 64);
    if (name === null) return null;
    let hint: string | null = null;
    if (c.hint !== undefined && c.hint !== null) {
      hint = boundedText(c.hint, 200);
      if (hint === null) return null;
    }
    categories.push({ id, name, hint });
  }
  return { subject, categories };
}

export function clefBody(s: Suggestion): ClefBody {
  const criteria: Record<string, string> = {};
  for (const c of s.categories) criteria[c.id] = c.hint ?? c.name;
  criteria[UNKNOWN] = UNKNOWN_CRITERION;
  return {
    model: "clef",
    state: `The merchant name on a card payment from a bank in the United Arab Emirates: ${JSON.stringify(s.subject)}`,
    questions: {
      category: {
        type: "choice",
        instructions: "Which spending category does a payment to this merchant belong to?",
        criteria,
      },
    },
  };
}

function categoryAnswer(result: unknown): Record<string, unknown> | null {
  let r: unknown = result;
  for (let depth = 0; depth < 3 && isPlainObject(r); depth++) {
    const answers = r.answers;
    if (isPlainObject(answers) && isPlainObject(answers.category)) return answers.category;
    r = r.result;
  }
  return null;
}

export function mapAnswer(result: unknown, s: Suggestion): Answer | null {
  const category = categoryAnswer(result);
  if (category === null) return null;
  const ids = [...s.categories.map((c) => c.id), UNKNOWN];
  const allowed = new Set(ids);
  const choice = category.choice;
  if (typeof choice !== "string" || !allowed.has(choice)) return null;
  const raw = category.probabilities;
  if (!isPlainObject(raw)) return null;
  const probabilities: Record<string, number> = {};
  for (const id of ids) {
    if (!Object.hasOwn(raw, id)) continue;
    const p = raw[id];
    if (typeof p === "number" && Number.isFinite(p) && p >= 0 && p <= 1) probabilities[id] = p;
  }
  return { tag: TAG, choice, probabilities };
}
