import CoreCategorize
import Foundation
import Testing

@testable import HasalaModel

final class StubSearchModel: SearchQueryModel, @unchecked Sendable {
  let state: ModelAvailability
  let answer: SearchModelAnswer
  private let lock = NSLock()
  private var asked: [String] = []

  init(_ answer: SearchModelAnswer, availability: ModelAvailability = .available) {
    self.answer = answer
    self.state = availability
  }

  var queries: [String] { lock.withLock { asked } }

  func availability() -> ModelAvailability { state }

  func interpret(_ query: String, vocabulary: SearchVocabulary) async -> SearchModelAnswer {
    lock.withLock { asked.append(query) }
    return answer
  }
}

@Suite("Search query parser")
struct SearchQueryParserTests {
  let vocabulary = SearchVocabulary(
    today: "Saturday 10 October 2026",
    categories: [.init(id: "groceries", name: "Groceries"), .init(id: "dining", name: "Dining")],
    merchants: ["Carrefour", "Starbucks", "Common Grounds", "carrefour"])

  @Test func carrefourInSeptember() async {
    let stub = StubSearchModel(.reply(SearchModelReply(
      merchants: ["carrefour"], period: .month, month: 9, flow: .spent, asksTotal: true)))
    let r = await SearchQueryParser(model: stub).parse(
      "How much did I spend at Carrefour in September?", vocabulary: vocabulary)
    #expect(r == .intent(SearchIntent(merchants: ["Carrefour"], period: .month, month: 9, flow: .spent, asksTotal: true)))
    #expect(stub.queries == ["How much did I spend at Carrefour in September?"])
  }

  @Test func coffeeKeepsListedMerchantsOnly() {
    let i = SearchQueryParser.intent(
      SearchModelReply(merchants: ["Starbucks", "coffee", "Common Grounds", "STARBUCKS"], period: .lastMonth),
      vocabulary: vocabulary)
    #expect(i.merchants == ["Starbucks", "Common Grounds"])
    #expect(i.period == .lastMonth)
  }

  @Test func unlistedMerchantIsKeptAsTyped() {
    let i = SearchQueryParser.intent(SearchModelReply(merchants: [" Waitrose ", "x"]), vocabulary: vocabulary)
    #expect(i.merchants == ["Waitrose"])
  }

  @Test func vocabularyDropsDuplicateMerchants() {
    #expect(vocabulary.merchants == ["Carrefour", "Starbucks", "Common Grounds"])
    let many = SearchVocabulary(today: "", categories: [], merchants: (0..<200).map { "m\($0)" })
    #expect(many.merchants.count == SearchVocabulary.merchantLimit)
  }

  @Test func categoryByIdOrNameOnly() {
    #expect(SearchQueryParser.intent(SearchModelReply(category: "dining"), vocabulary: vocabulary).category == "dining")
    #expect(SearchQueryParser.intent(SearchModelReply(category: "Groceries"), vocabulary: vocabulary).category == "groceries")
    #expect(SearchQueryParser.intent(SearchModelReply(category: "coffee"), vocabulary: vocabulary).category == nil)
  }

  @Test func amountsBecomeFils() {
    #expect(SearchQueryParser.fils("50") == 5_000)
    #expect(SearchQueryParser.fils("12.5") == 1_250)
    #expect(SearchQueryParser.fils("12.50") == 1_250)
    #expect(SearchQueryParser.fils("AED 1,250.75") == 125_075)
    #expect(SearchQueryParser.fils("dhs 7") == 700)
    #expect(SearchQueryParser.fils("12.505") == nil)
    #expect(SearchQueryParser.fils("-5") == nil)
    #expect(SearchQueryParser.fils("1e3") == nil)
    #expect(SearchQueryParser.fils("") == nil)
    #expect(SearchQueryParser.fils("٥٠") == nil)
    #expect(SearchQueryParser.fils("9999999999") == nil)
  }

  @Test func swappedRangeIsOrdered() {
    let i = SearchQueryParser.intent(SearchModelReply(minimumAmount: "200", maximumAmount: "50"), vocabulary: vocabulary)
    #expect(i.minimumFils == 5_000 && i.maximumFils == 20_000)
  }

  @Test func incompletePeriodsAreDropped() {
    #expect(SearchQueryParser.intent(SearchModelReply(period: .month), vocabulary: vocabulary).period == .any)
    #expect(SearchQueryParser.intent(SearchModelReply(period: .month, month: 13), vocabulary: vocabulary).period == .any)
    #expect(SearchQueryParser.intent(SearchModelReply(period: .lastDays, days: 0), vocabulary: vocabulary).period == .any)
    let i = SearchQueryParser.intent(SearchModelReply(period: .lastDays, month: 3, days: 7), vocabulary: vocabulary)
    #expect(i.period == .lastDays && i.days == 7 && i.month == nil)
  }

  @Test func arabicNeverReachesTheModel() async {
    let stub = StubSearchModel(.reply(SearchModelReply(merchants: ["Carrefour"])))
    let parser = SearchQueryParser(model: stub)
    #expect(await parser.parse("كم صرفت في كارفور", vocabulary: vocabulary) == .keywordsOnly(.script))
    #expect(await parser.parse("carrefour كارفور", vocabulary: vocabulary) == .keywordsOnly(.script))
    #expect(stub.queries.isEmpty)
    #expect(!SearchQueryParser.accepts("كارفور"))
    #expect(SearchQueryParser.accepts("coffee last month"))
    #expect(SearchQueryParser.accepts("what’s my spend at Zuma?"))
  }

  @Test func unavailableModelFallsBack() async {
    for a in [ModelAvailability.notEligible, .notEnabled, .notReady, .unsupportedLanguage] {
      let stub = StubSearchModel(.reply(SearchModelReply(merchants: ["Carrefour"])), availability: a)
      #expect(await SearchQueryParser(model: stub).parse("carrefour last week", vocabulary: vocabulary)
        == .keywordsOnly(.unavailable(a)))
      #expect(stub.queries.isEmpty)
    }
    let none = SearchQueryParser(model: UnavailableSearchQueryModel())
    #expect(!none.isAvailable)
  }

  @Test func failuresAndEmptyRepliesFallBack() async {
    let failed = SearchQueryParser(model: StubSearchModel(.failed(.guardrail)))
    #expect(await failed.parse("carrefour last week", vocabulary: vocabulary) == .keywordsOnly(.failed(.guardrail)))
    let empty = SearchQueryParser(model: StubSearchModel(.reply(SearchModelReply(asksTotal: true))))
    #expect(await empty.parse("tell me something", vocabulary: vocabulary) == .keywordsOnly(.nothingUnderstood))
  }

  @Test func liveRepliesAreGroundedInTheQuery() {
    let v = SearchVocabulary(
      today: "Saturday 10 October 2026",
      categories: [
        .init(id: "groceries", name: "Groceries"), .init(id: "dining", name: "Dining"),
        .init(id: "transport", name: "Transport"), .init(id: "salary", name: "Salary"),
      ],
      merchants: ["Carrefour", "Talabat", "Starbucks", "Common Grounds", "Careem", "Waitrose", "Spinneys", "ENOC",
                  "IKEA", "Lulu Hypermarket", "Netflix"])
    func g(_ q: String, _ r: SearchModelReply) -> SearchIntent { SearchQueryParser.intent(r, vocabulary: v, query: q) }

    #expect(g("coffee last month", SearchModelReply(
      merchants: ["Starbucks"], category: "dining", minimumAmount: "0", maximumAmount: "0", period: .lastMonth,
      flow: .spent, asksTotal: true))
      == SearchIntent(merchants: ["Starbucks"], period: .lastMonth, flow: .spent, asksTotal: true))

    #expect(g("how much did I spend at Carrefour in September", SearchModelReply(
      merchants: ["Carrefour"], period: .month, month: 9, year: 2026, flow: .spent, asksTotal: true))
      == SearchIntent(merchants: ["Carrefour"], period: .month, month: 9, flow: .spent, asksTotal: true))

    #expect(g("groceries over 250 this month", SearchModelReply(
      merchants: ["Carrefour", "Talabat", "Waitrose", "Spinneys", "ENOC", "IKEA", "Lulu Hypermarket"],
      category: "groceries", minimumAmount: "250", maximumAmount: "250", period: .thisMonth, flow: .spent,
      asksTotal: true))
      == SearchIntent(category: "groceries", minimumFils: 25_000, period: .thisMonth, flow: .spent, asksTotal: true))

    #expect(g("taxi rides in the past 7 days", SearchModelReply(
      merchants: ["Careem"], period: .lastWeek, flow: .spent, asksTotal: true))
      == SearchIntent(merchants: ["Careem"], period: .lastDays, days: 7, flow: .spent, asksTotal: true))

    #expect(g("salary this year", SearchModelReply(
      merchants: ["salary"], period: .thisYear, flow: .received, asksTotal: true))
      == SearchIntent(category: "salary", period: .thisYear, flow: .received, asksTotal: true))

    #expect(g("dining under 50 last week", SearchModelReply(
      merchants: ["dining"], category: "dining", minimumAmount: "0", maximumAmount: "50", period: .lastWeek,
      flow: .spent, asksTotal: true))
      == SearchIntent(category: "dining", maximumFils: 5_000, period: .lastWeek, flow: .spent, asksTotal: true))

    #expect(g("netflix", SearchModelReply(merchants: ["Netflix"], period: .today, flow: .spent, asksTotal: true))
      == SearchIntent(merchants: ["Netflix"], flow: .spent, asksTotal: true))
  }

  @Test func boundsFollowTheWords() {
    func g(_ q: String, _ r: SearchModelReply) -> SearchIntent { SearchQueryParser.intent(r, vocabulary: vocabulary, query: q) }
    let under = g("carrefour under 100", SearchModelReply(merchants: ["Carrefour"], minimumAmount: "100"))
    #expect(under.minimumFils == nil && under.maximumFils == 10_000)
    let over = g("carrefour more than 100", SearchModelReply(merchants: ["Carrefour"], maximumAmount: "100"))
    #expect(over.minimumFils == 10_000 && over.maximumFils == nil)
    let between = g("carrefour between 50 and 200", SearchModelReply(
      merchants: ["Carrefour"], minimumAmount: "50", maximumAmount: "200"))
    #expect(between.minimumFils == 5_000 && between.maximumFils == 20_000)
    let noDigits = g("big carrefour shops", SearchModelReply(merchants: ["Carrefour"], minimumAmount: "500"))
    #expect(noDigits.minimumFils == nil)
    #expect(g("carrefour in march 2025", SearchModelReply(merchants: ["Carrefour"], period: .month, month: 3, year: 2025)).year == 2025)
    #expect(g("carrefour last 30 days", SearchModelReply(merchants: ["Carrefour"], period: .lastMonth)).days == 30)
  }

  @Test func instructionsCarryTheVocabulary() {
    let text = SearchQueryParser.instructions(vocabulary)
    #expect(text.contains("Today is Saturday 10 October 2026."))
    #expect(text.contains("- groceries: Groceries"))
    #expect(text.contains("Merchants: Carrefour, Starbucks, Common Grounds"))
  }

  @Test func factoryMakesASearchModel() {
    let a = HasalaModelFactory.makeSearch().availability()
    #expect([.available, .notEligible, .notEnabled, .notReady, .unsupportedLanguage].contains(a))
  }
}

@Suite("Search query parser, live model", .enabled(if: ProcessInfo.processInfo.environment["HASALA_LIVE_MODEL"] == "1"))
struct LiveSearchQueryParserTests {
  @Test func examples() async {
    let v = SearchVocabulary(
      today: "Saturday 10 October 2026",
      categories: [
        .init(id: "groceries", name: "Groceries"), .init(id: "dining", name: "Dining"),
        .init(id: "transport", name: "Transport"), .init(id: "shopping", name: "Shopping"),
        .init(id: "subscriptions", name: "Subscriptions"), .init(id: "rent", name: "Rent"),
        .init(id: "salary", name: "Salary"),
      ],
      merchants: ["Carrefour", "Talabat", "Starbucks", "Common Grounds", "Zuma", "Careem", "Noon", "Waitrose",
                  "Spinneys", "Netflix", "Spotify", "ENOC", "IKEA", "Lulu Hypermarket"])
    let parser = SearchQueryParser(model: HasalaModelFactory.makeSearch())
    guard parser.isAvailable else {
      print("live model: \(parser.model.availability())")
      return
    }
    for q in [
      "coffee last month", "how much did I spend at Carrefour in September", "groceries over 250 this month",
      "taxi rides in the past 7 days", "salary this year", "dining under 50 last week", "netflix",
    ] {
      print("live model: \(q) -> \(await parser.parse(q, vocabulary: v))")
    }
  }
}
