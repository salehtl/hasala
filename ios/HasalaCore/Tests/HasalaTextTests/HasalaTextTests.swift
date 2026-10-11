// HasalaText unit tests. The Go-verdict tables for whitespace and lower-casing
// run against conformance/dict/matching.json in HasalaCoreConformanceTests.
import Testing

@testable import HasalaText

@Suite("scalar sets and trims")
struct ScalarSetTests {
  @Test("Go's IsSpace has exactly 25 members; NEL in, BOM out")
  func goSpace() {
    #expect(ScalarSet.goSpace.members.count == 25)
    #expect(ScalarSet.goSpace.contains(0x85))
    #expect(!ScalarSet.goSpace.contains(0xfeff))
    #expect(!ScalarSet.goSpace.contains(0x200b))  // ZWSP is not White_Space
  }

  @Test("each named trim removes only its own set, only at the edges")
  func trims() {
    #expect(" \t a b \n".trimming(.asciiSpace) == "a b")
    #expect("\u{A0}x\u{A0}".trimming(.asciiSpace) == "\u{A0}x\u{A0}")
    #expect("\u{A0}\u{FEFF}x\u{FEFF}".trimming(.unwrapTrim) == "x")
    #expect(" \tx \n".trimming(.spaceTab) == "x \n")
    #expect("\u{85}x\u{85}".trimmingGoSpace == "x")
    #expect("\u{FEFF}x".trimmingGoSpace == "\u{FEFF}x")
    #expect("\u{FEFF}\u{2028} x \u{3000}".trimming(.jsTrim) == "x")
    #expect("\u{85}x".trimming(.jsTrim) == "\u{85}x")  // NEL is not JS whitespace
    #expect("".trimming(.goSpace) == "" && "   ".trimming(.goSpace) == "")
  }

  @Test("collapse: Go's strings.Fields joined by one space")
  func collapse() {
    #expect("  CARREFOUR   Hyper ".collapsingGoSpace == "CARREFOUR Hyper")
    #expect("a\u{85}b\u{3000}\u{2028}c".collapsingGoSpace == "a b c")
    #expect("a\u{FEFF}b".collapsingGoSpace == "a\u{FEFF}b")
    #expect(" \t ".collapsingGoSpace == "")
  }

  @Test("the forbidden set is the fixed 03c §1.6 list")
  func forbidden() {
    for v: UInt32 in [0x00, 0x1f, 0x7f, 0x80, 0x9f, 0x2028, 0x2029, 0x202a, 0x202e, 0x2066, 0x2069, 0xfeff, 0xfffe, 0xffff] {
      #expect(ScalarSet.forbidden.contains(v))
    }
    for v: UInt32 in [0x20, 0x41, 0x200e, 0x200f, 0x061c, 0xa0, 0x202f, 0x206a] {
      #expect(!ScalarSet.forbidden.contains(v))
    }
    #expect(ScalarSet.forbidden.members.count == 32 + 1 + 32 + 2 + 5 + 4 + 3)
  }
}

@Suite("ordering and counting")
struct CompareTests {
  @Test("UTF-8 byte order, not canonical equivalence and not UTF-16 order")
  func utf8Order() {
    #expect(compareUTF8("a", "b") < 0 && compareUTF8("b", "a") > 0 && compareUTF8("a", "a") == 0)
    #expect(compareUTF8("a", "ab") < 0 && compareUTF8("", "a") < 0)
    // U+1F600 sorts ABOVE U+E000 in UTF-8 and scalar order, below it in UTF-16.
    #expect(compareUTF8("\u{1F600}", "\u{E000}") > 0)
    #expect(compareScalars("\u{1F600}", "\u{E000}") > 0)
    // NFC "é" and NFD "e\u{301}" are == as Swift Strings, different as bytes.
    let nfc = "\u{E9}"
    let nfd = "e\u{301}"
    #expect(nfc == nfd)
    #expect(!utf8Equal(nfc, nfd))
    #expect(compareUTF8(nfc, nfd) != 0)
    #expect(compareUTF8(nfd, nfc) == -compareUTF8(nfc, nfd))
  }

  @Test("scalar and UTF-8 order agree on a mixed sample")
  func ordersAgree() {
    let sample = ["", "a", "B", "é", "e\u{301}", "\u{FFFF}", "\u{10000}", "\u{E000}", "ي", "z", "\u{7F}", "\u{80}"]
    for a in sample {
      for b in sample { #expect(compareUTF8(a, b).signum() == compareScalars(a, b).signum()) }
    }
  }

  @Test("runes are scalars: a flag is two, an e plus combining accent is two")
  func runes() {
    #expect(runeCount("\u{1F1E6}\u{1F1EA}") == 2)
    #expect(runeCount("e\u{301}") == 2)
    #expect(truncateRunes("\u{1F1E6}\u{1F1EA}x", 1) == "\u{1F1E6}")
    #expect(truncateRunes("abc", 10) == "abc" && truncateRunes("abc", 0) == "")
  }

  @Test("ASCII helpers never apply Unicode case mapping")
  func ascii() {
    #expect(ASCII.lowercased("ABC İ Σ") == "abc İ Σ")
    #expect(ASCII.uppercased("abc ı ß") == "ABC ı ß")
    #expect(ASCII.isDecimal("0123") && !ASCII.isDecimal("") && !ASCII.isDecimal("12\n") && !ASCII.isDecimal("١٢"))
    #expect(ASCII.isLowerHex("00ff", count: 4) && !ASCII.isLowerHex("00FF", count: 4))
  }

  @Test("Go's simple lower case: one scalar per scalar, no Final_Sigma context")
  func goLower() {
    #expect(GoCase.lower("CARREFOUR") == "carrefour")
    #expect(GoCase.lower("\u{130}") == "i")  // JavaScript gives "i\u{307}"
    #expect(GoCase.lower("ΟΔΟΣ") == "οδοσ")  // JavaScript gives a final ς
    #expect(GoCase.lower("مرحبا") == "مرحبا")
  }
}

@Suite("Label, Note, Token (03c §1.6)")
struct TextRuleTests {
  @Test("Label bounds, forbidden scalars and edge space")
  func label() {
    #expect(TextRules.checkLabel("Groceries") == nil)
    #expect(TextRules.checkLabel("بقالة\u{200F}") == nil)  // RLM allowed
    #expect(TextRules.checkLabel("") == .empty)
    #expect(TextRules.checkLabel(String(repeating: "a", count: 64)) == nil)
    #expect(TextRules.checkLabel(String(repeating: "a", count: 65)) == .tooManyScalars(max: 64))
    #expect(TextRules.checkLabel(String(repeating: "ب", count: 64)) == nil)  // 128 bytes
    // 64 four-byte scalars are exactly 256 bytes: the byte bound never binds
    // before the scalar bound, and both are checked anyway.
    #expect(TextRules.checkLabel(String(repeating: "\u{1F600}", count: 64)) == nil)
    #expect(TextRules.checkLabel("a\u{2028}b") == .forbiddenScalar(0x2028))
    #expect(TextRules.checkLabel("a\nb") == .forbiddenScalar(0x0a))
    #expect(TextRules.checkLabel(" a") == .edgeSpace)
    #expect(TextRules.checkLabel("a\u{3000}") == .edgeSpace)
    #expect(TextRules.checkLabel("a b") == nil)
  }

  @Test("Note allows LF and the empty string, nothing else forbidden")
  func note() {
    #expect(TextRules.checkNote("") == nil)
    #expect(TextRules.checkNote("line one\nline two") == nil)
    #expect(TextRules.checkNote("tab\there") == .forbiddenScalar(0x09))
    #expect(TextRules.checkNote(String(repeating: "x", count: 500)) == nil)
    #expect(TextRules.checkNote(String(repeating: "x", count: 501)) == .tooManyScalars(max: 500))
    #expect(TextRules.checkNote(String(repeating: "\u{1F600}", count: 500)) == nil)  // exactly 2000 bytes
  }

  @Test("Token grammar over bytes", arguments: [
    ("groceries", true), ("a", true), ("c_01ja3s0a2b4c", true), (String(repeating: "a", count: 32), true),
    (String(repeating: "a", count: 33), false), ("", false), ("1abc", false), ("Abc", false), ("ab-c", false),
    ("abc\n", false), ("ab c", false), ("é", false),
  ])
  func token(_ s: String, _ ok: Bool) {
    #expect(TextRules.isToken(s) == ok)
  }
}
