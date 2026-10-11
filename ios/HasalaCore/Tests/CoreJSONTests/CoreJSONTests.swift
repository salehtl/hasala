// CoreJSON unit tests. Expected writer output in the `.javascript` style was
// produced by `JSON.stringify(JSON.parse(literal))` under Bun (the reference
// runtime), so the tables are the oracle's answers, not hand-derived ones.
import Testing

@testable import CoreJSON

private func parse(_ s: String) throws -> JSONValue { try JSONParser.parse(text: s) }
private func js(_ v: JSONValue) -> String { JSONWriter().string(v) }

@Suite("parser")
struct ParserTests {
  @Test("number literals are kept exactly as written")
  func literals() throws {
    for lit in ["0", "-0", "1.0", "1e0", "1E+2", "-12.5e-3", "9007199254740993", "123456789012345678901234567890"] {
      #expect(try parse(lit) == .number(JSONNumber(literal: lit)!))
      #expect(try parse("[\(lit)]").arrayValue?.first?.numberValue?.literal == lit)
    }
  }

  @Test("integer views: v4 Int refuses 1.0, 1e0, -0 and past 2^53")
  func integers() throws {
    func n(_ s: String) -> JSONNumber { JSONNumber(literal: s)! }
    #expect(n("42").v4Int == 42 && n("-42").v4Int == -42)
    #expect(n("1.0").v4Int == nil && n("1e0").v4Int == nil && n("-0").v4Int == nil)
    #expect(n("9007199254740991").v4Int == 9_007_199_254_740_991)
    #expect(n("9007199254740992").v4Int == nil && n("-9007199254740992").v4Int == nil)
    #expect(n("9223372036854775807").int64Value == .max && n("9223372036854775808").int64Value == nil)
    #expect(n("-0").int64Value == 0 && n("1.5").int64Value == nil)
    #expect(n("1.0").isIntegerLiteral == false && n("-7").isIntegerLiteral)
  }

  @Test("RFC 8259 grammar is enforced", arguments: [
    "", " ", "01", "1.", ".5", "+1", "-", "1e", "1e+", "0x10", "NaN", "Infinity", "-Infinity", "tru", "nul",
    "[1,]", "{\"a\":1,}", "{'a':1}", "{a:1}", "[1 2]", "{\"a\" 1}", "\"abc", "\"\\x\"", "\"\\u12\"",
    "\"\\uZZZZ\"", "\"a\u{01}b\"", "\"a\nb\"", "[1]]", "{} {}", "// c\n1", "\u{A0}1", "\u{0B}1", "\u{0C}1",
    "\u{FEFF}1", "[\"\\uD800\\uZZZZ\"]",
  ])
  func refusals(_ text: String) {
    #expect(throws: JSONParseError.self) { try parse(text) }
  }

  @Test("JSON whitespace is space, tab, LF and CR only")
  func whitespace() throws {
    #expect(try parse(" \t\n\r[ 1 ,\t2\r\n] ") == .array([.number(JSONNumber(1)), .number(JSONNumber(2))]))
  }

  @Test("duplicate keys are last-wins at the first position, as JSON.parse")
  func duplicates() throws {
    let v = try parse(#"{"a":1,"b":2,"a":3}"#)
    #expect(v.objectValue?.keys == ["a", "b"])
    #expect(v["a"] == .number(JSONNumber(3)))
    #expect(js(v) == #"{"a":3,"b":2}"#)
  }

  @Test("escapes, surrogate pairs, and lone surrogates becoming U+FFFD")
  func escapes() throws {
    #expect(try parse(#""\"\\\/\b\f\n\r\t""#) == .string("\"\\/\u{08}\u{0C}\n\r\t"))
    #expect(try parse(#""\u00e9\u00E9""#) == .string("éé"))
    #expect(try parse(#""\uD83D\uDE00""#) == .string("\u{1F600}"))
    #expect(try parse(#""\uD800""#) == .string("\u{FFFD}"))
    #expect(try parse(#""\uDC00x""#) == .string("\u{FFFD}x"))
    #expect(try parse(#""\uD800\u0041""#) == .string("\u{FFFD}A"))
    #expect(try parse(#""\uD800\uD800\uDC00""#) == .string("\u{FFFD}\u{10000}"))
    #expect(try parse(#""\uDE00\uD83D""#) == .string("\u{FFFD}\u{FFFD}"))
    #expect(try parse(#""\u0000""#) == .string("\u{0}"))
  }

  @Test("bytes: one BOM stripped, invalid UTF-8 replaced inside strings, refused outside")
  func bytes() throws {
    #expect(try JSONParser.parse([0xef, 0xbb, 0xbf] + Array("{}".utf8)) == .object(JSONObject()))
    #expect(throws: JSONParseError.self) { try JSONParser.parse([0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf] + Array("{}".utf8)) }
    #expect(try JSONParser.parse([0x22, 0x61, 0xff, 0x62, 0x22]) == .string("a\u{FFFD}b"))
    #expect(throws: JSONParseError.self) { try JSONParser.parse([0x5b, 0xff, 0x5d]) }
  }

  @Test("nesting is bounded")
  func depth() throws {
    let ok = String(repeating: "[", count: 128) + String(repeating: "]", count: 128)
    _ = try parse(ok)
    let deep = String(repeating: "[", count: 129) + String(repeating: "]", count: 129)
    #expect(throws: JSONParseError.tooDeep(limit: 128)) { try parse(deep) }
    // Refused before it is built, however deep: no stack is spent on it.
    let hostile = String(repeating: "[", count: 1_000_000)
    #expect(throws: JSONParseError.tooDeep(limit: 128)) { try parse(hostile) }
    #expect(throws: JSONParseError.tooDeep(limit: 2)) { try JSONParser.parse(text: "[[[1]]]", maxDepth: 2) }
  }

  @Test("1 and true stay distinct; null is not absent")
  func types() throws {
    let v = try parse(#"{"a":1,"b":true,"c":null}"#)
    #expect(v["a"]?.numberValue != nil && v["a"]?.boolValue == nil)
    #expect(v["b"]?.boolValue == true)
    #expect(v["c"]?.isNull == true && v["d"] == nil)
  }

  @Test("equality is by bytes: NFC and NFD strings differ")
  func byteEquality() {
    #expect(JSONValue.string("\u{E9}") != .string("e\u{301}"))
    #expect(JSONObject([("\u{E9}", .null), ("e\u{301}", .null)]).count == 2)
  }
}

@Suite("writer")
struct WriterTests {
  @Test("JSON.stringify's escaping: controls escaped, / < > & U+2028 U+2029 DEL literal")
  func escaping() {
    let s = "\"\\\u{08}\u{0C}\n\r\t\u{01}\u{1F}/<>&\u{2028}\u{2029}\u{7F}\u{80}é\u{1F600}"
    #expect(js(.string(s)) == "\"\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f/<>&\u{2028}\u{2029}\u{7F}\u{80}é\u{1F600}\"")
  }

  @Test("JavaScript key order: array indices first, ascending, then insertion order")
  func keyOrder() throws {
    let v = try parse(#"{"b":1,"1":2,"0":3,"a":4,"4294967295":5,"01":6,"4294967294":7,"-1":8}"#)
    #expect(js(v) == #"{"0":3,"1":2,"4294967294":7,"b":1,"a":4,"4294967295":5,"01":6,"-1":8}"#)
    #expect(
      JSONWriter(keyOrder: .insertion).string(v) == #"{"b":1,"1":2,"0":3,"a":4,"4294967295":5,"01":6,"4294967294":7,"-1":8}"#)
  }

  // (literal, JSON.stringify(JSON.parse(literal))) as Bun prints them.
  static let numbers: [(String, String)] = [
    ("1.50", "1.5"), ("1e2", "100"), ("-0", "0"), ("0.0", "0"), ("1e21", "1e+21"), ("1e-7", "1e-7"),
    ("123456789012345678901", "123456789012345680000"), ("0.000001", "0.000001"), ("1.5e-7", "1.5e-7"),
    ("9007199254740993", "9007199254740992"), ("1e400", "null"), ("-1e400", "null"), ("5e-324", "5e-324"),
    ("1.7976931348623157e308", "1.7976931348623157e+308"), ("0.1", "0.1"), ("100", "100"), ("-12.5e3", "-12500"),
    ("1e-6", "0.000001"), ("1.2e-6", "0.0000012"), ("1e20", "100000000000000000000"), ("2.5e-5", "0.000025"),
    ("0.30000000000000004", "0.30000000000000004"), ("123e-20", "1.23e-18"), ("-0.0000001", "-1e-7"),
    ("4.35", "4.35"), ("1e+0", "1"), ("12345678901234567890", "12345678901234567000"), ("0.1e1", "1"),
    ("1E2", "100"),
  ]

  @Test("numbers: .javascript renders a JavaScript Number; .literal keeps the text", arguments: numbers)
  func numberStyles(_ literal: String, _ expected: String) throws {
    let v = try parse(literal)
    #expect(js(v) == expected)
    #expect(JSONWriter(numbers: .literal).string(v) == literal)
  }

  @Test("compact output with no whitespace; round trip is value-stable")
  func compact() throws {
    let text = #"{ "v" : 1 , "ops" : [ { "a" : [ ] , "b" : { } , "c" : null , "d" : false } ] }"#
    let v = try parse(text)
    #expect(js(v) == #"{"v":1,"ops":[{"a":[],"b":{},"c":null,"d":false}]}"#)
    #expect(try parse(js(v)) == v)
  }

  @Test("sorting keys by UTF-8 bytes (serializeState's canonical order), recursively")
  func sortedKeys() throws {
    let v = try parse(#"{"b":{"z":1,"é":2,"e":3},"a":[{"y":1,"x":2}],"B":0}"#)
    #expect(js(v.sortingKeysByUTF8()) == #"{"B":0,"a":[{"x":2,"y":1}],"b":{"e":3,"z":1,"é":2}}"#)
  }
}
