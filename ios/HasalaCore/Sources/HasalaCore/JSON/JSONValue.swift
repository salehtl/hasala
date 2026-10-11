// A strict JSON value that keeps what `JSONSerialization` and `JSONDecoder`
// throw away (spec 04 §2.2; spec 03c §1.1-§1.2; client-core-a §3 hazards 1-3):
//
//   - the NUMBER LITERAL, exactly as written: `1`, `1.0` and `1e0` are three
//     different literals, and the v4 decoders refuse the last two where an
//     integer is required. A literal past 2^53 stays exact.
//   - OBJECT KEY ORDER, as first seen. Duplicate keys are last-wins, as
//     `JSON.parse` does: the key keeps its first position and takes the last
//     value.
//   - the difference between `1` and `true` (no NSNumber bridging).
//
// Byte-exact module (spec 04 §2.4 R2): no Foundation JSON, no Double on any
// path that decides a value, no Character iteration.
import CoreText

public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(JSONNumber)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  // Equality and hashing compare strings by UTF-8 BYTES. The synthesized
  // versions would use `String ==`, under which NFC and NFD spellings are
  // equal: two values that write different bytes would compare equal.
  public static func == (a: JSONValue, b: JSONValue) -> Bool {
    switch (a, b) {
    case (.null, .null): true
    case (.bool(let x), .bool(let y)): x == y
    case (.number(let x), .number(let y)): x == y
    case (.string(let x), .string(let y)): utf8Equal(x, y)
    case (.array(let x), .array(let y)): x == y
    case (.object(let x), .object(let y)): x == y
    default: false
    }
  }

  public func hash(into h: inout Hasher) {
    switch self {
    case .null: h.combine(0)
    case .bool(let b): h.combine(1); h.combine(b)
    case .number(let n): h.combine(2); h.combine(n)
    case .string(let s): h.combine(3); h.combine(Array(s.utf8))
    case .array(let a): h.combine(4); h.combine(a)
    case .object(let o): h.combine(5); h.combine(o)
    }
  }
}

/// A JSON number, held as its literal text (RFC 8259 grammar, validated on
/// construction).
public struct JSONNumber: Sendable, Hashable, CustomStringConvertible {
  public let literal: String

  /// `nil` unless `literal` is an RFC 8259 number:
  /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
  public init?(literal: String) {
    guard JSONNumber.isNumberLiteral(Array(literal.utf8)) else { return nil }
    self.literal = literal
  }

  /// An integer, written in its canonical decimal form.
  public init(_ value: Int64) { literal = String(value) }

  init(validated literal: String) { self.literal = literal }

  public var description: String { literal }

  /// Whether the literal is a plain integer: `-?(0|[1-9][0-9]*)`. `1.0`, `1e0`
  /// and `-0` included as written; see ``v4Int`` for the v4 rule.
  public var isIntegerLiteral: Bool {
    var u = Substring(literal).utf8[...]
    if u.first == 0x2d { u = u.dropFirst() }
    return !u.isEmpty && u.allSatisfy(ASCII.isDigit)
  }

  /// The value as `Int64` when the literal is an integer literal that fits
  /// (`-0` reads as 0); `nil` for a fraction, an exponent or an out-of-range
  /// literal. No rounding ever happens.
  public var int64Value: Int64? {
    isIntegerLiteral ? Int64(literal) : nil
  }

  /// The spec 03c §1.2 v4 `Int`: an integer literal with no fraction, no
  /// exponent and not `-0`, in `[-(2^53-1), 2^53-1]`. `nil` otherwise.
  public var v4Int: Int64? {
    guard literal != "-0", let v = int64Value, v >= -JSONNumber.maxSafeInteger,
      v <= JSONNumber.maxSafeInteger
    else { return nil }
    return v
  }

  /// 2^53 - 1, JavaScript's `Number.MAX_SAFE_INTEGER`.
  public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

  static func isNumberLiteral(_ u: [UInt8]) -> Bool {
    var i = 0
    let n = u.count
    func digits() -> Int {
      let start = i
      while i < n, ASCII.isDigit(u[i]) { i += 1 }
      return i - start
    }
    if i < n, u[i] == 0x2d { i += 1 }
    guard i < n else { return false }
    if u[i] == 0x30 {
      i += 1
    } else if digits() == 0 {
      return false
    }
    if i < n, u[i] == 0x2e {
      i += 1
      guard digits() > 0 else { return false }
    }
    if i < n, u[i] == 0x65 || u[i] == 0x45 {
      i += 1
      if i < n, u[i] == 0x2b || u[i] == 0x2d { i += 1 }
      guard digits() > 0 else { return false }
    }
    return i == n
  }
}

/// An ordered JSON object. Keys are unique; insertion order is kept.
public struct JSONObject: Sendable, Hashable {
  public struct Member: Sendable, Hashable {
    public let key: String
    public var value: JSONValue

    public static func == (a: Member, b: Member) -> Bool { utf8Equal(a.key, b.key) && a.value == b.value }
    public func hash(into h: inout Hasher) {
      h.combine(Array(key.utf8))
      h.combine(value)
    }
  }

  public private(set) var members: [Member]
  /// Position of each key, by its UTF-8 bytes (a `String` key would hash by
  /// canonical equivalence and merge NFC and NFD spellings).
  private var positions: [[UInt8]: Int]

  public init() {
    members = []
    positions = [:]
  }

  /// Builds an object from pairs in order. A repeated key is last-wins at its
  /// first position, as `JSON.parse` and a JavaScript object literal do.
  public init(_ pairs: [(String, JSONValue)]) {
    self.init()
    members.reserveCapacity(pairs.count)
    for (k, v) in pairs { self[k] = v }
  }

  public var count: Int { members.count }
  public var keys: [String] { members.map(\.key) }

  /// The value for `key` (compared by UTF-8 bytes, never canonical equivalence),
  /// or `nil` when absent. Setting `nil` removes the key; setting a present key
  /// replaces its value in place.
  public subscript(key: String) -> JSONValue? {
    get { index(of: key).map { members[$0].value } }
    set {
      let k = Array(key.utf8)
      if let i = positions[k] {
        if let v = newValue {
          members[i].value = v
        } else {
          members.remove(at: i)
          positions[k] = nil
          for j in i..<members.count { positions[Array(members[j].key.utf8)] = j }
        }
      } else if let v = newValue {
        positions[k] = members.count
        members.append(Member(key: key, value: v))
      }
    }
  }

  private func index(of key: String) -> Int? { positions[Array(key.utf8)] }

  // Identity is the ordered members; the position index is derived.
  public static func == (a: JSONObject, b: JSONObject) -> Bool { a.members == b.members }
  public func hash(into h: inout Hasher) { h.combine(members) }
}

extension JSONValue {
  public var objectValue: JSONObject? { if case .object(let o) = self { o } else { nil } }
  public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
  public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
  public var numberValue: JSONNumber? { if case .number(let n) = self { n } else { nil } }
  public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
  public var isNull: Bool { if case .null = self { true } else { false } }

  /// Member lookup on an object; `nil` for a non-object or an absent key.
  public subscript(key: String) -> JSONValue? { objectValue?[key] }

  /// A copy with every object's keys sorted by UTF-8 bytes, recursively: the
  /// key order of replay/state.ts `canonical()` (`serializeState`). Array order
  /// is kept.
  public func sortingKeysByUTF8() -> JSONValue {
    switch self {
    case .array(let a): return .array(a.map { $0.sortingKeysByUTF8() })
    case .object(let o):
      let sorted = o.members.sorted { compareUTF8($0.key, $1.key) < 0 }
      return .object(JSONObject(sorted.map { ($0.key, $0.value.sortingKeysByUTF8()) }))
    default: return self
    }
  }
}
