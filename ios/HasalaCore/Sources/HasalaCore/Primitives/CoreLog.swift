// `CoreLog`: the core's one logger, a thin `os.Logger` wrapper (spec 04 §2.2,
// CorePrimitives; spec 01 §11.6; spec 04 §2.4 R7).
//
// The shape makes the safe call the only one that compiles:
//   - the event is a `StaticString`, so it is written in the source and can
//     never carry user data;
//   - a field is a count, a static state name, or a `.private` string. There is
//     no field that takes an arbitrary value, so a secret type (`SecureBytes`, a
//     key, a phrase) cannot be interpolated even privately (01 §11.6), and
//     there is no `String` interpolation into the public part of a line;
//   - everything that is not a count or a static name is `privacy: .private`.
//
// R7 still applies to what goes into `.private`: amounts, merchants, email
// addresses, Gmail ids, tokens, keys and phrase words are never logged, not even
// privately. Diagnostics carry counts and states only (01 §11.6).
import os

public struct CoreLog: Sendable {
  /// The unified-logging subsystem every core category logs under.
  public static let subsystem = "HasalaCore"

  /// One `key=value` field of a log line.
  public struct Field: Sendable {
    enum Value: Sendable {
      case count(Int64)
      case state(StaticString)
      case redacted(String)
    }

    let key: StaticString
    let value: Value

    /// A count or other number that is not user data (public).
    public static func count(_ key: StaticString, _ n: some BinaryInteger) -> Field {
      Field(key: key, value: .count(Int64(clamping: n)))
    }

    /// A state, reason class or code written in the source (public).
    public static func state(_ key: StaticString, _ name: StaticString) -> Field {
      Field(key: key, value: .state(name))
    }

    /// Text that may derive from user data: logged `.private` only. Never an
    /// amount, merchant, address, id, token, key or phrase word (R7).
    public static func redacted(_ key: StaticString, _ text: String) -> Field {
      Field(key: key, value: .redacted(text))
    }
  }

  private let logger: Logger

  /// A logger for one category (by convention the module, e.g. `"CoreSync"`).
  public init(category: StaticString) {
    logger = Logger(subsystem: CoreLog.subsystem, category: "\(category)")
  }

  public func debug(_ event: StaticString, _ fields: Field...) { emit(.debug, event, fields) }
  public func info(_ event: StaticString, _ fields: Field...) { emit(.info, event, fields) }
  public func notice(_ event: StaticString, _ fields: Field...) { emit(.default, event, fields) }
  public func error(_ event: StaticString, _ fields: Field...) { emit(.error, event, fields) }
  public func fault(_ event: StaticString, _ fields: Field...) { emit(.fault, event, fields) }

  private func emit(_ level: OSLogType, _ event: StaticString, _ fields: [Field]) {
    let line = CoreLog.render(event, fields)
    if line.redacted.isEmpty {
      logger.log(level: level, "\(line.public, privacy: .public)")
    } else {
      logger.log(level: level, "\(line.public, privacy: .public) \(line.redacted, privacy: .private)")
    }
  }

  /// Splits a line into the part logged in the clear (the event, counts and
  /// states) and the part logged `.private`. Exposed to the package for tests.
  package static func render(_ event: StaticString, _ fields: [Field]) -> (public: String, redacted: String) {
    var open = "\(event)"
    var hidden: [String] = []
    for f in fields {
      switch f.value {
      case .count(let n): open += " \(f.key)=\(n)"
      case .state(let s): open += " \(f.key)=\(s)"
      case .redacted(let t): hidden.append("\(f.key)=\(t)")
      }
    }
    return (open, hidden.joined(separator: " "))
  }
}
