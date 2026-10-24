// The mailbox provider's own Authentication-Results, read as the trust primitive of the mailbox
// lane (spec 04 §7.6; spec 01's trust rule, security inventory G3): a port of
// the ledgerd TypeScript client's src/mail/authres.ts. Gmail's rule is below; Outlook.com's is
// `analyzeOutlook` (the WP1 decision, docs/decisions/outlook-mailbox.md §3). `analyze(_:provider:)`
// picks the rule.
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
// `dkim=pass` with a DKIM domain (`header.d`, else the domain of `header.i`) aligned with the
// domain of the one `From` field, and every `dmarc` spec in it names that domain as `header.from`.
// `spf` and `dmarc` results are parsed like any other method but never trusted: DMARC can pass
// on SPF alone, and SPF vouches for the envelope sender, not the From domain a bank's template
// is keyed on. An A-R that is not readable (see `stripComments`, `parseARValue`) is
// `parse_error`. Everything else is
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
  /// The mailbox provider whose rule decides. The raw values are the provider ids of the wire,
  /// provenance and database (CoreMailbox's `MailProviderID` maps onto these).
  public enum Provider: String, Sendable, Equatable, CaseIterable {
    case gmail, outlook
  }

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
    /// Outlook only: the EOP-only fields do not prove the message crossed EOP inbound.
    case noEOP = "no_eop"
    case notInbox = "not_inbox"
    case unknownSender = "unknown_sender"
    case noDMARCReject = "no_dmarc_reject"

    public var recorded: String {
      switch self {
      case .notInbox, .unknownSender, .noDMARCReject: Reason.fail.rawValue
      default: rawValue
      }
    }
  }

  public struct Verdict: Sendable, Equatable {
    public let trusted: Bool
    public let reason: Reason

    public init(trusted: Bool, reason: Reason) {
      self.trusted = trusted
      self.reason = reason
    }
  }

  /// The verdict and, only when trusted, the verified domain, from ONE reading of the bytes.
  public struct Analysis: Sendable, Equatable {
    public let verdict: Verdict
    /// The DKIM domain of the passing verdict (Gmail), or the DMARC `header.from` (Outlook); lower case.
    public let domain: String?
    public let signature: String?

    public init(verdict: Verdict, domain: String?, signature: String? = nil) {
      self.verdict = verdict
      self.domain = domain
      self.signature = signature
    }
  }

  /// The trust decision for a message's raw header block. Never throws.
  public static func gmailVerdict(_ rawHeaders: String) -> Verdict { analyze(rawHeaders).verdict }

  /// Outlook.com's trust decision for a message's raw header block. Never throws.
  public static func outlookVerdict(_ rawHeaders: String) -> Verdict { analyzeOutlook(rawHeaders).verdict }

  /// The trust decision of `provider`'s rule.
  public static func verdict(_ rawHeaders: String, provider: Provider) -> Verdict {
    analyze(rawHeaders, provider: provider).verdict
  }

  /// The domain the trusted verdict vouched for, or nil (always nil when untrusted).
  public static func verifiedDomain(_ rawHeaders: String, provider: Provider = .gmail) -> String? {
    analyze(rawHeaders, provider: provider).domain
  }

  /// The verdict and verified domain of `provider`'s rule, from one reading of the bytes.
  public static func analyze(_ rawHeaders: String, provider: Provider) -> Analysis {
    switch provider {
    case .gmail: analyze(rawHeaders)
    case .outlook: analyzeOutlook(rawHeaders)
    }
  }

  static func untrusted(_ r: Reason) -> Analysis { Analysis(verdict: Verdict(trusted: false, reason: r), domain: nil) }

  /// Gmail's rule.
  public static func analyze(_ rawHeaders: String) -> Analysis {
    if rawHeaders.isEmpty { return untrusted(.noAR) }
    guard let fields = readFields(rawHeaders) else { return untrusted(.parseError) }

    // Every A-R in the block, in order. The name is matched exactly (after trim, case-
    // insensitively): ARC-Authentication-Results is a different field.
    let arValues = named(fields, "authentication-results").map(\.value)
    if arValues.isEmpty { return untrusted(.noAR) }

    let parsed = arValues.map(parseARValue)
    if parsed.contains(where: { !$0.readable }) { return untrusted(.parseError) }
    let gmail = parsed.indices.filter { parsed[$0].authservID.utf8.elementsEqual(gmailAuthservID.utf8) }
    if gmail.isEmpty { return untrusted(.noAR) }
    if gmail.count > 1 { return untrusted(.multipleAR) }
    guard gmail[0] == 0 else { return untrusted(.notTopmost) }

    let ar = parsed[0]
    let from = named(fields, "from")
    let fromDom = from.count == 1 ? string(fromDomain(from[0].value)) : ""
    guard
      let dkimPass = ar.methods.first(where: {
        same($0.method, "dkim") && same($0.result, "pass") && dkimAligned(dkimDomain($0), fromDom)
      })
    else { return untrusted(.fail) }
    if ar.methods.contains(where: { same($0.method, "dmarc") && !same(domainProp($0, "header.from"), fromDom) }) {
      return untrusted(.fail)
    }
    let domain = dkimDomain(dkimPass)
    let b = dkimPass.props.last { $0.key.utf8.elementsEqual("header.b".utf8) }.map { string(jsTrim(Array($0.value.unicodeScalars))) }
    return Analysis(verdict: Verdict(trusted: true, reason: .pass), domain: domain, signature: (b?.isEmpty ?? true) ? nil : b)
  }

  // MARK: - Outlook.com

  /// The EOP-only fields that prove inbound EOP processing (lower case). Exchange's header
  /// firewall removes sender-supplied `X-MS-Exchange-Organization-*` fields (UNVERIFIED for
  /// Outlook.com until the owner's checks C2/C3).
  static let outlookAuthAs = Array("x-ms-exchange-organization-authas".unicodeScalars)
  static let outlookAuthSource = Array("x-ms-exchange-organization-authsource".unicodeScalars)
  /// The AuthAs values accepted (lower case). Internet mail is Anonymous.
  static let outlookAuthAsValues = [Array("anonymous".unicodeScalars)]
  /// AuthSource must be an LDH name under this suffix (lower case).
  static let outlookAuthSourceSuffix = Array(".prod.outlook.com".unicodeScalars)
  /// The results the Microsoft-form A-R must report, each method exactly once, each result
  /// exactly (`bestguesspass` and `softpass` are not passes).
  static let outlookRequired: [(method: String, result: String)] = [("compauth", "pass"), ("dmarc", "pass")]

  /// Outlook.com's rule. Its own A-R has no authserv-id ("Microsoft form"), so content cannot
  /// tell it from one a sender wrote; position and the EOP-only fields have to. The first step
  /// that applies decides:
  ///
  /// 1. over the bounds or unreadable: `parse_error`;
  /// 2. no Microsoft-form A-R: `no_ar`;
  /// 3. more than one Microsoft-form A-R: `multiple_ar`;
  /// 4. the topmost A-R (any form) is not the Microsoft one: `not_topmost`;
  /// 5. not exactly one AuthAs (Anonymous) and exactly one AuthSource (an LDH name under
  ///    `.prod.outlook.com`): `no_eop`;
  /// 6. not exactly one `compauth=pass` and one `dmarc=pass` with a valid DMARC `header.from`:
  ///    `fail`;
  /// 7. not exactly one `From`, or its domain is not that `header.from`: `fail`;
  /// 8. trusted; the verified domain is the DMARC `header.from`.
  ///
  /// SPF and DKIM are parsed but are not trust inputs; ARC is ignored. Each step is one block
  /// and its constants are above, so tightening or loosening it after the owner's samples is a
  /// local change (and a vector). The rule rests on premises real mail has not yet proven, so
  /// the Outlook lane does not use it: it trusts `analyzeOutlookSender` (the WP1 decision §3a).
  public static func analyzeOutlook(_ rawHeaders: String) -> Analysis {
    // 1. Bounds.
    if rawHeaders.isEmpty { return untrusted(.noAR) }
    guard let fields = readFields(rawHeaders) else { return untrusted(.parseError) }

    let parsed = named(fields, "authentication-results").map { parseARValue($0.value) }
    if parsed.contains(where: { !$0.readable }) { return untrusted(.parseError) }

    // 2–4. Exactly one Microsoft-form A-R, and it is the topmost A-R.
    let ms = parsed.indices.filter { parsed[$0].microsoftForm }
    if ms.isEmpty { return untrusted(.noAR) }
    if ms.count > 1 { return untrusted(.multipleAR) }
    guard ms[0] == 0 else { return untrusted(.notTopmost) }
    let ar = parsed[0]

    // 5. EOP proof.
    let authAs = named(fields, outlookAuthAs).map { jsLower(jsTrim($0.value)) }
    let authSource = named(fields, outlookAuthSource).map { jsLower(jsTrim($0.value)) }
    guard authAs.count == 1, outlookAuthAsValues.contains(authAs[0]),
      authSource.count == 1, authSource[0].count >= outlookAuthSourceSuffix.count,
      Array(authSource[0].suffix(outlookAuthSourceSuffix.count)) == outlookAuthSourceSuffix,
      isLDHDomain(authSource[0])
    else { return untrusted(.noEOP) }

    // 6. The verdict: each required method exactly once, with the exact result.
    for req in outlookRequired {
      let specs = ar.methods.filter { same($0.method, req.method) }
      guard specs.count == 1, same(specs[0].result, req.result) else { return untrusted(.fail) }
    }
    guard let dmarc = ar.methods.first(where: { same($0.method, "dmarc") }) else { return untrusted(.fail) }
    let domain = domainProp(dmarc, "header.from")
    if domain.isEmpty { return untrusted(.fail) }

    // 7. From binding: the domain compauth evaluated is the From the lane will read.
    let from = named(fields, "from")
    guard from.count == 1, same(string(fromDomain(from[0].value)), domain) else { return untrusted(.fail) }

    // 8.
    return Analysis(verdict: Verdict(trusted: true, reason: .pass), domain: domain)
  }

  public static func analyzeOutlookSender(
    _ rawHeaders: String, inInbox: Bool, knownSenders: [String], rejectDomains: [String]
  ) -> Analysis {
    guard let fields = readFields(rawHeaders) else { return untrusted(.parseError) }
    guard inInbox else { return untrusted(.notInbox) }
    let from = named(fields, "from")
    guard from.count == 1, let address = fromAddress(from[0].value),
      knownSenders.contains(where: { same(ASCII.lowercased($0), address) })
    else { return untrusted(.unknownSender) }
    let domain = String(address[address.index(after: address.lastIndex(of: "@")!)...])
    guard rejectDomains.contains(where: { same(ASCII.lowercased($0), domain) }) else { return untrusted(.noDMARCReject) }
    return Analysis(verdict: Verdict(trusted: true, reason: .pass), domain: domain)
  }

  static func fromAddress(_ value: Scalars) -> String? {
    let (clean, readable) = stripComments(value)
    guard readable, let s = stripQuoted(clean), !s.contains(","), !s.contains(";") else { return nil }
    let addr: Scalars
    if let lt = s.firstIndex(of: "<") {
      guard let gt = s.firstIndex(of: ">"), gt > lt, s.filter({ $0 == "<" }).count == 1,
        s.filter({ $0 == ">" }).count == 1, !s[..<lt].contains("@"), jsTrim(s[(gt + 1)...]).isEmpty
      else { return nil }
      addr = Array(jsTrim(s[(lt + 1)..<gt]))
    } else {
      guard !s.contains(">") else { return nil }
      addr = Array(jsTrim(s))
    }
    guard addr.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
      let at = addr.firstIndex(of: "@"), at > 0, addr.filter({ $0 == "@" }).count == 1
    else { return nil }
    let lower = Array(ASCII.lowercased(string(addr)).unicodeScalars)
    guard isLDHDomain(Array(lower[(at + 1)...])) else { return nil }
    return string(lower)
  }

  static func stripQuoted(_ v: Scalars) -> Scalars? {
    var out: Scalars = []
    var inQuote = false
    var i = 0
    while i < v.count {
      let c = v[i]
      if inQuote {
        if c == "\\" {
          i += 2
          continue
        }
        if c == "\"" { inQuote = false }
      } else if c == "\"" {
        inQuote = true
        out.append(" ")
      } else {
        out.append(c)
      }
      i += 1
    }
    return inQuote ? nil : out
  }

  static func dkimAligned(_ d: String, _ from: String) -> Bool {
    if d.isEmpty || from.isEmpty { return false }
    let (d8, f8) = (Array(d.utf8), Array(from.utf8))
    if d8 == f8 { return true }
    func under(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.count > b.count && a.suffix(b.count + 1).elementsEqual([0x2e] + b) }
    return under(f8, d8) || (f8.contains(0x2e) && under(d8, f8))
  }

  /// The domain of the one mailbox of a `From` value, read from its addr-spec with comments
  /// removed: inside the one angle-addr when there is one, after the last `@` outside a quoted
  /// string, spaces and tabs trimmed, ASCII lower-cased, trailing dots dropped. Empty when the
  /// value has an unreadable comment or quote, more than one `<` or `>`, a top-level `,`, no `@`,
  /// or a domain with anything but letters, digits, `.` and `-`.
  static func fromDomain(_ value: Scalars) -> Scalars {
    let (clean, ok) = stripComments(value)
    guard ok else { return [] }
    var lt = -1
    var gt = -1
    var lts = 0
    var gts = 0
    var inQuote = false
    var i = 0
    while i < clean.count {
      let c = clean[i]
      if inQuote {
        if c == "\\" {
          i += 1
        } else if c == "\"" {
          inQuote = false
        }
      } else if c == "\"" {
        inQuote = true
      } else if c == "<" {
        lt = i
        lts += 1
      } else if c == ">" {
        gt = i
        gts += 1
      } else if c == "," {
        return []
      }
      i += 1
    }
    guard lts <= 1, gts == lts, gt >= lt else { return [] }
    let addr = lts == 1 ? Array(clean[(lt + 1)..<gt]) : clean
    var at = -1
    inQuote = false
    i = 0
    while i < addr.count {
      let c = addr[i]
      if inQuote {
        if c == "\\" {
          i += 1
        } else if c == "\"" {
          inQuote = false
        }
      } else if c == "\"" {
        inQuote = true
      } else if c == "@" {
        at = i
      }
      i += 1
    }
    guard at >= 0 else { return [] }
    var lo = at + 1
    var hi = addr.count
    while lo < hi, addr[lo] == " " || addr[lo] == "\t" { lo += 1 }
    while hi > lo, addr[hi - 1] == " " || addr[hi - 1] == "\t" { hi -= 1 }
    var out: Scalars = []
    for c in addr[lo..<hi] {
      let l = c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(UInt8(c.value + 0x20)) : c
      let allowed = (l.value >= 0x61 && l.value <= 0x7a) || (l.value >= 0x30 && l.value <= 0x39) || l == "." || l == "-"
      guard allowed else { return [] }
      out.append(l)
    }
    while out.last == "." { out.removeLast() }
    return out
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
    /// Microsoft form: the first segment is a method spec, not an authserv-id. `methods` then
    /// holds the first segment's spec too, and `authservID` (the raw first token) never matches.
    let microsoftForm: Bool
    let readable: Bool
  }

  static func readFields(_ rawHeaders: String) -> [Field]? {
    guard rawHeaders.utf16.count <= maxRawUnits else { return nil }
    return unfold(Array(rawHeaders.unicodeScalars))
  }

  static func named(_ fields: [Field], _ name: Scalars) -> [Field] {
    fields.filter { jsLower(jsTrim($0.name)) == name }
  }

  static func named(_ fields: [Field], _ name: String) -> [Field] { named(fields, Array(name.unicodeScalars)) }

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
    let (clean, stripped) = stripComments(value)
    var readable = stripped
    let segments = splitTop(clean, ";")
    let idToken = tokenize(segments.first ?? []).first ?? []
    let authservID = string(jsLower(unquote(idToken)))
    // Microsoft's form has no authserv-id: its first token is already a method=result
    // (`spf=pass`). An authserv-id is a value token and cannot contain `=`, so the two forms
    // cannot be confused; in this form every segment, the first included, is a method spec.
    let microsoftForm = idToken.contains("=")
    var methods: [MethodSpec] = []
    for seg in segments.dropFirst(microsoftForm ? 0 : 1) {
      let toks = tokenize(seg)
      if toks.isEmpty { continue }
      if toks.count == 1, jsLower(toks[0]) == Array("none".unicodeScalars) { continue }
      guard let spec = parseMethodSpec(toks) else {
        readable = false
        continue
      }
      methods.append(spec)
    }
    return ARHeader(authservID: authservID, methods: methods, microsoftForm: microsoftForm, readable: readable)
  }

  static func parseMethodSpec(_ tokens: [Scalars]) -> MethodSpec? {
    guard let head = splitKV(tokens[0]) else { return nil }
    let name = head.key.split(separator: "/", omittingEmptySubsequences: false).first.map(Array.init) ?? []
    let method = string(jsLower(jsTrim(name)))
    if method.isEmpty { return nil }
    let result = string(jsLower(jsTrim(unquote(head.value))))
    var props: [(key: String, value: String)] = []
    for t in tokens.dropFirst() {
      guard let kv = splitKV(t) else { return nil }
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

  static func dkimDomain(_ spec: MethodSpec) -> String {
    spec.props.contains { $0.key.utf8.elementsEqual("header.d".utf8) }
      ? domainProp(spec, "header.d") : domainProp(spec, "header.i")
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
  /// space; quoted strings pass through verbatim. Not readable when a comment holds a `"`, a `)`
  /// closes no comment, or a comment or quoted string is left open.
  static func stripComments(_ v: Scalars) -> (Scalars, readable: Bool) {
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
        if c == "\"" { return (out, false) }
        if c == "(" {
          depth += 1
        } else if c == ")" {
          depth -= 1
        }
      } else if c == ")" {
        return (out, false)
      } else if c == "(" {
        depth += 1
        out.append(" ")
      } else {
        if c == "\"" { inQuote = true }
        out.append(c)
      }
      i += 1
    }
    return (out, depth == 0 && !inQuote)
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
