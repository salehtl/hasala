import Testing

@testable import HasalaModels

@Suite("Category icon guess")
struct CategoryIconGuessTests {
  @Test func everyGuessIsAnIconTheEditorOffers() {
    for entry in CategoryIconGuess.table { #expect(CategoryLimits.glyphs.contains(entry.glyph), "\(entry.glyph)") }
    #expect(CategoryLimits.glyphs.contains(CategoryIconGuess.fallback))
    #expect(CategoryIconGuess.fallback == .tag)
  }

  @Test func englishNames() {
    #expect(CategoryIconGuess.glyph(for: "Coffee") == .dining)
    #expect(CategoryIconGuess.glyph(for: "  coffee shops ") == .dining)
    #expect(CategoryIconGuess.glyph(for: "CAFÉ") == .dining)
    #expect(CategoryIconGuess.glyph(for: "Groceries") == .groceries)
    #expect(CategoryIconGuess.glyph(for: "Flights") == .travel)
    #expect(CategoryIconGuess.glyph(for: "Car") == .transport)
    #expect(CategoryIconGuess.glyph(for: "Car loan") == .debt)
    #expect(CategoryIconGuess.glyph(for: "Car insurance") == .insurance)
    #expect(CategoryIconGuess.glyph(for: "Gym membership") == .subscriptions)
    #expect(CategoryIconGuess.glyph(for: "Home internet") == .utilities)
    #expect(CategoryIconGuess.glyph(for: "Emergency fund") == .savingsJar)
    #expect(CategoryIconGuess.glyph(for: "Gifts") == .shopping)
  }

  @Test func arabicNames() {
    #expect(CategoryIconGuess.glyph(for: "قهوة") == .dining)
    #expect(CategoryIconGuess.glyph(for: "القهوة") == .dining)
    #expect(CategoryIconGuess.glyph(for: "قَهْوَة") == .dining)
    #expect(CategoryIconGuess.glyph(for: "إيجار") == .rent)
    #expect(CategoryIconGuess.glyph(for: "ايجار البيت") == .rent)
    #expect(CategoryIconGuess.glyph(for: "الكهرباء") == .utilities)
    #expect(CategoryIconGuess.glyph(for: "ألعاب") == .entertainment)
    #expect(CategoryIconGuess.glyph(for: "الألعاب") == .entertainment)
    #expect(CategoryIconGuess.glyph(for: "سفر") == .travel)
    #expect(CategoryIconGuess.glyph(for: "هدايا") == .shopping)
  }

  @Test func pluralsAndArabicPrefixes() {
    #expect(CategoryIconGuess.glyph(for: "Pharmacies") == .healthcare)
    #expect(CategoryIconGuess.glyph(for: "Utility bills") == .utilities)
    #expect(CategoryIconGuess.glyph(for: "Lunches") == .dining)
    #expect(CategoryIconGuess.glyph(for: "Buses") == .transport)
    #expect(CategoryIconGuess.glyph(for: "للسيارة") == .transport)
    #expect(CategoryIconGuess.glyph(for: "بالسيارة") == .transport)
    #expect(CategoryIconGuess.glyph(for: "والبيت") == .rent)
    #expect(CategoryIconGuess.glyph(for: "للبيت") == .rent)
    #expect(CategoryIconGuess.glyph(for: "لعشاء") == .dining)
    #expect(CategoryIconGuess.glyph(for: "وقود") == .transport)
    #expect(CategoryIconGuess.glyph(for: "Cares") == .tag)
    #expect(CategoryIconGuess.glyph(for: "Rates") == .tag)
    #expect(CategoryIconGuess.glyph(for: "Bills") == .tag)
  }

  @Test func anUnknownOrEmptyNameKeepsTheTag() {
    #expect(CategoryIconGuess.glyph(for: "") == .tag)
    #expect(CategoryIconGuess.glyph(for: "   ") == .tag)
    #expect(CategoryIconGuess.glyph(for: "Kids") == .tag)
    #expect(CategoryIconGuess.glyph(for: "Netflix") == .tag)
    #expect(CategoryIconGuess.glyph(for: "أطفال") == .tag)
  }
}
