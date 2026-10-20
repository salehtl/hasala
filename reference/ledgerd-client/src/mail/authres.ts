/**
 * Gmail's own Authentication-Results, read as the trust primitive for the
 * mailbox lane (spec D4).
 *
 * # Why this is sound HERE and forbidden on the SMTP lane
 *
 * `internal/origin` never reads Authentication-Results: on SMTP-received mail
 * any hop that can open a TCP connection can forge one claiming dkim=pass for a
 * bank (see internal/origin/dkim.go's package comment). This parser is the
 * exact opposite situation and NOTHING here weakens that rule — it runs ONLY on
 * bytes the client fetched from Gmail's own store over an authenticated API
 * (TLS + OAuth), where RFC 8601 §5 REQUIRES the receiving ADMD to delete
 * incoming A-R headers claiming its own authserv-id. The design does not assume
 * Gmail conforms; the pre-ship conformance probe (Task 11) proves it, and the
 * rule below is hardened to fail closed if it ever stops.
 *
 * The Go side must NEVER grow an A-R reader. That is pinned by a source-scan
 * fence test in internal/origin (authres_absent_test.go).
 *
 * # The rule (spec D4, hardened)
 *
 * Trust a verdict ONLY when:
 *   - exactly one Authentication-Results header has authserv-id == mx.google.com,
 *   - it precedes every other Authentication-Results header, AND
 *   - it reports dkim=pass with a d= domain aligned with the one From domain.
 *
 * Everything else is untrusted with a specific reason:
 *   - no_ar       — no mx.google.com A-R present (drafts, Gmail's POP importer,
 *                   API-inserted mail that never crossed Gmail's inbound MX, or
 *                   only foreign-authserv-id A-Rs).
 *   - multiple_ar — more than one mx.google.com A-R.
 *   - not_topmost — a foreign-authserv-id A-R precedes the mx.google.com one.
 *   - fail        — the mx.google.com A-R does not report a passing verdict.
 *   - parse_error — the header block could not be read (malformed, over-bounds).
 *
 * Fail-closed is the whole posture: any ambiguity is untrusted, never a wrong
 * trust and never a dropped message (an untrusted verdict routes the message to
 * needs-review, not to the void).
 *
 * # Bounds
 *
 * Every input here is attacker-writable (a genuine bank message a user forwards,
 * or anything an attacker who guessed the burner address mailed in). The raw
 * header size and the fold depth of one field are bounded before any detailed
 * parsing, mirroring how internal/origin/dkim.go bounds its folded-header work.
 * Over-bounds input is parse_error, never an exception and never an unbounded
 * scan.
 *
 * # Outlook.com
 *
 * `outlookVerdict` is the same posture for a personal Microsoft mailbox, whose
 * own A-R has no authserv-id. It shares the reading above (bounds, unfolding,
 * comments, quoting) and has its own rule; see analyzeOutlook. `analyzeFor`
 * picks the rule by provider id ("gmail" | "outlook").
 */

/** The one authserv-id whose verdict this lane trusts. Bare match only. */
const GMAIL_AUTHSERV_ID = "mx.google.com";

/**
 * maxRawBytes bounds the whole header block before it is walked. Every A-R
 * value is a substring of it, so this single cap also bounds every downstream
 * scan. 256 KiB clears real mail (the SMTP lane's largest fixture header block
 * is ~12.5 KB) by an order of magnitude while refusing a block built to be
 * expensive to unfold. Measured in UTF-16 code units, which is a conservative
 * proxy for bytes (never smaller for the ASCII these headers are).
 */
const maxRawBytes = 256 * 1024;

/**
 * maxFieldLines bounds the fold depth of one header field. Unfolding appends
 * each continuation line to the field value, so an unbounded fold is unbounded
 * copying bought with one message; mirrors internal/origin/dkim.go's cap.
 */
const maxFieldLines = 512;

/**
 * The reason codes a verdict can report. `no_eop` is outlookVerdict's only:
 * gmailVerdict never returns it.
 */
export type ArReason =
  | "pass"
  | "no_ar"
  | "multiple_ar"
  | "not_topmost"
  | "fail"
  | "parse_error"
  | "no_eop";

/** The mailbox providers whose own Authentication-Results this module reads. */
export type MailProvider = "gmail" | "outlook";

/** The verdict: trusted iff reason === "pass". */
export type ArVerdict = { trusted: boolean; reason: ArReason };

/** One parsed method=result token with its properties, e.g. dkim=pass header.d=… */
type MethodSpec = {
  method: string; // lowercased, version stripped (dkim/1 → dkim)
  result: string; // lowercased (pass, fail, neutral, none, …)
  props: Map<string, string>; // ptype.property (lowercased) → value
};

/** One parsed Authentication-Results header. */
type ArHeader = {
  authservId: string; // lowercased; empty if unreadable
  methods: MethodSpec[];
  /**
   * Microsoft form: the first segment is a method spec, not an authserv-id
   * (see outlookVerdict). Then `methods` also holds the first segment's spec,
   * and `authservId` is the raw first token (which never equals an id this
   * module trusts, because an RFC 8601 authserv-id cannot contain '=').
   */
  microsoftForm: boolean;
};

/**
 * gmailVerdict returns the trust decision for a message's raw RFC822 headers.
 * It never throws: any malformed input becomes parse_error.
 */
export function gmailVerdict(rawHeaders: string): ArVerdict {
  return analyze(rawHeaders).verdict;
}

/**
 * verifiedDomain returns the domain the trusted mx.google.com verdict vouched
 * for — the dkim d= (header.d) when the verdict passed on DKIM, else the
 * dmarc header.from — for sender-list matching, or null.
 *
 * It returns a domain ONLY when gmailVerdict trusts the message. Sender-list
 * matching happens exclusively on a trusted verdict, so an untrusted message
 * has no verified domain to offer; returning null there keeps the two functions
 * from disagreeing about whether a domain was proven.
 */
export function verifiedDomain(rawHeaders: string, provider: MailProvider = "gmail"): string | null {
  return analyzeFor(rawHeaders, provider).domain;
}

/**
 * outlookVerdict is the Outlook.com twin of gmailVerdict (rule below, from the
 * WP1 decision `docs/decisions/outlook-mailbox.md` §3). It never throws.
 */
export function outlookVerdict(rawHeaders: string): ArVerdict {
  return analyzeOutlook(rawHeaders).verdict;
}

/** The verdict of the given provider's rule. */
export function providerVerdict(rawHeaders: string, provider: MailProvider): ArVerdict {
  return analyzeFor(rawHeaders, provider).verdict;
}

export type Analysis = { verdict: ArVerdict; domain: string | null };

/**
 * analyzeFor is the verdict and the verified domain of one provider's rule,
 * from one reading of the bytes. An unknown provider is untrusted.
 */
export function analyzeFor(rawHeaders: string, provider: MailProvider): Analysis {
  if (provider === "gmail") return analyze(rawHeaders);
  if (provider === "outlook") return analyzeOutlook(rawHeaders);
  return untrusted("parse_error");
}

const untrusted = (reason: ArReason): Analysis => ({
  verdict: { trusted: false, reason },
  domain: null,
});

/**
 * analyze is the single core both public functions call, so the verdict and the
 * verified domain can never be derived from two different readings of the same
 * bytes.
 */
function analyze(rawHeaders: string): Analysis {
  try {
    if (typeof rawHeaders !== "string" || rawHeaders.length === 0) {
      return untrusted("no_ar");
    }
    if (rawHeaders.length > maxRawBytes) {
      return untrusted("parse_error");
    }

    const fields = unfold(rawHeaders);
    if (fields === null) {
      return untrusted("parse_error");
    }

    // Every A-R header in the block, in order. A-R is matched EXACTLY (case
    // insensitively): "ARC-Authentication-Results" and "X-…-Authentication-
    // Results" are different fields and must not count.
    const arValues: string[] = [];
    for (const f of fields) {
      if (fieldNameEquals(f.name, "authentication-results")) {
        arValues.push(f.value);
      }
    }
    if (arValues.length === 0) {
      return untrusted("no_ar");
    }

    const parsed = arValues.map(parseArValue);

    // Which A-Rs are Gmail's own. Bare authserv-id match only.
    const gmailIdx: number[] = [];
    parsed.forEach((ar, i) => {
      if (ar.authservId === GMAIL_AUTHSERV_ID) gmailIdx.push(i);
    });

    if (gmailIdx.length === 0) {
      // A-Rs exist but none is Gmail's — no verdict we may trust exists.
      return untrusted("no_ar");
    }
    if (gmailIdx.length > 1) {
      return untrusted("multiple_ar");
    }

    // Exactly one. It must precede every other A-R header — i.e. be the first
    // A-R in the block. A forged foreign A-R prepended above it fails here.
    const idx = gmailIdx[0]!;
    if (idx !== 0) {
      return untrusted("not_topmost");
    }

    const ar = parsed[idx]!;

    const from = fields.filter((f) => fieldNameEquals(f.name, "from"));
    const fromDom = from.length === 1 ? fromDomain(from[0]!.value) : "";
    const dkimPass = ar.methods.find(
      (m) => m.method === "dkim" && m.result === "pass" && dkimAligned(domainProp(m, "header.d"), fromDom),
    );
    if (!dkimPass) {
      return untrusted("fail");
    }
    const domain = domainProp(dkimPass, "header.d");

    return { verdict: { trusted: true, reason: "pass" }, domain };
  } catch {
    // A parser on the trust path must never crash the fetch cycle.
    return untrusted("parse_error");
  }
}

// --- Outlook.com -----------------------------------------------------------

/**
 * The EOP-only fields that prove a message crossed Exchange Online Protection
 * inbound. Exchange's header firewall removes sender-supplied
 * X-MS-Exchange-Organization-* fields from untrusted mail, and keeps these on
 * delivery (UNVERIFIED for Outlook.com until the WP0 checks C2/C3).
 */
const OUTLOOK_AUTH_AS = "x-ms-exchange-organization-authas";
const OUTLOOK_AUTH_SOURCE = "x-ms-exchange-organization-authsource";
/** The AuthAs values accepted (lower case). Internet mail is Anonymous. */
const OUTLOOK_AUTH_AS_VALUES: readonly string[] = ["anonymous"];
/** AuthSource must be an LDH name under this suffix (lower case). */
const OUTLOOK_AUTH_SOURCE_SUFFIX = ".prod.outlook.com";
/**
 * The results the Microsoft-form A-R must report, method → result. Exactly
 * `pass`: dmarc=bestguesspass and compauth=softpass are not passes. Each method
 * must appear exactly once.
 */
const OUTLOOK_REQUIRED: readonly (readonly [string, string])[] = [
  ["compauth", "pass"],
  ["dmarc", "pass"],
];

/**
 * analyzeOutlook is the Outlook.com trust rule (WP1 decision §3). It reads the
 * header block of the `$value` MIME with the same bounds, unfolding, comment
 * stripping and quoting as the Gmail rule. Outlook.com's own A-R carries no
 * authserv-id ("Microsoft form"), so content cannot tell it from one a sender
 * wrote; position and the EOP-only fields have to. The first step that applies
 * decides:
 *
 *   1. over the bounds or unreadable                       → parse_error
 *   2. no Microsoft-form A-R                               → no_ar
 *   3. more than one Microsoft-form A-R                    → multiple_ar
 *   4. the topmost A-R (any form) is not the Microsoft one → not_topmost
 *   5. not exactly one AuthAs (Anonymous) and exactly one
 *      AuthSource (LDH, under .prod.outlook.com)           → no_eop
 *   6. not exactly one compauth=pass and one dmarc=pass,
 *      with a valid DMARC header.from                      → fail
 *   7. not exactly one From, or its domain ≠ header.from   → fail
 *   8. trusted; the verified domain is the DMARC header.from.
 *
 * SPF and DKIM are parsed but are not trust inputs; ARC is ignored. Each step
 * is one block below, and its constants are above, so tightening or loosening
 * the rule after the WP0 samples is a local change (and a vector).
 *
 * This verdict is fail-closed but rests on premises that real mail has not yet
 * proven (EOP stamps exactly one topmost A-R; $value keeps header order). Until
 * the owner's checks pass, the Outlook lane sends every message to review
 * whatever this returns (`outlookTrustProven`, WP5b).
 */
function analyzeOutlook(rawHeaders: string): Analysis {
  try {
    // 1. Bounds.
    if (typeof rawHeaders !== "string" || rawHeaders.length === 0) {
      return untrusted("no_ar");
    }
    if (rawHeaders.length > maxRawBytes) {
      return untrusted("parse_error");
    }
    const fields = unfold(rawHeaders);
    if (fields === null) {
      return untrusted("parse_error");
    }

    const parsed = fields
      .filter((f) => fieldNameEquals(f.name, "authentication-results"))
      .map((f) => parseArValue(f.value));

    // 2–4. Exactly one Microsoft-form A-R, and it is the topmost A-R.
    const msIdx: number[] = [];
    parsed.forEach((ar, i) => {
      if (ar.microsoftForm) msIdx.push(i);
    });
    if (msIdx.length === 0) {
      return untrusted("no_ar");
    }
    if (msIdx.length > 1) {
      return untrusted("multiple_ar");
    }
    if (msIdx[0] !== 0) {
      return untrusted("not_topmost");
    }
    const ar = parsed[0]!;

    // 5. EOP proof.
    const valuesOf = (name: string): string[] =>
      fields.filter((f) => fieldNameEquals(f.name, name)).map((f) => f.value.trim().toLowerCase());
    const authAs = valuesOf(OUTLOOK_AUTH_AS);
    const authSource = valuesOf(OUTLOOK_AUTH_SOURCE);
    if (
      authAs.length !== 1 ||
      !OUTLOOK_AUTH_AS_VALUES.includes(authAs[0]!) ||
      authSource.length !== 1 ||
      !authSource[0]!.endsWith(OUTLOOK_AUTH_SOURCE_SUFFIX) ||
      !isLdhDomain(authSource[0]!)
    ) {
      return untrusted("no_eop");
    }

    // 6. The verdict: each required method exactly once, with the exact result.
    for (const [method, result] of OUTLOOK_REQUIRED) {
      const specs = ar.methods.filter((m) => m.method === method);
      if (specs.length !== 1 || specs[0]!.result !== result) {
        return untrusted("fail");
      }
    }
    const dmarc = ar.methods.find((m) => m.method === "dmarc")!;
    const domain = domainProp(dmarc, "header.from");
    if (domain === "") {
      return untrusted("fail");
    }

    // 7. From binding: the domain compauth evaluated is the From we will read.
    const from = fields.filter((f) => fieldNameEquals(f.name, "from"));
    if (from.length !== 1 || fromDomain(from[0]!.value) !== domain) {
      return untrusted("fail");
    }

    // 8.
    return { verdict: { trusted: true, reason: "pass" }, domain };
  } catch {
    return untrusted("parse_error");
  }
}

/**
 * fromDomain is the domain of a From value: the part after the last '@', cut
 * at '>', space, tab, CR, LF, '"' or ')', ASCII lower-cased, trailing dots
 * dropped; "" when there is no '@'. It is the Swift lane's
 * `BankDomains.domainOf`, which the sender-trust match downstream uses on the
 * same From.
 */
function dkimAligned(d: string, from: string): boolean {
  if (d === "" || from === "") return false;
  return from === d || from.endsWith("." + d) || (from.includes(".") && d.endsWith("." + from));
}

function fromDomain(value: string): string {
  const at = value.lastIndexOf("@");
  if (at < 0) return "";
  let out = "";
  for (let i = at + 1; i < value.length; i++) {
    const c = value[i]!;
    if (c === ">" || c === " " || c === "\t" || c === "\r" || c === "\n" || c === '"' || c === ")") break;
    out += c >= "A" && c <= "Z" ? c.toLowerCase() : c;
  }
  while (out.endsWith(".")) out = out.slice(0, -1);
  return out;
}

/** A single header field after unfolding. */
type Field = { name: string; value: string };

/**
 * unfold splits a raw RFC822 header block into fields, joining RFC 5322 folded
 * continuation lines (those beginning with a space or tab). It stops at the
 * first blank line (end of the header block); anything after is the body and is
 * ignored. Returns null if a field folds deeper than maxFieldLines.
 */
function unfold(raw: string): Field[] | null {
  const lines = raw.split(/\r\n|\r|\n/);
  const fields: Field[] = [];
  let cur: { name: string; value: string; foldLines: number } | null = null;

  const flush = () => {
    if (cur) {
      fields.push({ name: cur.name, value: cur.value });
      cur = null;
    }
  };

  for (const line of lines) {
    if (line === "") {
      // Blank line terminates the header block.
      break;
    }
    if (line[0] === " " || line[0] === "\t") {
      // Continuation of the current field. A continuation with no field to
      // continue is malformed leading whitespace; drop it rather than throw.
      if (cur) {
        cur.foldLines++;
        if (cur.foldLines > maxFieldLines) return null;
        // Unfolding replaces CRLF + WSP with a single space (RFC 5322 §2.2.3),
        // which also keeps a token from being glued across the fold.
        cur.value += " " + line.trimStart();
      }
      continue;
    }
    const colon = line.indexOf(":");
    if (colon < 0) {
      // A non-continuation line with no colon is not a header field. Ignore it
      // rather than throw; a Gmail-fetched block will not contain one.
      flush();
      continue;
    }
    flush();
    cur = {
      name: line.slice(0, colon),
      value: line.slice(colon + 1).trimStart(),
      foldLines: 0,
    };
  }
  flush();
  return fields;
}

/** Case-insensitive, whitespace-trimmed field-name equality. */
function fieldNameEquals(name: string, want: string): boolean {
  return name.trim().toLowerCase() === want;
}

/**
 * parseArValue reads one Authentication-Results value into its authserv-id and
 * method specs, per RFC 8601 §2.2. It is total: an unreadable value yields an
 * empty authserv-id (which cannot match GMAIL_AUTHSERV_ID) and whatever methods
 * it could recover.
 */
function parseArValue(value: string): ArHeader {
  // Comments (CFWS) can appear anywhere and may nest and may contain ';' or
  // '('; strip them first so neither the resinfo split nor tokenisation trips
  // over their contents.
  const clean = stripComments(value);

  // resinfo entries are separated by ';' (RFC 8601 §2.2). The first segment is
  // the authserv-id (and an optional version); each later segment is a
  // methodspec plus its propspecs.
  const segments = splitTop(clean, ";");

  const first = segments.length > 0 ? segments[0]! : "";
  const idToken = tokenize(first)[0] ?? "";
  const authservId = unquote(idToken).toLowerCase();

  // Microsoft's form has no authserv-id: its first token is already a
  // method=result (e.g. "spf=pass"). An authserv-id is a value token, which
  // cannot contain '=', so the two forms cannot be confused. In this form
  // every segment, the first included, is a method spec.
  const microsoftForm = idToken.includes("=");

  const methods: MethodSpec[] = [];
  for (let i = microsoftForm ? 0 : 1; i < segments.length; i++) {
    const toks = tokenize(segments[i]!);
    if (toks.length === 0) continue;
    const spec = parseMethodSpec(toks);
    if (spec) methods.push(spec);
  }

  return { authservId, methods, microsoftForm };
}

/** parseMethodSpec turns [method=result, ptype.prop=value, …] into a MethodSpec. */
function parseMethodSpec(tokens: string[]): MethodSpec | null {
  const head = splitKV(tokens[0]!);
  if (!head) return null;
  // method may carry a version: "dkim/1". Only the method name matters here.
  const method = head.key.split("/")[0]!.trim().toLowerCase();
  if (method === "") return null;
  const result = unquote(head.value).trim().toLowerCase();
  const props = new Map<string, string>();
  for (let i = 1; i < tokens.length; i++) {
    const kv = splitKV(tokens[i]!);
    if (!kv) continue;
    props.set(kv.key.trim().toLowerCase(), unquote(kv.value));
  }
  return { method, result, props };
}

/** splitKV splits a token on its FIRST '='. Returns null if there is none. */
function splitKV(token: string): { key: string; value: string } | null {
  const eq = token.indexOf("=");
  if (eq < 0) return null;
  return { key: token.slice(0, eq), value: token.slice(eq + 1) };
}

/**
 * domainProp reads a property expected to hold a domain (header.d, header.from),
 * strips a leading '@' (header.i-style local parts never reach here, but
 * header.from can be a full address in the wild), lowercases it, and returns
 * "" if the result is not a plausible bare domain. Case folding matters because
 * DNS names are case-insensitive and this value is later compared against a
 * sender list.
 */
function domainProp(spec: MethodSpec, key: string): string {
  let v = spec.props.get(key);
  if (v === undefined) return "";
  v = v.trim();
  // header.from / header.d can carry an addr-spec; keep the domain.
  const at = v.lastIndexOf("@");
  if (at >= 0) v = v.slice(at + 1);
  v = v.toLowerCase();
  // A bare domain: labels of unreserved chars separated by dots, at least one
  // dot. Anything else (a stray port, empty, whitespace) is not usable.
  if (!isLdhDomain(v)) {
    return "";
  }
  return v;
}

/** A lower-case LDH domain with at least two labels. */
function isLdhDomain(v: string): boolean {
  return /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/.test(v);
}

/**
 * stripComments removes RFC 5322 CFWS comments — parenthesised, nestable, with
 * '\' quoting the next char — replacing each top-level comment with a single
 * space so adjacent tokens stay separated. Quoted strings are passed through
 * verbatim so a '(' or ';' inside quotes is not mistaken for structure.
 */
function stripComments(v: string): string {
  let out = "";
  let depth = 0;
  let inQuote = false;
  for (let i = 0; i < v.length; i++) {
    const c = v[i]!;
    if (inQuote) {
      if (c === "\\") {
        out += c + (v[i + 1] ?? "");
        i++;
        continue;
      }
      if (c === '"') inQuote = false;
      out += c;
      continue;
    }
    if (depth > 0) {
      if (c === "\\") {
        i++; // skip the escaped char inside the comment
        continue;
      }
      if (c === "(") depth++;
      else if (c === ")") depth--;
      continue; // drop comment content
    }
    if (c === "(") {
      depth++;
      out += " ";
      continue;
    }
    if (c === '"') {
      inQuote = true;
      out += c;
      continue;
    }
    out += c;
  }
  return out;
}

/**
 * splitTop splits on a separator char at the TOP level only — not inside a
 * quoted string. Comments are already gone by the time this runs.
 */
function splitTop(v: string, sep: string): string[] {
  const parts: string[] = [];
  let cur = "";
  let inQuote = false;
  for (let i = 0; i < v.length; i++) {
    const c = v[i]!;
    if (inQuote) {
      if (c === "\\") {
        cur += c + (v[i + 1] ?? "");
        i++;
        continue;
      }
      if (c === '"') inQuote = false;
      cur += c;
      continue;
    }
    if (c === '"') {
      inQuote = true;
      cur += c;
      continue;
    }
    if (c === sep) {
      parts.push(cur);
      cur = "";
      continue;
    }
    cur += c;
  }
  parts.push(cur);
  return parts;
}

/**
 * tokenize splits a resinfo segment into whitespace-separated tokens, keeping
 * quoted strings (including any whitespace inside them) intact.
 */
function tokenize(seg: string): string[] {
  const out: string[] = [];
  let cur = "";
  let inQuote = false;
  const push = () => {
    if (cur !== "") {
      out.push(cur);
      cur = "";
    }
  };
  for (let i = 0; i < seg.length; i++) {
    const c = seg[i]!;
    if (inQuote) {
      if (c === "\\") {
        cur += c + (seg[i + 1] ?? "");
        i++;
        continue;
      }
      if (c === '"') inQuote = false;
      cur += c;
      continue;
    }
    if (c === '"') {
      inQuote = true;
      cur += c;
      continue;
    }
    if (c === " " || c === "\t") {
      push();
      continue;
    }
    cur += c;
  }
  push();
  return out;
}

/** unquote strips one layer of surrounding double quotes and unescapes '\x'. */
function unquote(s: string): string {
  s = s.trim();
  if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') {
    const inner = s.slice(1, -1);
    let out = "";
    for (let i = 0; i < inner.length; i++) {
      if (inner[i] === "\\" && i + 1 < inner.length) {
        out += inner[i + 1];
        i++;
      } else {
        out += inner[i];
      }
    }
    return out;
  }
  return s;
}
