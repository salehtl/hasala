// Gmail's own Authentication-Results, read as the trust primitive of the Gmail lane (spec 04
// §7.6; spec 01's trust rule, security inventory G3): a port of
// reference/ledgerd-client/src/mail/authres.ts.
//
// # Why this is sound here
//
// It runs ONLY on headers the phone fetched from Gmail's own store over an authenticated API
// (TLS + OAuth), where RFC 8601 §5 requires the receiving ADMD to delete incoming A-R headers
// claiming its own authserv-id. The rule does not assume Gmail conforms; it fails closed.
// The server never reads Authentication-Results (it never sees mail at all).
//
// # The rule
//
// Trust a verdict ONLY when exactly one Authentication-Results header has authserv-id
// `mx.google.com`, it precedes every other Authentication-Results header, and it reports
// `dkim=pass` with a `header.d` domain or `dmarc=pass` (whose domain is then `header.from`).
// `spf` results are parsed like any other method but never trusted: SPF vouches for the
// envelope sender, not the From domain a bank's template is keyed on. Everything else is
// untrusted with a reason, and an untrusted message goes to review, never to the void.
//
// # Fidelity
//
// The verdict and the domain are the TypeScript twin's on every input: the same splitting,
// the same JavaScript `trim` set (including U+00A0 and U+FEFF) and JavaScript's full
// lower-case mapping, the same 256 KiB bound measured in UTF-16 code units. CoreMailTests pins
// the non-ASCII whitespace and case-folding behaviour explicitly rather than inheriting it.
import HasalaText

public enum AuthResults {
  /// The one authserv-id whose verdict the lane trusts. Bare match only.
  public static let gmailAuthservID = "mx.google.com"
  /// Bounds the header block (UTF-16 code units, as in the twin) before it is walked.
  public static let maxRawUnits = 256 * 1024
  /// Bounds the fold depth of one header field.
  public static let maxFieldLines = 512

  public enum Reason: String, Sendable, Equatable {
    case pass
    /// No `mx.google.com` A-R (drafts, POP imports, API-inserted mail, foreign A-Rs only).
    case noAR = "no_ar"
    /// More than one `mx.google.com` A-R.
    case multipleAR = "multiple_ar"
    /// A foreign A-R precedes the `mx.google.com` one.
    case notTopmost = "not_topmost"
    /// The `mx.google.com` A-R reports no usable passing verdict.
    case fail
    /// The header block could not be read (over the bounds).
    case parseError = "parse_error"
  }

  public struct Verdict: Sendable, Equatable {
    public let trusted: Bool
    public let reason: Reason
  }

  /// The verdict and, only when trusted, the verified domain, from ONE reading of the bytes.
  public struct Analysis: Sendable, Equatable {
    public let verdict: Verdict
    /// The DKIM `header.d` of the passing verdict, else the DMARC `header.from`; lower case.
    public let domain: String?
  }

  /// The trust decision for a message's raw header block. Never throws.
  public static func gmailVerdict(_ rawHeaders: String) -> Verdict { analyze(rawHeaders).verdict }

  /// The domain the trusted verdict vouched for, or nil (always nil when untrusted).
  public static func verifiedDomain(_ rawHeaders: String) -> String? { analyze(rawHeaders).domain }

  static func untrusted(_ r: Reason) -> Analysis { Analysis(verdict: Verdict(trusted: false, reason: r), domain: nil) }

  public static func analyze(_ rawHeaders: String) -> Analysis {
    if rawHeaders.isEmpty { return untrusted(.noAR) }
    if rawHeaders.utf16.count > maxRawUnits { return untrusted(.parseError) }
    guard let fields = unfold(Array(rawHeaders.unicodeScalars)) else { return untrusted(.parseError) }

    // Every A-R in the block, in order. The name is matched exactly (after trim, case-
    // insensitively): ARC-Authentication-Results is a different field.
    let want = Array("authentication-results".unicodeScalars)
    let arValues = fields.filter { jsLower(jsTrim($0.name)) == want }.map(\.value)
    if arValues.isEmpty { return untrusted(.noAR) }

    let parsed = arValues.map(parseARValue)
    let gmail = parsed.indices.filter { parsed[$0].authservID.utf8.elementsEqual(gmailAuthservID.utf8) }
    if gmail.isEmpty { return untrusted(.noAR) }
    if gmail.count > 1 { return untrusted(.multipleAR) }
    guard gmail[0] == 0 else { return untrusted(.notTopmost) }

    let ar = parsed[0]
    let dkimPass = ar.methods.first { same($0.method, "dkim") && same($0.result, "pass") && !domainProp($0, "header.d").isEmpty }
    let dmarcPass = ar.methods.first { same($0.method, "dmarc") && same($0.result, "pass") }
    if dkimPass == nil && dmarcPass == nil { return untrusted(.fail) }

    var domain = dkimPass.map { domainProp($0, "header.d") } ?? ""
    if domain.isEmpty, let dmarcPass { domain = domainProp(dmarcPass, "header.from") }
    // dmarc=pass with no usable header.from is a pass with nothing to match a sender list
    // against: fail closed rather than hand the caller a nil to special-case.
    if domain.isEmpty { return untrusted(.fail) }
    return Analysis(verdict: Verdict(trusted: true, reason: .pass), domain: domain)
  }

  // MARK: - Parsing

  typealias Scalars = [Unicode.Scalar]

  struct Field {
    let name: Scalars
    let value: Scalars
  }

  struct MethodSpec {
    /// Lower-cased, version stripped (`dkim/1` is `dkim`). ASCII text compares by bytes here.
    let method: String
    let result: String
    /// Property (lower-cased `ptype.property`) to value, in order; the last one of a name wins.
    let props: [(key: String, value: String)]
  }

  struct ARHeader {
    let authservID: String
    let methods: [MethodSpec]
  }

  /// Splits a header block into fields (`split(/\r\n|\r|\n/)`), joining folded continuation
  /// lines with one space; stops at the first blank line. Nil when a field folds deeper than
  /// `maxFieldLines`.
  static func unfold(_ raw: Scalars) -> [Field]? {
    var lines: [ArraySlice<Unicode.Scalar>] = []
    var start = 0
    var i = 0
    while i < raw.count {
      let c = raw[i]
      if c == "\r" || c == "\n" {
        lines.append(raw[start..<i])
        i += (c == "\r" && i + 1 < raw.count && raw[i + 1] == "\n") ? 2 : 1
        start = i
        continue
      }
      i += 1
    }
    lines.append(raw[start..<raw.count])

    var fields: [Field] = []
    var curName: Scalars? = nil
    var curValue: Scalars = []
    var foldLines = 0
    func flush() {
      if let n = curName { fields.append(Field(name: n, value: curValue)) }
      curName = nil
    }
    for line in lines {
      if line.isEmpty { break }  // the blank line ends the header block
      if line.first == " " || line.first == "\t" {
        // A continuation with no field to continue is dropped.
        if curName != nil {
          foldLines += 1
          if foldLines > maxFieldLines { return nil }
          curValue.append(" ")
          curValue.append(contentsOf: jsTrimStart(line))
        }
        continue
      }
      guard let colon = line.firstIndex(of: ":") else {
        flush()  // not a header field; ignored
        continue
      }
      flush()
      curName = Array(line[line.startIndex..<colon])
      curValue = Array(jsTrimStart(line[(colon + 1)...]))
      foldLines = 0
    }
    flush()
    return fields
  }

  /// One A-R value: its authserv-id and method specs (RFC 8601 §2.2). Total: an unreadable
  /// value yields an empty authserv-id, which never matches.
  static func parseARValue(_ value: Scalars) -> ARHeader {
    let segments = splitTop(stripComments(value), ";")
    let idToken = tokenize(segments.first ?? []).first ?? []
    let authservID = string(jsLower(unquote(idToken)))
    var methods: [MethodSpec] = []
    for seg in segments.dropFirst() {
      let toks = tokenize(seg)
      if toks.isEmpty { continue }
      if let spec = parseMethodSpec(toks) { methods.append(spec) }
    }
    return ARHeader(authservID: authservID, methods: methods)
  }

  static func parseMethodSpec(_ tokens: [Scalars]) -> MethodSpec? {
    guard let head = splitKV(tokens[0]) else { return nil }
    let name = head.key.split(separator: "/", omittingEmptySubsequences: false).first.map(Array.init) ?? []
    let method = string(jsLower(jsTrim(name)))
    if method.isEmpty { return nil }
    let result = string(jsLower(jsTrim(unquote(head.value))))
    var props: [(key: String, value: String)] = []
    for t in tokens.dropFirst() {
      guard let kv = splitKV(t) else { continue }
      props.append((string(jsLower(jsTrim(kv.key))), string(unquote(kv.value))))
    }
    return MethodSpec(method: method, result: result, props: props)
  }

  /// Splits on the FIRST `=`.
  static func splitKV(_ token: Scalars) -> (key: Scalars, value: Scalars)? {
    guard let eq = token.firstIndex(of: "=") else { return nil }
    return (Array(token[0..<eq]), Array(token[(eq + 1)...]))
  }

  /// A property expected to hold a domain: trimmed, everything through the last `@` dropped,
  /// lower-cased, and then it must be a plain LDH domain with at least one dot, or it is "".
  static func domainProp(_ spec: MethodSpec, _ key: String) -> String {
    guard let raw = spec.props.last(where: { $0.key.utf8.elementsEqual(key.utf8) })?.value else { return "" }
    var v = Array(jsTrim(Array(raw.unicodeScalars)))
    if let at = v.lastIndex(of: "@") { v = Array(v[(at + 1)...]) }
    let lower = jsLower(v)
    return isLDHDomain(lower) ? string(lower) : ""
  }

  /// `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`
  static func isLDHDomain(_ v: Scalars) -> Bool {
    func alnum(_ c: Unicode.Scalar) -> Bool { (c.value >= 0x61 && c.value <= 0x7a) || (c.value >= 0x30 && c.value <= 0x39) }
    let labels = v.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for l in labels {
      guard let f = l.first, let last = l.last, l.count <= 63, alnum(f), alnum(last) else { return false }
      guard l.allSatisfy({ alnum($0) || $0 == "-" }) else { return false }
    }
    return true
  }

  /// Removes RFC 5322 comments (nestable, `\` quoting), each top-level comment becoming one
  /// space; quoted strings pass through verbatim.
  static func stripComments(_ v: Scalars) -> Scalars {
    var out: Scalars = []
    var depth = 0
    var inQuote = false
    var i = 0
    while i < v.count {
      let c = v[i]
      if inQuote {
        if c == "\\" {
          out.append(c)
          if i + 1 < v.count { out.append(v[i + 1]) }
          i += 2
          continue
        }
        if c == "\"" { inQuote = false }
        out.append(c)
      } else if depth > 0 {
        if c == "\\" {
          i += 2  // the escaped character is part of the comment
          continue
        }
        if c == "(" {
          depth += 1
        } else if c == ")" {
          depth -= 1
        }
      } else if c == "(" {
        depth += 1
        out.append(" ")
      } else {
        if c == "\"" { inQuote = true }
        out.append(c)
      }
      i += 1
    }
    return out
  }

  /// Splits on `sep` at the top level only (not inside a quoted string).
  static func splitTop(_ v: Scalars, _ sep: Unicode.Scalar) -> [Scalars] {
    var parts: [Scalars] = []
    var cur: Scalars = []
    var inQuote = false
    var i = 0
    while i < v.count {
      let c = v[i]
      if inQuote {
        if c == "\\" {
          cur.append(c)
          if i + 1 < v.count { cur.append(v[i + 1]) }
          i += 2
          continue
        }
        if c == "\"" { inQuote = false }
        cur.append(c)
      } else if c == "\"" {
        inQuote = true
        cur.append(c)
      } else if c == sep {
        parts.append(cur)
        cur = []
      } else {
        cur.append(c)
      }
      i += 1
    }
    parts.append(cur)
    return parts
  }

  /// Whitespace-separated (space, tab) tokens, quoted strings kept whole.
  static func tokenize(_ seg: Scalars) -> [Scalars] {
    var out: [Scalars] = []
    var cur: Scalars = []
    var inQuote = false
    var i = 0
    while i < seg.count {
      let c = seg[i]
      if inQuote {
        if c == "\\" {
          cur.append(c)
          if i + 1 < seg.count { cur.append(seg[i + 1]) }
          i += 2
          continue
        }
        if c == "\"" { inQuote = false }
        cur.append(c)
      } else if c == "\"" {
        inQuote = true
        cur.append(c)
      } else if c == " " || c == "\t" {
        if !cur.isEmpty { out.append(cur) }
        cur = []
      } else {
        cur.append(c)
      }
      i += 1
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }

  /// Trims, then strips one layer of surrounding double quotes and unescapes `\x`.
  static func unquote(_ s: Scalars) -> Scalars {
    let t = Array(jsTrim(s))
    guard t.count >= 2, t.first == "\"", t.last == "\"" else { return t }
    let inner = t[1..<(t.count - 1)]
    var out: Scalars = []
    var i = inner.startIndex
    while i < inner.endIndex {
      if inner[i] == "\\" && i + 1 < inner.endIndex {
        out.append(inner[i + 1])
        i += 2
      } else {
        out.append(inner[i])
        i += 1
      }
    }
    return out
  }

  // MARK: - JavaScript string semantics

  /// `String.prototype.trim`.
  static func jsTrim(_ s: some Collection<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
    let a = Array(s)
    var lo = 0
    var hi = a.count
    while lo < hi, ScalarSet.jsTrim.contains(a[lo]) { lo += 1 }
    while hi > lo, ScalarSet.jsTrim.contains(a[hi - 1]) { hi -= 1 }
    return a[lo..<hi]
  }

  /// `String.prototype.trimStart`.
  static func jsTrimStart(_ s: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
    var lo = s.startIndex
    while lo < s.endIndex, ScalarSet.jsTrim.contains(s[lo]) { lo += 1 }
    return s[lo...]
  }

  /// `String.prototype.toLowerCase`, scalar by scalar (full mapping: U+212A KELVIN SIGN becomes
  /// `k`, U+0130 becomes `i` U+0307), as the twin reads these values.
  static func jsLower(_ s: some Collection<Unicode.Scalar>) -> Scalars {
    var out: Scalars = []
    out.reserveCapacity(s.count)
    for c in s {
      if c.isASCII {
        out.append(c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(UInt8(c.value + 0x20)) : c)
      } else {
        out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return out
  }

  /// Byte equality: `String ==` is canonical equivalence, never the comparison here.
  static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

  static func string(_ s: some Sequence<Unicode.Scalar>) -> String {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s)
    return String(v)
  }
}
