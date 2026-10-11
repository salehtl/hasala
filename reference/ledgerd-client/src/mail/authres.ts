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
 *   - it reports dkim=pass (with a d= domain) OR dmarc=pass.
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

/** The reason codes gmailVerdict can report. */
export type ArReason =
  | "pass"
  | "no_ar"
  | "multiple_ar"
  | "not_topmost"
  | "fail"
  | "parse_error";

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
export function verifiedDomain(rawHeaders: string): string | null {
  return analyze(rawHeaders).domain;
}

type Analysis = { verdict: ArVerdict; domain: string | null };

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

    // dkim=pass with a d= domain, OR dmarc=pass.
    const dkimPass = ar.methods.find(
      (m) => m.method === "dkim" && m.result === "pass" && !!domainProp(m, "header.d"),
    );
    const dmarcPass = ar.methods.find((m) => m.method === "dmarc" && m.result === "pass");

    if (!dkimPass && !dmarcPass) {
      return untrusted("fail");
    }

    const domain =
      (dkimPass && domainProp(dkimPass, "header.d")) ||
      (dmarcPass && domainProp(dmarcPass, "header.from")) ||
      null;

    // dmarc=pass with no header.from is still a pass per the rule, but then
    // there is no domain to match a sender list against. A trusted verdict with
    // no domain is unusable downstream, so fail closed rather than hand Task 12
    // a null it would have to special-case.
    if (domain === null) {
      return untrusted("fail");
    }

    return { verdict: { trusted: true, reason: "pass" }, domain };
  } catch {
    // A parser on the trust path must never crash the fetch cycle.
    return untrusted("parse_error");
  }
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

  const methods: MethodSpec[] = [];
  for (let i = 1; i < segments.length; i++) {
    const toks = tokenize(segments[i]!);
    if (toks.length === 0) continue;
    const spec = parseMethodSpec(toks);
    if (spec) methods.push(spec);
  }

  return { authservId, methods };
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
  if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/.test(v)) {
    return "";
  }
  return v;
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
