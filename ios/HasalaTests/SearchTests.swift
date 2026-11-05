import CoreCategorize
import HasalaMocks
import HasalaModel
import HasalaModels
import Testing

@testable import Hasala

/// Search's "Try asking" offers only the rows whose word finds something in this iPhone's
/// own ledger (what a query finds is `ActivityReviewModelTests`'s).
@MainActor
@Suite("Search")
struct SearchTests {
  @Test func tryAskingOffersOnlyRowsThatFindSomething() {
    let store = InMemoryLedger()
    let all = SearchView.suggestions(in: store.state, now: store.now).map(\.term)
    #expect(all == ["dining", "rent", "carrefour"])

    var noCarrefour = store.state
    noCarrefour.txns.removeAll { $0.merchant.localizedCaseInsensitiveContains("carrefour") }
    noCarrefour.rules.removeAll { r in r.patterns.contains { $0.localizedCaseInsensitiveContains("carrefour") } }
    #expect(SearchView.suggestions(in: noCarrefour, now: store.now).map(\.term) == ["dining", "rent"])

    var empty = store.state
    empty.txns = []
    empty.rules = []
    empty.categories = []
    #expect(SearchView.suggestions(in: empty, now: store.now).isEmpty)
  }

  @Test func tryAskingOnlyAsksWhatSearchCanAnswer() {
    let questions = SearchView.suggestions.map(\.question)
    #expect(!questions.contains { $0.lowercased().hasPrefix("when") })
    #expect(questions.contains("How much on rent this year?"))
    #expect(SearchView.suggestions.first { $0.question == "How much on rent this year?" }?.term == "rent")
  }

  @Test func promptAndTitleFollowTheModel() {
    #expect(SearchView.prompt(available: true) == "Ask about your money")
    #expect(SearchView.prompt(available: false) == "Search merchants and categories")
    #expect(SearchView.readyTitle(available: true) == "Try asking")
    #expect(SearchView.readyTitle(available: false) == "Try searching")
  }

  @Test func resultsCarryTheirProject() {
    let store = InMemoryLedger()
    let found = SearchResults("Emirates", store.state, now: store.now)
    #expect(found.rows.first { $0.id == "emirates" }?.project == MiniTxnRow.Project(id: "japan", name: "Japan trip"))
    #expect(SearchResults("Carrefour", store.state, now: store.now).rows.allSatisfy { $0.project == nil })
  }

  @Test func aQuestionWithoutTheModelFallsBackToTheNamesInIt() {
    let store = InMemoryLedger()
    let q = "how much at carrefour in september"
    #expect(SearchResults(q, store.state, now: store.now).isEmpty)
    let off = SearchResults.find(q, store.state, now: store.now, aliases: [], keywordFallback: false)
    #expect(off.isEmpty)
    let found = SearchResults.find(q, store.state, now: store.now, aliases: [], keywordFallback: true)
    #expect(found.shownFor == ["Carrefour"])
    #expect(Set(found.rows.map(\.id)).isSuperset(of: ["carrefour", "carrefour-sep26", "carrefour-sep13"]))
    #expect(found.activityText(for: q) == "Carrefour")
    #expect(SearchResults.shownForLine(found.shownFor) == "Showing results for \u{2068}Carrefour\u{2069}")

    let dining = SearchResults.find("dining last week", store.state, now: store.now, aliases: [], keywordFallback: true)
    #expect(dining.shownFor == ["Dining"])
    #expect(dining.categories.map(\.id) == ["dining"])

    let joke = SearchResults.find("tell me a joke", store.state, now: store.now, aliases: [], keywordFallback: true)
    #expect(joke.isEmpty && joke.shownFor.isEmpty)
  }

  @Test func noMatchesSaysWhyAndIsolatesTheQuery() {
    let ar = "\u{0643}\u{0627}\u{0631}\u{0641}\u{0648}\u{0631}"
    let plain = SearchView.nothingFoundCopy(ar, reason: nil)
    #expect(plain.title == "No matches for “\u{2068}\(ar)\u{2069}”")
    #expect(plain.body == "Try a merchant name or a category. Bank alerts usually spell merchant names in English.")
    let off = SearchView.nothingFoundCopy("coffee last month", reason: .unavailable(.notEligible))
    #expect(off.body == "Questions need Apple Intelligence on this iPhone. Try a merchant name or a category.")
    #expect(SearchView.nothingFoundCopy("x y", reason: .nothingUnderstood).body == plain.body)
  }

  @Test func arabicNamesFindTheirDictionaryMerchant() {
    let store = InMemoryLedger()
    let entries = [
      DictEntry(pattern: "\u{0643}\u{0627}\u{0631}\u{0641}\u{0648}\u{0631}", match: "contains", category: "groceries",
                display: "Carrefour"),
      DictEntry(pattern: "\u{0637}\u{0644}\u{0628}\u{0627}\u{062A}", match: "contains", category: "dining", display: "talabat"),
      DictEntry(pattern: "carrefour", match: "contains", category: "groceries", display: "Carrefour"),
    ]
    let carrefour = "\u{0643}\u{0627}\u{0631}\u{0641}\u{0648}\u{0631}"
    #expect(ArabicAlias.names(for: carrefour, entries) == ["Carrefour"])
    #expect(ArabicAlias.names(for: "\u{0643}\u{0627}\u{0631}\u{0641}", entries) == ["Carrefour"])
    #expect(ArabicAlias.names(for: "carrefour", entries).isEmpty)
    #expect(ArabicAlias.names(for: "\u{0643}", entries).isEmpty)
    #expect(ArabicAlias.names(for: "\u{0645}\u{0643}\u{062A}\u{0628}\u{0629}", entries).isEmpty)
    #expect(ArabicAlias.fold("\u{0645}\u{0643}\u{062A}\u{0628}\u{0629}") == ArabicAlias.fold("\u{0645}\u{0643}\u{062A}\u{0628}\u{0647}"))
    #expect(ArabicAlias.fold("\u{0645}\u{0633}\u{062A}\u{0634}\u{0641}\u{0649}") == ArabicAlias.fold("\u{0645}\u{0633}\u{062A}\u{0634}\u{0641}\u{064A}"))

    #expect(SearchResults(carrefour, store.state, now: store.now).isEmpty)
    let found = SearchResults.find(carrefour, store.state, now: store.now, aliases: entries, keywordFallback: false)
    #expect(found.shownFor == ["Carrefour"])
    #expect(found.rows.map(\.id).contains("carrefour"))
    #expect(found.activityText(for: carrefour) == "Carrefour")

    let unknown = "\u{0645}\u{0643}\u{062A}\u{0628}\u{0629}"
    #expect(SearchResults.find(unknown, store.state, now: store.now, aliases: entries, keywordFallback: true).isEmpty)
  }

  @Test func theBundledDictionaryCarriesArabicAliases() {
    #expect(ArabicAlias.names(for: "\u{0643}\u{0627}\u{0631}\u{0641}\u{0648}\u{0631}", ArabicAlias.bundled) == ["Carrefour"])
  }

  @Test func topResultSumsTheMerchantsRowsInFils() throws {
    let store = InMemoryLedger()
    let found = SearchResults("carre", store.state, now: store.now)
    let top = try #require(found.top)
    let s = TopResultSummary(top, in: found.rows)
    #expect(s.merchant == "Carrefour")
    #expect(s.count == 3)
    #expect(s.total == .aed(1_031_95))
    #expect(s.line(hidden: false) == "3 transactions · 1,031.95")
    #expect(s.line(hidden: true) == "3 transactions · •••")
  }

  @Test func topResultShowsOnlyTheCountWhenRowsDoNotAddUp() {
    func row(_ id: String, _ m: Money, income: Bool = false, notCounted: Bool = false, estimate: Bool = false) -> MiniTxnRow {
      var r = MiniTxnRow(id: id, merchant: "Shop", glyph: .shopping, hue: .other, detail: "", amount: m, isIncome: income)
      r.notCounted = notCounted
      r.estimate = estimate
      return r
    }
    let one = TopResultSummary(row("a", .aed(10_00)), in: [row("a", .aed(10_00))])
    #expect(one.line(hidden: false) == "1 transaction · 10.00")
    let mixedCurrency = [row("a", .aed(10_00)), row("b", Money(minor: 5_00, currency: "USD"))]
    #expect(TopResultSummary(mixedCurrency[0], in: mixedCurrency).line(hidden: false) == "2 transactions")
    let mixedDirection = [row("a", .aed(10_00)), row("b", .aed(5_00), income: true)]
    #expect(TopResultSummary(mixedDirection[0], in: mixedDirection).total == nil)
    let notCounted = [row("a", .aed(10_00)), row("b", .aed(5_00), notCounted: true)]
    #expect(TopResultSummary(notCounted[0], in: notCounted).line(hidden: false) == "2 transactions")
    let estimated = [row("a", .aed(10_00)), row("b", .aed(5_25), estimate: true)]
    #expect(TopResultSummary(estimated[0], in: estimated).line(hidden: false) == "2 transactions · \u{2248} 15.25")
    let income = [row("a", .aed(10_00), income: true), row("b", .aed(5_00), income: true)]
    #expect(TopResultSummary(income[0], in: income).line(hidden: false) == "2 transactions · +15.00")
    let usd = [row("a", Money(minor: 5_00, currency: "USD"))]
    #expect(TopResultSummary(usd[0], in: usd).line(hidden: false) == "1 transaction · USD 5.00")
    let other = [row("a", .aed(10_00)), MiniTxnRow(id: "z", merchant: "Other", glyph: .shopping, hue: .other, detail: "",
                                                     amount: .aed(99_00))]
    #expect(TopResultSummary(other[0], in: other).count == 1)
  }

  @Test func seeAllInActivityCountsWhatSearchFound() {
    let store = InMemoryLedger()
    let found = SearchResults("carre", store.state, now: store.now)
    #expect(found.activityText(for: "carre") == "carre")
    #expect(SearchResults.seeAllLabel(found.rows.count) == "See all \(found.rows.count) in Activity")
  }
}
