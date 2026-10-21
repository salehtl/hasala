// A strict RFC 8259 parser producing `JSONValue`, with the observable behaviour
// of `JSON.parse` on the text `TextDecoder` produces (wire/op.ts `parseBody`):
//
//   - bytes are decoded WHATWG-style first: one leading BOM stripped, invalid
//     UTF-8 replaced by U+FFFD (inside a string that is data; outside one it is
//     a syntax error, as in JavaScript);
//   - whitespace is exactly space, tab, LF and CR;
//   - escapes are `\" \\ \/ \b \f \n \r \t \uXXXX` (hex in either case); a
//     `\uXXXX` pair forming a surrogate pair is combined, and a LONE surrogate
//     becomes U+FFFD, or is refused with `refuseLoneSurrogates`. JavaScript
//     keeps a lone surrogate in the string, keeps such keys distinct and writes
//     the escape back out, so this is a divergence; op and raw bodies refuse
//     them (wire/op.ts `parseBody`) and the witness never carries one;
//   - raw control characters U+0000-U+001F inside a string are refused;
//   - numbers keep their literal; duplicate keys are last-wins.
//
// Errors carry a coarse reason and a byte offset only, never parser prose or
// input content: callers report `"<what>: body is not valid JSON (<n> bytes)"`
// and nothing more, because the text can reach materialized state.
import HasalaText

public enum JSONParseError: Error, Equatable, Sendable {
  case syntax(offset: Int)
  /// Nesting deeper than the parser's limit.
  case tooDeep(limit: Int)
}

public enum JSONParser {
  /// The nesting limit. JavaScript engines allow far deeper documents; nothing
  /// on the wire nests beyond a handful of levels. The bound exists because
  /// releasing a `JSONValue` is recursive (Swift tears an indirect value down
  /// level by level), and a hostile document a few hundred levels deep
  /// overflows the 512 KiB stack of a secondary thread when it is freed.
  /// Measured on macOS 26: 2000 levels crash a Swift Testing worker when freed,
  /// 512 do not; 128 leaves a wide margin.
  /// Documented divergence from JSON.parse, which would accept it.
  public static let defaultMaxDepth = 128

  /// Parses UTF-8 `bytes` (WHATWG-decoded first: BOM stripped, invalid
  /// sequences replaced).
  public static func parse(
    _ bytes: some Collection<UInt8>, maxDepth: Int = defaultMaxDepth, refuseLoneSurrogates: Bool = false
  ) throws(JSONParseError) -> JSONValue {
    var start = bytes.startIndex
    if bytes.starts(with: [0xef, 0xbb, 0xbf]) { start = bytes.index(start, offsetBy: 3) }
    // Re-encoding through String repairs invalid UTF-8 exactly as WHATWG does.
    let text = String(decoding: bytes[start...], as: UTF8.self)
    return try parse(text: text, maxDepth: maxDepth, refuseLoneSurrogates: refuseLoneSurrogates)
  }

  /// Parses `text` as `JSON.parse` would (no BOM handling: a leading U+FEFF is
  /// not JSON whitespace).
  public static func parse(
    text: String, maxDepth: Int = defaultMaxDepth, refuseLoneSurrogates: Bool = false
  ) throws(JSONParseError) -> JSONValue {
    var p = Parser(bytes: Array(text.utf8), maxDepth: maxDepth, refuseLoneSurrogates: refuseLoneSurrogates)
    p.skipWhitespace()
    let v = try p.document()
    p.skipWhitespace()
    guard p.i == p.u.count else { throw .syntax(offset: p.i) }
    return v
  }
}

private struct Parser {
  let u: [UInt8]
  let maxDepth: Int
  let refuseLoneSurrogates: Bool
  var i = 0

  init(bytes: [UInt8], maxDepth: Int, refuseLoneSurrogates: Bool) {
    u = bytes
    self.maxDepth = maxDepth
    self.refuseLoneSurrogates = refuseLoneSurrogates
  }

  mutating func skipWhitespace() {
    while i < u.count, u[i] == 0x20 || u[i] == 0x09 || u[i] == 0x0a || u[i] == 0x0d { i += 1 }
  }

  func fail() -> JSONParseError { .syntax(offset: i) }

  /// One open container on the explicit stack. The parser is iterative so a
  /// deeply nested document costs heap, not stack: test runners and
  /// background work run on threads with small stacks.
  struct Frame {
    var isObject: Bool
    var items: [JSONValue] = []
    var object = JSONObject()
    var key = ""
  }

  mutating func document() throws(JSONParseError) -> JSONValue {
    var stack: [Frame] = []
    while true {
      // Parse the start of one value: a scalar, an empty container, or the
      // opening of a non-empty one (pushed, then its first value is parsed).
      skipWhitespace()
      guard i < u.count else { throw fail() }
      var produced: JSONValue
      switch u[i] {
      case 0x7b, 0x5b:
        let isObject = u[i] == 0x7b
        guard stack.count < maxDepth else { throw .tooDeep(limit: maxDepth) }
        i += 1
        skipWhitespace()
        if i < u.count, u[i] == (isObject ? 0x7d : 0x5d) {
          i += 1
          produced = isObject ? .object(JSONObject()) : .array([])
        } else {
          var frame = Frame(isObject: isObject)
          if isObject { frame.key = try memberKey() }
          stack.append(frame)
          continue
        }
      case 0x22: produced = .string(try string())
      case 0x74:
        try literal("true")
        produced = .bool(true)
      case 0x66:
        try literal("false")
        produced = .bool(false)
      case 0x6e:
        try literal("null")
        produced = .null
      case 0x2d, 0x30...0x39: produced = .number(try number())
      default: throw fail()
      }

      // Attach the finished value to its container, closing every container
      // that ends here, until one expects another value (or the root is done).
      while true {
        guard !stack.isEmpty else { return produced }
        let top = stack.count - 1
        if stack[top].isObject {
          stack[top].object[stack[top].key] = produced
        } else {
          stack[top].items.append(produced)
        }
        skipWhitespace()
        guard i < u.count else { throw fail() }
        if u[i] == 0x2c {
          i += 1
          if stack[top].isObject {
            skipWhitespace()
            stack[top].key = try memberKey()
          }
          break
        }
        guard u[i] == (stack[top].isObject ? 0x7d : 0x5d) else { throw fail() }
        i += 1
        let done = stack.removeLast()
        produced = done.isObject ? .object(done.object) : .array(done.items)
      }
    }
  }

  /// `"key"` then `:` (whitespace allowed around the colon).
  mutating func memberKey() throws(JSONParseError) -> String {
    guard i < u.count, u[i] == 0x22 else { throw fail() }
    let key = try string()
    skipWhitespace()
    guard i < u.count, u[i] == 0x3a else { throw fail() }
    i += 1
    return key
  }

  mutating func literal(_ word: StaticString) throws(JSONParseError) {
    let w = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
    guard i + w.count <= u.count, u[i..<(i + w.count)].elementsEqual(w) else { throw fail() }
    i += w.count
  }

  mutating func number() throws(JSONParseError) -> JSONNumber {
    let start = i
    if u[i] == 0x2d { i += 1 }
    guard i < u.count else { throw fail() }
    if u[i] == 0x30 {
      i += 1
    } else if ASCII.isDigit(u[i]) {
      while i < u.count, ASCII.isDigit(u[i]) { i += 1 }
    } else {
      throw fail()
    }
    if i < u.count, u[i] == 0x2e {
      i += 1
      let d = i
      while i < u.count, ASCII.isDigit(u[i]) { i += 1 }
      guard i > d else { throw fail() }
    }
    if i < u.count, u[i] == 0x65 || u[i] == 0x45 {
      i += 1
      if i < u.count, u[i] == 0x2b || u[i] == 0x2d { i += 1 }
      let d = i
      while i < u.count, ASCII.isDigit(u[i]) { i += 1 }
      guard i > d else { throw fail() }
    }
    return JSONNumber(validated: String(decoding: u[start..<i], as: UTF8.self))
  }

  mutating func string() throws(JSONParseError) -> String {
    i += 1  // opening quote
    var out = [UInt8]()
    while true {
      guard i < u.count else { throw fail() }
      let c = u[i]
      switch c {
      case 0x22:
        i += 1
        return String(decoding: out, as: UTF8.self)
      case 0x5c:
        i += 1
        guard i < u.count else { throw fail() }
        let e = u[i]
        i += 1
        switch e {
        case 0x22: out.append(0x22)
        case 0x5c: out.append(0x5c)
        case 0x2f: out.append(0x2f)
        case 0x62: out.append(0x08)
        case 0x66: out.append(0x0c)
        case 0x6e: out.append(0x0a)
        case 0x72: out.append(0x0d)
        case 0x74: out.append(0x09)
        case 0x75: appendScalar(try unicodeEscape(), to: &out)
        default:
          i -= 1
          throw fail()
        }
      case 0x00...0x1f:
        throw fail()
      default:
        out.append(c)
        i += 1
      }
    }
  }

  /// After `\u`: one escape, or a surrogate pair written as two. A lone
  /// surrogate (either half) becomes U+FFFD; a high surrogate followed by
  /// anything but a low-surrogate escape leaves that next escape unconsumed.
  mutating func unicodeEscape() throws(JSONParseError) -> UInt32 {
    let first = try hex4()
    switch first {
    case 0xd800...0xdbff:
      if i + 6 <= u.count, u[i] == 0x5c, u[i + 1] == 0x75 {
        let save = i
        i += 2
        let second = try hex4()
        if (0xdc00...0xdfff).contains(second) {
          return 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
        }
        i = save
      }
      if refuseLoneSurrogates { throw fail() }
      return 0xfffd
    case 0xdc00...0xdfff:
      if refuseLoneSurrogates { throw fail() }
      return 0xfffd
    default:
      return first
    }
  }

  mutating func hex4() throws(JSONParseError) -> UInt32 {
    guard i + 4 <= u.count else { throw fail() }
    var v: UInt32 = 0
    for _ in 0..<4 {
      let c = u[i]
      let d: UInt32
      switch c {
      case 0x30...0x39: d = UInt32(c - 0x30)
      case 0x41...0x46: d = UInt32(c - 0x41 + 10)
      case 0x61...0x66: d = UInt32(c - 0x61 + 10)
      default: throw fail()
      }
      v = v << 4 | d
      i += 1
    }
    return v
  }

  func appendScalar(_ v: UInt32, to out: inout [UInt8]) {
    let s = Unicode.Scalar(v) ?? "\u{FFFD}"
    out.append(contentsOf: UTF8.encode(s)!)
  }
}
