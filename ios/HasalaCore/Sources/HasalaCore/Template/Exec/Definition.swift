// The template format (server/internal/tmpl/v2-template-format.md; tmpl/exec.ts `Definition`),
// read from JSON with CoreJSON. A definition is data that crossed a network or came out of the
// bundle; every field is type-checked here, and anything malformed is refused (fail closed:
// the mailbox routes the mail to review rather than guessing).
import CoreJSON
import HasalaText

public enum TemplateError: Error, Equatable, Sendable {
  /// A definition this executor cannot run (the publish gate refuses these; one here means a
  /// template reached the device without passing it).
  case definition(String)
  /// A pattern that violates the dialect, with Go's reason codes in scan order.
  case dialect(String, codes: [String])
  /// The calling task was cancelled; checked before every pattern search. A run's worst case
  /// is its pattern count times ICU's per-search limit (several seconds on a hostile 2 MB
  /// body), so the caller's deadline is enforced by cancelling the task that runs `execute`
  /// (inventory client-core-b §2.3). Not a verdict: nothing about the message is recorded.
  case cancelled
}

public struct TemplateDefinition: Sendable, Equatable {
  public struct Match: Sendable, Equatable {
    public var senderDomain: [String]
    public var smsSender: [String]
    public var subjectContains: [String]
    public var bodyContains: [String]
    public var bodyNotContains: [String]
  }

  public struct Extract: Sendable, Equatable {
    public var field: String
    public var type: String
    public var source: String
    public var patterns: [String]
    public var flags: [String]
    public var layouts: [String]
    public var value: String?
    public var override: Bool
    public var why: String
    /// `on_match` in document order (applied in code-unit order of the keys).
    public var onMatch: [(key: String, value: String)]

    public static func == (a: Extract, b: Extract) -> Bool {
      a.field == b.field && a.type == b.type && a.source == b.source && a.patterns == b.patterns
        && a.flags == b.flags && a.layouts == b.layouts && a.value == b.value && a.override == b.override
        && a.why == b.why && a.onMatch.map(\.key) == b.onMatch.map(\.key)
        && a.onMatch.map(\.value) == b.onMatch.map(\.value)
    }
  }

  public var id: String
  public var version: Int
  public var bank: String
  public var normalizerVersion: Int
  public var channel: String
  public var match: Match
  public var defaultCurrency: String
  public var dateFrom: String
  public var extract: [Extract]
  public var required: [String]

  /// Decodes a definition from its JSON text.
  public init(json bytes: [UInt8]) throws(TemplateError) {
    let v: JSONValue
    do {
      v = try JSONParser.parse(bytes)
    } catch {
      throw .definition("the definition is not JSON")
    }
    try self.init(json: v)
  }

  public init(json v: JSONValue) throws(TemplateError) {
    guard let o = v.objectValue else { throw .definition("the definition is not an object") }
    id = try Self.string(o, "id") ?? ""
    version = try Self.int(o, "version") ?? 0
    bank = try Self.string(o, "bank") ?? ""
    normalizerVersion = try Self.int(o, "normalizer_version") ?? 0
    channel = try Self.string(o, "channel") ?? ""
    let m = try Self.object(o, "match") ?? JSONObject()
    match = Match(
      senderDomain: try Self.strings(m, "sender_domain"), smsSender: try Self.strings(m, "sms_sender"),
      subjectContains: try Self.strings(m, "subject_contains"), bodyContains: try Self.strings(m, "body_contains"),
      bodyNotContains: try Self.strings(m, "body_not_contains"))
    defaultCurrency = try Self.string(o, "default_currency") ?? ""
    dateFrom = try Self.string(o, "date_from") ?? ""
    required = try Self.strings(o, "required")
    var extract: [Extract] = []
    if let raw = o["extract"], !raw.isNull {
      guard let items = raw.arrayValue else { throw .definition("extract is not an array") }
      for (i, item) in items.enumerated() {
        guard let e = item.objectValue else { throw .definition("extract[\(i)] is not an object") }
        var onMatch: [(key: String, value: String)] = []
        if let om = try Self.object(e, "on_match") {
          for member in om.members {
            guard let s = member.value.stringValue else { throw .definition("extract[\(i)].on_match values must be strings") }
            onMatch.append((member.key, s))
          }
        }
        let override: Bool
        switch e["override"] {
        case nil, .null?: override = false
        case .bool(let b)?: override = b
        default: throw .definition("extract[\(i)].override is not a boolean")
        }
        extract.append(
          Extract(
            field: try Self.string(e, "field") ?? "", type: try Self.string(e, "type") ?? "",
            source: try Self.string(e, "source") ?? "", patterns: try Self.strings(e, "patterns"),
            flags: try Self.strings(e, "flags"), layouts: try Self.strings(e, "layouts"),
            value: try Self.string(e, "value"), override: override, why: try Self.string(e, "why") ?? "",
            onMatch: onMatch))
      }
    }
    self.extract = extract
  }

  /// The canonical encoding (Go's `Definition.Canonical`): every key at every level, present
  /// (no omitempty) and sorted, with JSON.stringify's escaping. Pinned by
  /// conformance/dialect/patterns.json `canonical`.
  public func canonicalJSON() -> [UInt8] {
    func strs(_ a: [String]) -> JSONValue { .array(a.map { .string($0) }) }
    let extracts: [JSONValue] = extract.map { e in
      .object(
        JSONObject([
          ("field", .string(e.field)), ("flags", strs(e.flags)), ("layouts", strs(e.layouts)),
          ("on_match", .object(JSONObject(e.onMatch.map { ($0.key, JSONValue.string($0.value)) }))),
          ("override", .bool(e.override)), ("patterns", strs(e.patterns)), ("source", .string(e.source)),
          ("type", .string(e.type)), ("value", .string(e.value ?? "")), ("why", .string(e.why)),
        ]))
    }
    var matchFields: [(String, JSONValue)] = [
      ("body_contains", strs(match.bodyContains)), ("body_not_contains", strs(match.bodyNotContains)),
      ("sender_domain", strs(match.senderDomain)), ("subject_contains", strs(match.subjectContains)),
    ]
    if !match.smsSender.isEmpty { matchFields.append(("sms_sender", strs(match.smsSender))) }
    var fields: [(String, JSONValue)] = [
      ("bank", .string(bank)), ("date_from", .string(dateFrom)), ("default_currency", .string(defaultCurrency)),
      ("extract", .array(extracts)), ("id", .string(id)), ("match", .object(JSONObject(matchFields))),
      ("normalizer_version", .number(JSONNumber(Int64(normalizerVersion)))), ("required", strs(required)),
      ("version", .number(JSONNumber(Int64(version)))),
    ]
    if !channel.isEmpty && !channel.utf8.elementsEqual("mail".utf8) { fields.append(("channel", .string(channel))) }
    return JSONWriter().bytes(JSONValue.object(JSONObject(fields)).sortingKeysByUTF8())
  }

  public var isSMS: Bool { channel.utf8.elementsEqual("sms".utf8) }

  var channelKnown: Bool { channel.isEmpty || channel.utf8.elementsEqual("mail".utf8) || isSMS }

  public func matchesSMSSender(_ sender: String) -> Bool {
    guard isSMS else { return false }
    let s = ASCII.lowercased(sender.trimming(.asciiSpace))
    if s.isEmpty { return false }
    return match.smsSender.contains { ASCII.lowercased($0).utf8.elementsEqual(s.utf8) }
  }

  // MARK: - Field access (null and absent are the same: Go's zero value)

  static func string(_ o: JSONObject, _ k: String) throws(TemplateError) -> String? {
    switch o[k] {
    case nil, .null?: return nil
    case .string(let s)?: return s
    default: throw .definition("\(k) is not a string")
    }
  }

  static func int(_ o: JSONObject, _ k: String) throws(TemplateError) -> Int? {
    switch o[k] {
    case nil, .null?: return nil
    case .number(let n)?:
      guard let v = n.int64Value, let i = Int(exactly: v) else { throw .definition("\(k) is not an integer") }
      return i
    default: throw .definition("\(k) is not a number")
    }
  }

  static func object(_ o: JSONObject, _ k: String) throws(TemplateError) -> JSONObject? {
    switch o[k] {
    case nil, .null?: return nil
    case .object(let v)?: return v
    default: throw .definition("\(k) is not an object")
    }
  }

  static func strings(_ o: JSONObject, _ k: String) throws(TemplateError) -> [String] {
    switch o[k] {
    case nil, .null?: return []
    case .array(let a)?:
      var out: [String] = []
      for x in a {
        guard let s = x.stringValue else { throw .definition("\(k) holds a non-string") }
        out.append(s)
      }
      return out
    default: throw .definition("\(k) is not an array")
    }
  }
}
