// CoreMoney unit tests: the 03c §1.3 grammars and base vectors 01, 02, 07 and
// 08 (spec 03c "Test vectors"), and the PWA's minorMoney.test.ts and
// flowBars.test.ts `compactMinor` cases, ported.
import Testing

@testable import CoreMoney

@Suite("grammars (03c §1.3)")
struct GrammarTests {
  @Test("base-01: Minor accepts 0, 1, Int64.max; refuses 00, -0, 2^63, 1.0")
  func minor() throws {
    #expect(try Minor(wire: "0").value == 0)
    #expect(try Minor(wire: "1").value == 1)
    #expect(try Minor(wire: "9223372036854775807").value == .max)
    #expect(throws: MoneyError.grammar) { try Minor(wire: "00") }
    #expect(throws: MoneyError.grammar) { try Minor(wire: "007") }
    #expect(throws: MoneyError.grammar) { try Minor(wire: "-0") }
    #expect(throws: MoneyError.grammar) { try Minor(wire: "-1") }
    #expect(throws: MoneyError.exceedsInt64) { try Minor(wire: "9223372036854775808") }
    #expect(throws: MoneyError.grammar) { try Minor(wire: "92233720368547758070") }
    for bad in ["1.0", "", " 1", "1 ", "+1", "1e3", "١", "1\n", "0x1"] {
      #expect(throws: MoneyError.grammar) { try Minor(wire: bad) }
    }
    #expect(Minor(-1) == nil && Minor(0)?.wire == "0")
  }

  @Test("PositiveMinor refuses zero")
  func positive() throws {
    #expect(try PositiveMinor(wire: "1").value == 1)
    #expect(throws: MoneyError.outOfRange) { try PositiveMinor(wire: "0") }
    #expect(PositiveMinor(0) == nil)
  }

  @Test("base-02: SignedMinor is symmetric and never Int64.min")
  func signed() throws {
    #expect(try SignedMinor(wire: "-9223372036854775807").value == -.max)
    #expect(try SignedMinor(wire: "9223372036854775807").value == .max)
    #expect(try SignedMinor(wire: "-1").value == -1)
    #expect(throws: MoneyError.outOfRange) { try SignedMinor(wire: "-9223372036854775808") }
    #expect(throws: MoneyError.exceedsInt64) { try SignedMinor(wire: "-9223372036854775809") }
    #expect(throws: MoneyError.grammar) { try SignedMinor(wire: "-0") }
    #expect(throws: MoneyError.grammar) { try SignedMinor(wire: "--1") }
    #expect(throws: MoneyError.grammar) { try SignedMinor(wire: "-01") }
    #expect(SignedMinor(.min) == nil)
  }

  @Test("v3 fields keep ^[0-9]+$ (leading zeros allowed) plus the Int64 cap")
  func v3() throws {
    #expect(try MoneyGrammar.parseV3("25000") == 25000)
    #expect(try MoneyGrammar.parseV3("007") == 7)
    #expect(try MoneyGrammar.parseV3("0000") == 0)
    #expect(try MoneyGrammar.parseV3("0009223372036854775807") == .max)
    #expect(throws: MoneyError.exceedsInt64) { try MoneyGrammar.parseV3("9223372036854775808") }
    #expect(throws: MoneyError.exceedsInt64) { try MoneyGrammar.parseV3("90071992547409930000") }
    #expect(throws: MoneyError.grammar) { try MoneyGrammar.parseV3("") }
    #expect(throws: MoneyError.grammar) { try MoneyGrammar.parseV3("-1") }
  }

  @Test("CurrencyCode is three upper-case ASCII letters; exponents follow table v1")
  func currency() {
    #expect(CurrencyCode("AED") != nil && CurrencyCode("aed") == nil && CurrencyCode("AE") == nil)
    #expect(CurrencyCode("AEDX") == nil && CurrencyCode("ÄED") == nil)
    #expect(MinorExponent.v1(.aed) == 2)
    #expect(MinorExponent.v1(CurrencyCode("KWD")!) == 3)
    #expect(MinorExponent.v1(CurrencyCode("JPY")!) == 0)
    #expect(MinorExponent.v1(CurrencyCode("XYZ")!) == 2)
  }
}

@Suite("checked arithmetic")
struct MathTests {
  @Test("overflow is an answer, never a trap")
  func overflow() {
    #expect(MoneyMath.add(.max, 1) == nil && MoneyMath.add(1, 2) == 3)
    #expect(MoneyMath.subtract(.min, 1) == nil)
    #expect(MoneyMath.multiply(.max, 2) == nil && MoneyMath.multiply(3, 4) == 12)
    #expect(MoneyMath.sum([.max, 1, -1]) == .max)  // the partial sum overflows, the total does not
    #expect(MoneyMath.sum([.max, .max]) == nil)
    #expect(MoneyMath.wideSum([.max, .max]) == Int128(Int64.max) * 2)
  }

  @Test("base-07: apportion by cumulative floor; shares sum to the home total")
  func apportion() {
    #expect(MoneyMath.apportion(home: 34215, parts: [29700, 4515]) == [29700, 4515])
    let shares = MoneyMath.apportion(home: 34215, parts: [10000, 2000])!
    #expect(shares == [28512, 5703])
    #expect(shares.reduce(0, +) == 34215)
    let thirds = MoneyMath.apportion(home: 100, parts: [1, 1, 1])!
    #expect(thirds == [33, 33, 34])
    #expect(MoneyMath.apportion(home: nil, parts: [1]) == nil)
    #expect(MoneyMath.apportion(home: 5, parts: []) == nil)
    #expect(MoneyMath.apportion(home: 5, parts: [0, 0]) == nil)
    let big = MoneyMath.apportion(home: .max, parts: [.max, 1])!
    #expect(big.reduce(Int128(0)) { $0 + Int128($1) } == Int128(Int64.max))
  }

  @Test("base-08: percent change, half-up, nil on a zero base")
  func pctChange() {
    #expect(MoneyMath.pctChange(64275, 54470) == 18)
    #expect(MoneyMath.pctChange(54470, 64275) == -15)
    #expect(MoneyMath.pctChange(1, 0) == nil)
    #expect(MoneyMath.pctChange(201, 200) == 1)  // 0.5% rounds up
    #expect(MoneyMath.pctChange(199, 200) == -1)  // and away from zero
    #expect(MoneyMath.pctChange(200, 200) == 0)
    #expect(MoneyMath.pctChange(.max, 1) == nil)  // ~9.2e20 percent does not fit
    #expect(MoneyMath.pctChange(-50, -100) == 50)
  }
}

@Suite("display and entry (lib/minorMoney.ts, compactMinor)")
struct FormatTests {
  @Test("formatMinor groups and pads; negatives use U+2212; exact past 2^53")
  func formatMinor() {
    #expect(MoneyFormat.formatMinor(0) == "0.00")
    #expect(MoneyFormat.formatMinor(5) == "0.05")
    #expect(MoneyFormat.formatMinor(123_456) == "1,234.56")
    #expect(MoneyFormat.formatMinor(-123_456) == "\u{2212}1,234.56")
    #expect(MoneyFormat.formatMinor(9_007_199_254_740_993) == "90,071,992,547,409.93")
    #expect(MoneyFormat.formatMinor(.max) == "92,233,720,368,547,758.07")
    #expect(MoneyFormat.formatMinor(.min) == "\u{2212}92,233,720,368,547,758.08")
    #expect(MoneyFormat.formatMinor(1_234_567, exponent: 3) == "1,234.567")
    #expect(MoneyFormat.formatMinor(1_234_567, exponent: 0) == "1,234,567")
  }

  @Test("formatMoney and signedMinor")
  func formatMoney() {
    #expect(MoneyFormat.formatMoney(123_456, currency: "AED") == "AED 1,234.56")
    #expect(MoneyFormat.formatMoney(123_456, currency: "") == "1,234.56")
    #expect(MoneyFormat.signedMinor(.debit, 2450) == ("\u{2212}24.50", .out))
    #expect(MoneyFormat.signedMinor(.credit, 500_000) == ("+5,000.00", .in))
    #expect(MoneyFormat.signedMinor(.unparsed, 0) == ("\u{2014}", .none))
  }

  @Test("parseMinorDraft: empty is not zero; exact; refuses rather than rewrites")
  func parse() {
    #expect(MoneyFormat.parseMinorDraft("") == .empty)
    #expect(MoneyFormat.parseMinorDraft("   ") == .empty)
    #expect(MoneyFormat.parseMinorDraft("\u{FEFF}\u{3000}") == .empty)
    #expect(MoneyFormat.parseMinorDraft("0") == .amount(0))
    #expect(MoneyFormat.parseMinorDraft("12000") == .amount(1_200_000))
    #expect(MoneyFormat.parseMinorDraft("8500.5") == .amount(850_050))
    #expect(MoneyFormat.parseMinorDraft("8500.50") == .amount(850_050))
    #expect(MoneyFormat.parseMinorDraft("0.05") == .amount(5))
    #expect(MoneyFormat.parseMinorDraft("12.") == .amount(1_200))
    #expect(MoneyFormat.parseMinorDraft(" 12.5 ") == .amount(1_250))
    #expect(MoneyFormat.parseMinorDraft("007") == .amount(700))
    #expect(MoneyFormat.parseMinorDraft("90071992547409.93") == .amount(9_007_199_254_740_993))
    #expect(MoneyFormat.parseMinorDraft("92233720368547758.07") == .amount(.max))
    #expect(MoneyFormat.parseMinorDraft("92233720368547758.08") == .refused(.tooLarge))
    #expect(MoneyFormat.parseMinorDraft("99999999999999999999999") == .refused(.tooLarge))
    #expect(MoneyFormat.parseMinorDraft("12.345") == .refused(.tooPrecise))
    #expect(MoneyFormat.parseMinorDraft("-100") == .refused(.negative))
    #expect(MoneyFormat.parseMinorDraft("\u{2212}100") == .refused(.negative))
    for text in ["12,000", "1e6", "abc", "12.3.4", "AED 12", "0x10", ".", ".5", "+5", "١٢", "12 000"] {
      #expect(MoneyFormat.parseMinorDraft(text) == .refused(.notAnAmount))
    }
    #expect(MoneyFormat.parseMinorDraft("1.234", exponent: 3) == .amount(1_234))
    #expect(MoneyFormat.parseMinorDraft("12.5", exponent: 0) == .refused(.tooPrecise))
  }

  @Test("minorToDraft is the inverse of parseMinorDraft")
  func draft() {
    #expect(MoneyFormat.minorToDraft(1_200_000) == "12000.00")
    #expect(MoneyFormat.minorToDraft(5) == "0.05")
    #expect(MoneyFormat.minorToDraft(0) == "0.00")
    #expect(MoneyFormat.minorToDraft(nil) == "")
    #expect(MoneyFormat.minorToDraft(-5) == "-0.05")
    #expect(MoneyFormat.minorToDraft(9_007_199_254_740_993) == "90071992547409.93")
    for minor: Int64 in [0, 5, 1_200_000, 9_007_199_254_740_993, .max] {
      #expect(MoneyFormat.parseMinorDraft(MoneyFormat.minorToDraft(minor)) == .amount(minor))
    }
  }

  @Test("compactMinor (flowBars.test.ts)")
  func compact() {
    #expect(MoneyFormat.compactMinor(82_000) == "+820")
    #expect(MoneyFormat.compactMinor(-14_000) == "\u{2212}140")
    #expect(MoneyFormat.compactMinor(120_000) == "+1.2k")
    #expect(MoneyFormat.compactMinor(2_100_000) == "+21k")
    #expect(MoneyFormat.compactMinor(-350_000) == "\u{2212}3.5k")
    #expect(MoneyFormat.compactMinor(150_000_000) == "+1.5m")
    #expect(MoneyFormat.compactMinor(0) == "0")
    #expect(MoneyFormat.compactMinor(9_007_199_254_740_993) == "+90071992.5m")
    #expect(MoneyFormat.compactMinor(.max) == "+92233720368.5m")
    #expect(MoneyFormat.compactMinor(.min) == "\u{2212}92233720368.5m")
  }
}
