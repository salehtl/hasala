import HasalaMocks
import HasalaModels
import Testing

// Money formatting, phrases and permille (frozen after Stage F).

@Suite("Money formatting")
struct MoneyFormatTests {
  @Test(arguments: [
    (Int64(0), "0.00"), (5, "0.05"), (99, "0.99"), (100, "1.00"), (7_417_55, "7,417.55"),
    (227_568_00, "227,568.00"), (1_000_000_00, "1,000,000.00"), (-4_210_50, "4,210.50"),
  ])
  func exact(minor: Int64, expected: String) {
    #expect(MoneyFormat.string(minor, style: .exact) == expected)
  }

  @Test(arguments: [(Int64(12_350_00), "12,350"), (9_040_80, "9,040.80"), (5_000_00, "5,000"), (1, "0.01")])
  func compact(minor: Int64, expected: String) {
    #expect(MoneyFormat.string(minor, style: .compact) == expected)
  }

  @Test(arguments: [(Int64(337_16), "337"), (337_50, "338"), (337_49, "337"), (-2_140_00, "2,140"), (49, "0")])
  func rounded(minor: Int64, expected: String) {
    #expect(MoneyFormat.string(minor, style: .rounded) == expected)
  }

  @Test func hiddenGlyphs() {
    #expect(MoneyFormat.hidden() == "••••")
    #expect(MoneyFormat.hidden(count: 6) == "••••••")
    #expect(MoneyFormat.hidden(count: 0) == "•")
  }

  @Test func phrasesHideOnlyTheFigures() {
    let p = MoneyPhrase([.text("AED "), .amount(.aed(827_28)), .text(" isn't in your plan yet")])
    #expect(p.rendered(hidden: false) == "AED 827.28 isn't in your plan yet")
    #expect(p.rendered(hidden: true) == "AED •••• isn't in your plan yet")
    #expect(p.spoken(hidden: true) == "AED Amount hidden isn't in your plan yet")
    let change = MoneyPhrase([.signedMoney(.aed(2_140_00), style: .rounded, hiddenGlyphs: 3), .text(" this month")])
    #expect(change.rendered(hidden: false) == "+2,140 this month")
    #expect(change.rendered(hidden: true) == "••• this month")
    let debt = MoneyPhrase([.signedMoney(.aed(-4_210_50), style: .exact, hiddenGlyphs: 4)])
    #expect(debt.rendered(hidden: false) == "\u{2212}4,210.50")
  }

  @Test func permille() {
    #expect(Permille.ratio(1, of: 0).value == 0)
    #expect(Permille.ratio(-5, of: 100).value == 0)
    #expect(Permille.ratio(9_040_80, of: 12_350_00).value == 732)
  }
}
