// The canonical writer: `JSON.stringify` over a `JSONValue`, byte for byte.
//
// This is the encoder the TypeScript op codec uses (wire/op.ts
// `encodeBlobOps`, `encodeRawBody`; replay/state.ts `serializeState`): no
// whitespace, keys in the object's order, and JSON.stringify's escaping:
// `"` and `\` escaped, `\b \f \n \r \t` by name, every other C0 control as
// lower-case `\u00XX`, and EVERYTHING ELSE LITERAL, including `/`, `<`, `>`, `&`,
// DEL, U+2028 and U+2029. (Go's `encoding/json` escapes `<`, `>`, `&`, U+2028 and
// U+2029, which is why Go-encoded bytes are only value-equal, never
// byte-equal, to these; client-core-a §3 hazard 2.)
//
// Two choices are JavaScript's and are on by default (`.javascript`):
//
//   - key order: a JavaScript object enumerates its array-index keys
//     (`"0"` ... `"4294967294"`, canonical decimal) first, ascending, then the
//     other keys in insertion order. `JSON.stringify(JSON.parse(text))` reorders
//     `{"b":1,"1":2}` to `{"1":2,"b":1}`; `.insertion` does not.
//   - numbers: JSON.stringify writes a JavaScript Number, so `1.50` becomes
//     `1.5`, `1e2` becomes `100`, `-0` becomes `0` and 2^53+1 becomes
//     9007199254740992. `.literal` writes the literal as parsed instead (spec
//     04 §2.2 "literal-preserving"), which is value-equal and exact.
import CoreText

public struct JSONWriter: Sendable {
  public enum NumberStyle: Sendable { case javascript, literal }
  public enum KeyOrder: Sendable { case javascript, insertion }

  public var numbers: NumberStyle
  public var keyOrder: KeyOrder

  public init(numbers: NumberStyle = .javascript, keyOrder: KeyOrder = .javascript) {
    self.numbers = numbers
    self.keyOrder = keyOrder
  }

  /// The UTF-8 bytes of `value`.
  public func bytes(_ value: JSONValue) -> [UInt8] {
    var out = [UInt8]()
    write(value, into: &out)
    return out
  }

  /// The text of `value`.
  public func string(_ value: JSONValue) -> String {
    String(decoding: bytes(value), as: UTF8.self)
  }

  private func write(_ v: JSONValue, into out: inout [UInt8]) {
    switch v {
    case .null: out += Array("null".utf8)
    case .bool(let b): out += Array((b ? "true" : "false").utf8)
    case .number(let n):
      switch numbers {
      case .literal: out += Array(n.literal.utf8)
      case .javascript: out += Array(JSNumber.stringify(literal: n.literal).utf8)
      }
    case .string(let s): JSONWriter.quote(s, into: &out)
    case .array(let a):
      out.append(0x5b)
      for (k, x) in a.enumerated() {
        if k > 0 { out.append(0x2c) }
        write(x, into: &out)
      }
      out.append(0x5d)
    case .object(let o):
      out.append(0x7b)
      var first = true
      for m in ordered(o.members) {
        if !first { out.append(0x2c) }
        first = false
        JSONWriter.quote(m.key, into: &out)
        out.append(0x3a)
        write(m.value, into: &out)
      }
      out.append(0x7d)
    }
  }

  private func ordered(_ members: [JSONObject.Member]) -> [JSONObject.Member] {
    guard keyOrder == .javascript else { return members }
    var indexed: [(UInt32, JSONObject.Member)] = []
    var named: [JSONObject.Member] = []
    for m in members {
      if let n = JSONWriter.arrayIndex(m.key) { indexed.append((n, m)) } else { named.append(m) }
    }
    if indexed.isEmpty { return members }
    return indexed.sorted { $0.0 < $1.0 }.map(\.1) + named
  }

  /// ECMAScript's array index: the canonical decimal string of an integer in
  /// `0 ... 2^32 - 2`.
  static func arrayIndex(_ key: String) -> UInt32? {
    let u = Array(key.utf8)
    guard !u.isEmpty, u.count <= 10, u.allSatisfy(ASCII.isDigit), u.count == 1 || u[0] != 0x30 else {
      return nil
    }
    var v: UInt64 = 0
    for d in u { v = v * 10 + UInt64(d - 0x30) }
    return v <= 4_294_967_294 ? UInt32(v) : nil
  }

  /// JSON.stringify's QuoteJSONString over a well-formed string.
  public static func quote(_ s: String, into out: inout [UInt8]) {
    out.append(0x22)
    for b in s.utf8 {
      switch b {
      case 0x22: out += [0x5c, 0x22]
      case 0x5c: out += [0x5c, 0x5c]
      case 0x08: out += [0x5c, 0x62]
      case 0x0c: out += [0x5c, 0x66]
      case 0x0a: out += [0x5c, 0x6e]
      case 0x0d: out += [0x5c, 0x72]
      case 0x09: out += [0x5c, 0x74]
      case 0x00...0x1f:
        let hex = Array("0123456789abcdef".utf8)
        out += [0x5c, 0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 0x0f)]]
      default: out.append(b)
      }
    }
    out.append(0x22)
  }
}

extension JSONValue {
  /// `JSON.stringify(self)` as UTF-8 bytes (JavaScript key order and numbers).
  public var jsonBytes: [UInt8] { JSONWriter().bytes(self) }
}
