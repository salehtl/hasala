// The template executor: a port of the ledgerd TypeScript client's src/tmpl/exec.ts (the mirror of
// server/internal/tmpl/exec.go), byte-identical on conformance/templates.
//
// The body is ATTACKER-WRITABLE and this runs on the phone with a backtracking engine. Three
// separate things hold the line: the dialect (applied at LOAD time by `compile`), the input
// bounds (over them the message is REFUSED, never truncated), and the capture bound (a single
// group may hand back at most 512 runes). ICU's time limit is a fourth, backstop layer: a
// match it stops is reported as `too_large`, the same refusal as an over-size body.
//
// Every place where platforms differ by default is pinned: the trim cutset is " \t\n\v\f\r",
// only ASCII a-z is upper-cased, lengths are runes or UTF-8 bytes, money is an integer parsed
// from a digit string that already passed a shape check, the three date layouts are parsed by
// hand, and every text comparison is on bytes.
//
// The sender-domain gate is NOT applied here: it belongs to the trusted lane (CoreMail's
// verified domain), and giving this function a domain would invite a caller to hand it the
// body's own From line, which anyone can author.
import HasalaText

/// Why an execution produced no transaction.
public enum ExecError: String, Sendable, Equatable {
  case none = ""
  /// Routine: this mail is not for this template.
  case noMatch = "no_match"
  /// The drift signal: the template matched and a required field did not extract.
  case missingField = "missing_field"
  /// The input was over a bound (or ICU's time limit stopped a match): refused, not truncated.
  case tooLarge = "too_large"
}

/// What one template read out of one message. Presence is derived from the values (a
/// non-empty `currency` says an amount was extracted).
public struct Extraction: Sendable, Equatable {
  public var amountMinor: Int64 = 0
  public var currency = ""
  /// "debit", "credit" or "".
  public var direction = ""
  /// RFC 3339 UTC (zoneless UAE wall clock read as UTC, as the oracle does), or "" when no body
  /// date was produced (including `date_from: "email"`).
  public var postedAt = ""
  public var merchant = ""
  public var last4 = ""
  public var isTransfer = false
  /// The capture groups that MATCHED and captured nothing, as `<field>_<group>`, sorted.
  public var emptyGroups: [String] = []
  /// The template matched and every required field was produced.
  public var matched = false
  public var error: ExecError = .none

  static func zero(_ e: ExecError) -> Extraction {
    var x = Extraction()
    x.error = e
    return x
  }
}

/// Bounds: part of the cross-executor contract (different numbers extract different values).
public enum TemplateBounds {
  /// The normalized text, in UTF-8 bytes.
  public static let maxBodyBytes = 2_000_000
  /// The effective subject, in UTF-8 bytes.
  public static let maxSubjectBytes = 64_000
  /// One captured group, in runes.
  public static let maxCaptureRunes = 512
  /// The empty-group diagnostic.
  public static let maxEmptyGroups = 32
}

@inline(__always) func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// A definition with its patterns compiled once. Immutable; safe to share across tasks (each
/// match runs on its own clone of the compiled ICU pattern).
public struct CompiledTemplate: Sendable {
  public let definition: TemplateDefinition

  struct Entry: Sendable {
    let x: TemplateDefinition.Extract
    let res: [ICURegex]
  }

  let entries: [Entry]

  /// Checks everything execution depends on, runs the dialect gate over every pattern, and
  /// compiles them (`compileDefinition`). Throws `.dialect` for a pattern the dialect refuses
  /// and `.definition` for anything else malformed.
  public init(_ d: TemplateDefinition) throws(TemplateError) {
    guard Self.isCurrency(d.defaultCurrency) else {
      throw .definition("default_currency is not three upper-case letters, so no amount could carry a currency")
    }
    guard d.channelKnown else { throw .definition("channel is neither \"mail\" nor \"sms\"") }
    if d.isSMS {
      guard same(d.dateFrom, "received") else { throw .definition("an sms template's date_from is not \"received\"") }
    } else {
      guard same(d.dateFrom, "body") || same(d.dateFrom, "email") else {
        throw .definition("date_from is neither \"body\" nor \"email\"")
      }
    }
    for f in d.required {
      guard Field(f) != nil else { throw .definition("required names \(f), which is not a field") }
      if Field(f) == .isTransfer {
        throw .definition("is_transfer cannot be required: a false flag is indistinguishable from an unset one")
      }
      if Field(f) == .date && same(d.dateFrom, "received") {
        throw .definition("date cannot be required when date_from is \"received\"")
      }
    }
    var entries: [Entry] = []
    var dates = 0
    for (i, x) in d.extract.enumerated() {
      entries.append(try Self.compileEntry(i, x))
      if Field(x.field) == .date { dates += 1 }
    }
    if same(d.dateFrom, "body") && dates == 0 {
      throw .definition("date_from is \"body\" but no extract entry produces a date")
    }
    if same(d.dateFrom, "email") && dates > 0 {
      throw .definition("date_from is \"email\" but \(dates) extract entries produce a date")
    }
    definition = d
    self.entries = entries
  }

  /// Decodes and compiles a definition from its JSON text.
  public init(json: [UInt8]) throws(TemplateError) {
    try self.init(try TemplateDefinition(json: json))
  }

  enum Field: String {
    case amount, date, merchant, last4, direction
    case isTransfer = "is_transfer"

    init?(_ s: String) {
      guard s.utf8.allSatisfy({ $0 < 0x80 }), let f = Field(rawValue: s) else { return nil }
      self = f
    }

    /// The legal types for this field.
    var types: [ValueType] {
      switch self {
      case .amount: [.amount]
      case .date: [.date]
      case .merchant: [.text, .const]
      case .last4: [.last4, .const]
      case .direction: [.const]
      case .isTransfer: [.flag]
      }
    }
  }

  enum ValueType: String {
    case amount, date, text, last4, const, flag

    init?(_ s: String) {
      guard s.utf8.allSatisfy({ $0 < 0x80 }), let t = ValueType(rawValue: s) else { return nil }
      self = t
    }

    /// The named groups the executor reads for this type: it reads exactly these.
    var requiredGroups: [String] {
      switch self {
      case .amount: ["amt"]
      case .date: ["d"]
      case .text, .last4: ["v"]
      case .const, .flag: []
      }
    }
  }

  static let layouts = ["DD-MM-YYYY", "DD/Mon/YYYY hh:mm A", "DD/Mon/YYYY", "DD-MM-YYYY HH:mm"]

  static func compileEntry(_ i: Int, _ x: TemplateDefinition.Extract) throws(TemplateError) -> Entry {
    func fail(_ msg: String) -> TemplateError { .definition("extract[\(i)]: \(msg)") }
    guard let field = Field(x.field) else { throw fail("field \(x.field) is not a field name") }
    guard let type = ValueType(x.type) else { throw fail("type \(x.type) is not a type") }
    guard field.types.contains(type) else { throw fail("field \(x.field) cannot be extracted as type \(x.type)") }
    guard same(x.source, "body") || same(x.source, "subject") else {
      throw fail("source \(x.source) is neither \"body\" nor \"subject\"")
    }
    let isConst = type == .const || type == .flag
    if isConst {
      if let err = checkLiteral(x.field, x.value ?? "") { throw fail(err) }
    } else if x.patterns.isEmpty {
      throw fail("a \(x.type) entry with no patterns can never produce a value")
    }
    for (f, v) in x.onMatch {
      if let err = checkLiteral(f, v) { throw fail("on_match: \(err)") }
    }
    if type == .date {
      if x.layouts.isEmpty { throw fail("a date entry with no layouts can never convert its capture") }
      for l in x.layouts where !layouts.contains(where: { same($0, l) }) {
        throw fail("layout \(l) is not one of the supported layouts")
      }
    }

    var res: [ICURegex] = []
    for (j, p) in x.patterns.enumerated() {
      // The load-time dialect gate: before the pattern is compiled, never after.
      let (codes, compiled) = Dialect.validateAndCompile(p, flags: x.flags)
      guard codes.isEmpty, let compiled else {
        let list = codes.map(\.rawValue)
        throw .dialect(
          "extract[\(i)].patterns[\(j)] violates the template dialect: \(list.joined(separator: ", "))", codes: list)
      }
      let names = Dialect.groupNames(p)
      for want in type.requiredGroups where !names.contains(where: { same($0, want) }) {
        throw fail("patterns[\(j)] does not capture (?P<\(want)>...), so a \(x.type) entry could never read a value from it")
      }
      // Every named group can become a diagnostics label, which must be a bounded identifier.
      for n in names where !isLabel(emptyGroupLabel(x.field, n)) {
        throw fail("patterns[\(j)] group \(n) would produce a diagnostics label that is not a bounded identifier")
      }
      res.append(compiled)
    }
    return Entry(x: x, res: res)
  }

  /// Validates a value written into a field verbatim; nil when it is acceptable.
  static func checkLiteral(_ field: String, _ value: String) -> String? {
    switch Field(field) {
    case .direction?:
      return same(value, "debit") || same(value, "credit") ? nil : "direction \(value) is neither debit nor credit"
    case .isTransfer?:
      return same(value, "true") || same(value, "false") ? nil : "is_transfer \(value) is neither true nor false"
    case .merchant?, .last4?:
      if value.isEmpty { return "\(field) cannot be set to the empty string" }
      return runeCountExceeds(value, TemplateBounds.maxCaptureRunes)
        ? "\(field) literal is longer than \(TemplateBounds.maxCaptureRunes) runes" : nil
    default:
      return "\(field) cannot be set from a literal value"
    }
  }

  // MARK: - Execution

  /// Runs the template over one message (its effective subject and normalized text). On
  /// `missing_field` the extraction carries everything that DID extract; on `no_match` it is
  /// the zero value. Throws `.cancelled` when the calling task is cancelled (checked before
  /// every pattern search), and otherwise only for a state no correct executor reaches
  /// (`.definition`).
  public func execute(subject: String, normalizedBody: String) throws(TemplateError) -> Extraction {
    if normalizedBody.utf8.count > TemplateBounds.maxBodyBytes { return .zero(.tooLarge) }
    if subject.utf8.count > TemplateBounds.maxSubjectBytes { return .zero(.tooLarge) }
    if !gate(subject: subject, body: normalizedBody) { return .zero(.noMatch) }

    let subject16 = Array(subject.utf16)
    let body16 = Array(normalizedBody.utf16)
    var st = State()
    do {
      for ce in entries {
        // First entry that produces a value for a field wins; later entries for it are
        // SKIPPED (not evaluated), unless they override.
        if st.refused.contains(ce.x.field) || (st.isSet(ce.x.field) && !ce.x.override) { continue }
        let src = same(ce.x.source, "subject") ? subject16 : body16
        if try !runEntry(&st, ce, src) { continue }
        for (f, v) in ce.x.onMatch.sorted(by: { Self.byCodeUnit($0.key, $1.key) }) where !st.isSet(f) {
          try st.setLiteral(f, v)
        }
      }
    } catch RunError.limitExceeded {
      return .zero(.tooLarge)
    } catch RunError.cancelled {
      throw .cancelled
    } catch {
      throw .definition("an entry failed to run")
    }

    var out = st.finish()
    let err = try validate(out)
    if err != .none {
      out.error = err
      return out
    }
    out.matched = true
    return out
  }

  /// Code-unit order of two keys (`byCodeUnit`); the keys are ASCII identifiers.
  static func byCodeUnit(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

  /// The content half of `match`: every listed string present (or, for body_not_contains,
  /// absent). Substring tests are on UTF-8 bytes.
  func gate(subject: String, body: String) -> Bool {
    let s = Array(subject.utf8)
    let b = Array(body.utf8)
    for n in definition.match.subjectContains where !Self.contains(s, Array(n.utf8)) { return false }
    for n in definition.match.bodyContains where !Self.contains(b, Array(n.utf8)) { return false }
    for n in definition.match.bodyNotContains where Self.contains(b, Array(n.utf8)) { return false }
    return true
  }

  static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty { return true }
    guard hay.count >= needle.count else { return false }
    var i = 0
    let last = hay.count - needle.count
    outer: while i <= last {
      for j in 0..<needle.count where hay[i + j] != needle[j] {
        i += 1
        continue outer
      }
      return true
    }
    return false
  }

  enum RunError: Error {
    case limitExceeded
    case cancelled
    case definition
  }

  /// Evaluates one entry; whether it produced a value. A pattern that does not match, or
  /// whose capture fails typed conversion, moves on to the next pattern. A currency the format
  /// refuses ends the field for the run.
  func runEntry(_ st: inout State, _ ce: Entry, _ src: [UInt16]) throws(RunError) -> Bool {
    let x = ce.x
    // A const or flag entry with no patterns is an unconditional default.
    if ce.res.isEmpty {
      do { try st.setLiteral(x.field, x.value ?? "") } catch { throw .definition }
      return true
    }
    guard let type = ValueType(x.type) else { throw .definition }
    for re in ce.res {
      // Each search is bounded by ICU's limit; the run as a whole is bounded by the caller's
      // deadline, which arrives as cancellation.
      if Task.isCancelled { throw .cancelled }
      let m: ICURegex.Match?
      do { m = try re.firstMatch(in: src) } catch { throw .limitExceeded }
      guard let m else { continue }
      func group(_ name: String) -> String? {
        for (k, n) in re.groups.enumerated() where n.map({ same($0, name) }) == true {
          guard let r = m.groups[k] else { return nil }
          return String(decoding: src[r], as: UTF16.self)
        }
        return nil
      }
      st.recordEmptyGroups(x.field, re, m)

      switch type {
      case .const, .flag:
        do { try st.setLiteral(x.field, x.value ?? "") } catch { throw .definition }
        return true
      case .amount:
        guard let amt = group("amt") else { continue }
        guard let got = Self.convertAmount(amt, group("ccy"), definition.defaultCurrency) else {
          if Self.currencyRefused(group("ccy"), definition.defaultCurrency) {
            st.refused.insert(x.field)
            return false
          }
          continue
        }
        st.setAmount(got.minor, got.currency)
        return true
      case .date:
        guard let text = group("d") else { continue }
        guard let when = Self.convertDate(text, x.layouts) else { continue }
        st.setDate(when)
        return true
      case .text:
        guard let text = group("v"), let value = Self.convertText(text) else { continue }
        do { try st.setLiteral(x.field, value) } catch { throw .definition }
        return true
      case .last4:
        guard let text = group("v"), let value = Self.convertLast4(text) else { continue }
        do { try st.setLiteral(x.field, value) } catch { throw .definition }
        return true
      }
    }
    return false
  }

  /// The second gate (`validateExtraction`): every required field produced, and the extraction
  /// internally coherent.
  func validate(_ e: Extraction) throws(TemplateError) -> ExecError {
    for f in definition.required {
      guard let field = Field(f), field != .isTransfer else { throw .definition("required names \(f)") }
      if !Self.produced(e, field) { return .missingField }
    }
    if e.amountMinor < 0 { throw .definition("a negative amount") }
    if e.amountMinor != 0 && e.currency.isEmpty { throw .definition("an amount with no currency") }
    if !e.currency.isEmpty && !Self.isCurrency(e.currency) { throw .definition("a malformed currency") }
    if !e.last4.isEmpty && !Self.isLast4(e.last4) { throw .definition("a malformed last4") }
    if runeCountExceeds(e.merchant, TemplateBounds.maxCaptureRunes) { throw .definition("an oversized merchant") }
    if same(definition.dateFrom, "email") && !e.postedAt.isEmpty {
      throw .definition("date_from is \"email\" but a date was extracted from the body")
    }
    return .none
  }

  /// Whether the field was extracted (`is_transfer` never counts: false looks like unset).
  static func produced(_ e: Extraction, _ f: Field) -> Bool {
    switch f {
    case .amount: !e.currency.isEmpty
    case .date: !e.postedAt.isEmpty
    case .merchant: !e.merchant.isEmpty
    case .last4: !e.last4.isEmpty
    case .direction: !e.direction.isEmpty
    case .isTransfer: false
    }
  }

  // MARK: - State

  struct State {
    var amountMinor: Int64 = 0
    var currency = ""
    var direction = ""
    var postedAt = ""
    var merchant = ""
    var last4 = ""
    var isTransfer = false
    var set: [Field] = []
    var empty: [String] = []
    var refused: Set<String> = []

    func isSet(_ field: String) -> Bool { Field(field).map { set.contains($0) } ?? false }

    mutating func mark(_ f: Field) { if !set.contains(f) { set.append(f) } }

    mutating func setAmount(_ minor: Int64, _ ccy: String) {
      amountMinor = minor
      currency = ccy
      mark(.amount)
    }

    mutating func setDate(_ rfc3339: String) {
      postedAt = rfc3339
      mark(.date)
    }

    enum LiteralError: Error { case notSettable }

    /// A value that needs no conversion: a const/flag value, an on_match entry, or an
    /// already-converted capture.
    mutating func setLiteral(_ field: String, _ value: String) throws(LiteralError) {
      guard let f = Field(field) else { throw .notSettable }
      switch f {
      case .direction: direction = same(value, "credit") ? "credit" : same(value, "debit") ? "debit" : ""
      case .merchant: merchant = value
      case .last4: last4 = value
      case .isTransfer: isTransfer = same(value, "true")
      case .amount, .date: throw .notSettable
      }
      mark(f)
    }

    /// Records the named groups that MATCHED and captured nothing. A group that did not
    /// participate at all is not empty.
    mutating func recordEmptyGroups(_ field: String, _ re: ICURegex, _ m: ICURegex.Match) {
      for (k, name) in re.groups.enumerated() {
        guard let name, let r = m.groups[k], r.isEmpty else { continue }
        let label = emptyGroupLabel(field, name)
        if !empty.contains(where: { same($0, label) }) { empty.append(label) }
      }
    }

    func finish() -> Extraction {
      var labels = empty.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      if labels.count > TemplateBounds.maxEmptyGroups { labels = Array(labels.prefix(TemplateBounds.maxEmptyGroups)) }
      var e = Extraction()
      e.amountMinor = amountMinor
      e.currency = currency
      e.direction = direction
      // Go's zero time is not a date (`Time.IsZero`).
      e.postedAt = same(postedAt, "0001-01-01T00:00:00Z") ? "" : postedAt
      e.merchant = merchant
      e.last4 = last4
      e.isTransfer = isTransfer
      e.emptyGroups = labels
      return e
    }
  }

  // MARK: - Typed conversion

  static func isCurrency(_ s: String) -> Bool {
    let u = Array(s.utf8)
    return u.count == 3 && u.allSatisfy { $0 >= 0x41 && $0 <= 0x5a }
  }

  static func isLast4(_ s: String) -> Bool {
    let u = Array(s.utf8)
    return (1...4).contains(u.count) && u.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
  }

  static func isLabel(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard let f = u.first, u.count <= 32 else { return false }
    func head(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f }
    return head(f) && u.dropFirst().allSatisfy { head($0) || ($0 >= 0x30 && $0 <= 0x39) }
  }

  /// The executor's own cutset, " \t\n\v\f\r" (Go's strings.Trim with it).
  static func trimCapture(_ s: String) -> String { s.trimming(.asciiSpace) }

  static func resolveCurrency(_ ccy: String?, _ defaultCurrency: String) -> String? {
    let c = ASCII.uppercased(trimCapture(ccy ?? ""))
    if c.isEmpty { return defaultCurrency }
    return isCurrency(c) ? c : nil
  }

  static let nonTwoDecimalCurrencies: Set<String> = [
    "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND",
    "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
  ]

  /// Rule 5: the `amt` group holds the NUMBER only: commas removed, exactly two decimals, no
  /// sign, at most Int64.max minor units. An optional `ccy` group overrides the default
  /// currency and must then be three letters (ASCII-upper-cased first). A currency whose minor
  /// exponent is not 2 (ISO 4217, the same table as CoreMoney's) is refused.
  static func convertAmount(_ amt: String, _ ccy: String?, _ defaultCurrency: String) -> (minor: Int64, currency: String)? {
    let trimmed = trimCapture(amt)
    if runeCountExceeds(trimmed, TemplateBounds.maxCaptureRunes) { return nil }
    let digits = trimmed.utf8.filter { $0 != 0x2c }
    // ^[0-9]+\.[0-9]{2}$
    guard digits.count >= 4, digits[digits.count - 3] == 0x2e else { return nil }
    let whole = digits[0..<(digits.count - 3)]
    let frac = digits[(digits.count - 2)...]
    func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    guard whole.allSatisfy(isDigit), frac.allSatisfy(isDigit) else { return nil }
    var minor: UInt64 = 0
    for b in whole + frac {
      let (m, o1) = minor.multipliedReportingOverflow(by: 10)
      let (s, o2) = m.addingReportingOverflow(UInt64(b - 0x30))
      if o1 || o2 { return nil }
      minor = s
    }
    guard minor <= UInt64(Int64.max), let currency = resolveCurrency(ccy, defaultCurrency),
      !nonTwoDecimalCurrencies.contains(currency)
    else {
      return nil
    }
    return (Int64(minor), currency)
  }

  static func currencyRefused(_ ccy: String?, _ defaultCurrency: String) -> Bool {
    resolveCurrency(ccy, defaultCurrency).map(nonTwoDecimalCurrencies.contains) ?? false
  }

  /// Rule 6: each declared layout in order, on the whole trimmed capture and then on the text
  /// before its first U+0020.
  static func convertDate(_ text: String, _ layouts: [String]) -> String? {
    let trimmed = trimCapture(text)
    if runeCountExceeds(trimmed, TemplateBounds.maxCaptureRunes) { return nil }
    let u = Array(trimmed.utf16)
    for l in layouts {
      if let got = parseExact(u[...], l) { return got }
      if let sp = u.firstIndex(of: 0x20), let got = parseExact(u[0..<sp], l) { return got }
    }
    return nil
  }

  static let shortMonths: [[UInt16]] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    .map { Array($0.utf16) }

  /// One layout, whole string, no trailing text: the hand-written mirror of Go's time.Parse for
  /// exactly these three layouts (month names fold ASCII case, AM/PM does not; numeric fields
  /// are fixed-width; calendar ranges checked; no zone, so UTC).
  static func parseExact(_ s: ArraySlice<UInt16>, _ layout: String) -> String? {
    var i = s.startIndex
    func num(_ n: Int) -> Int? {
      guard i + n <= s.endIndex else { return nil }
      var v = 0
      for k in 0..<n {
        let c = s[i + k]
        guard c >= 0x30 && c <= 0x39 else { return nil }
        v = v * 10 + Int(c - 0x30)
      }
      i += n
      return v
    }
    func lit(_ c: UInt16) -> Bool {
      guard i < s.endIndex, s[i] == c else { return false }
      i += 1
      return true
    }

    var hour = 0
    var minute = 0
    let day: Int
    let month: Int
    let year: Int
    if same(layout, "DD-MM-YYYY") || same(layout, "DD-MM-YYYY HH:mm") {
      guard let d = num(2), lit(0x2d), let mo = num(2), lit(0x2d), let y = num(4) else { return nil }
      (day, month, year) = (d, mo, y)
      if same(layout, "DD-MM-YYYY HH:mm") {
        guard lit(0x20), i < s.endIndex, s[i] >= 0x30 && s[i] <= 0x39 else { return nil }
        let wide = i + 1 < s.endIndex && s[i + 1] >= 0x30 && s[i + 1] <= 0x39
        guard let h = num(wide ? 2 : 1), lit(0x3a), let m = num(2) else { return nil }
        if h > 23 || m > 59 { return nil }
        hour = h
        minute = m
      }
    } else {
      guard let d = num(2), lit(0x2f) else { return nil }
      // Go's lookup(shortMonthNames): exactly three characters, ASCII-case-insensitive.
      guard i + 3 <= s.endIndex else { return nil }
      var name: [UInt16] = []
      for k in 0..<3 {
        let c = s[i + k]
        name.append(c >= 0x41 && c <= 0x5a ? c + 0x20 : c)
      }
      guard let idx = shortMonths.firstIndex(of: name) else { return nil }
      i += 3
      guard lit(0x2f), let y = num(4) else { return nil }
      (day, month, year) = (d, idx + 1, y)
      if same(layout, "DD/Mon/YYYY hh:mm A") {
        guard lit(0x20), let h = num(2), lit(0x3a), let m = num(2), lit(0x20) else { return nil }
        guard i + 2 <= s.endIndex else { return nil }
        let marker = (s[i], s[i + 1])
        let pm = marker == (0x50, 0x4d)
        guard pm || marker == (0x41, 0x4d) else { return nil }
        i += 2
        hour = h
        minute = m
        if hour > 12 || minute > 59 { return nil }
        if pm && hour < 12 { hour += 12 }
        if !pm && hour == 12 { hour = 0 }
      }
    }
    guard i == s.endIndex else { return nil }  // trailing text
    guard month >= 1 && month <= 12 else { return nil }
    guard day >= 1 && day <= daysIn(month, year) else { return nil }
    return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):00Z"
  }

  static func daysIn(_ month: Int, _ year: Int) -> Int {
    switch month {
    case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  static func pad(_ n: Int, _ width: Int) -> String {
    let s = String(n)
    return s.utf8.count >= width ? s : String(repeating: "0", count: width - s.utf8.count) + s
  }

  /// A trimmed, non-empty capture of at most 512 runes.
  static func convertText(_ s: String) -> String? {
    let t = trimCapture(s)
    return t.isEmpty || runeCountExceeds(t, TemplateBounds.maxCaptureRunes) ? nil : t
  }

  /// Rule 7: drop every non-ASCII-digit, keep the last four; none is a failure.
  static func convertLast4(_ s: String) -> String? {
    if runeCountExceeds(s, TemplateBounds.maxCaptureRunes) { return nil }
    var digits: [UInt8] = []
    for b in s.utf8 where b >= 0x30 && b <= 0x39 {
      digits.append(b)
      if digits.count > 4 { digits.removeFirst() }
    }
    return digits.isEmpty ? nil : String(decoding: digits, as: UTF8.self)
  }
}

func emptyGroupLabel(_ field: String, _ group: String) -> String { field + "_" + group }

/// Whether `s` is longer than `max` runes (Go's utf8.RuneCountInString(s) > max).
func runeCountExceeds(_ s: String, _ max: Int) -> Bool {
  var n = 0
  for _ in s.unicodeScalars {
    n += 1
    if n > max { return true }
  }
  return false
}
