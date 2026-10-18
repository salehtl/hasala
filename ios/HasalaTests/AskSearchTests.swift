import CoreCategorize
import HasalaMocks
import HasalaModel
import HasalaModels
import Testing

@testable import Hasala

struct CannedSearchModel: SearchQueryModel {
  var state: ModelAvailability = .available
  var replies: [String: SearchModelAnswer] = [:]

  func availability() -> ModelAvailability { state }

  func interpret(_ query: String, vocabulary: SearchVocabulary) async -> SearchModelAnswer {
    replies[query] ?? .reply(SearchModelReply())
  }
}

@MainActor
@Suite("Ask search")
struct AskSearchTests {
  let store = InMemoryLedger()

  func ask(_ q: String, _ reply: SearchModelReply) async -> AskAnswer? {
    let parser = SearchQueryParser(model: CannedSearchModel(replies: [q: .reply(reply)]))
    guard case .intent(let i) = await parser.parse(q, vocabulary: AskSearch.vocabulary(store.state, now: store.now))
    else { return nil }
    return AskSearch.answer(i, store.state, now: store.now)
  }

  @Test func carrefourInSeptember() async throws {
    let a = try #require(await ask(
      "How much did I spend at Carrefour in September?",
      SearchModelReply(merchants: ["Carrefour"], period: .month, month: 9, flow: .spent, asksTotal: true)))
    #expect(a.total == .aed(689_80))
    #expect(a.rows.map(\.id) == ["carrefour-sep26", "carrefour-sep13"])
    #expect(a.headline == "At Carrefour in September")
    #expect(a.scope.map(\.label) == ["Carrefour", "September", "Spent"])
    #expect(a.countLine == "2 transactions")
    #expect(!a.isIncome)
    #expect(a.activity == TxnFilter(text: "Carrefour"))
  }

  @Test func coffeeByMonth() async throws {
    let coffee = ["Starbucks", "Common Grounds"]
    let last = try #require(await ask("coffee last month", SearchModelReply(merchants: coffee, period: .lastMonth)))
    #expect(last.rows.isEmpty && last.total == .aed(0))
    #expect(last.headline == "At Starbucks and Common Grounds last month")
    let this = try #require(await ask("coffee this month", SearchModelReply(merchants: coffee, period: .thisMonth)))
    #expect(this.rows.map(\.id) == ["starbucks", "common-grounds"])
    #expect(this.total == .aed(108_00))
    #expect(this.activity == nil)
  }

  @Test func categoryThisMonth() async throws {
    let a = try #require(await ask(
      "How much on dining this month?", SearchModelReply(category: "dining", period: .thisMonth, flow: .spent)))
    #expect(a.total == .aed(642_75))
    #expect(a.rows.count == 5)
    #expect(a.headline == "Dining this month")
    #expect(a.activity == TxnFilter(category: "dining"))
  }

  @Test func amountRangeInFils() async throws {
    let a = try #require(await ask(
      "groceries over 250 this month",
      SearchModelReply(category: "groceries", minimumAmount: "250", period: .thisMonth)))
    #expect(a.rows.map(\.id) == ["carrefour", "waitrose"])
    #expect(a.total == .aed(597_00))
    #expect(a.headline == "Groceries over 250 this month")
    let under = try #require(await ask(
      "carrefour under 300.50", SearchModelReply(merchants: ["Carrefour"], maximumAmount: "300.50")))
    #expect(under.rows.map(\.id) == ["carrefour-sep26"])
    let exact = AskEngine.answer(store.state, filter: AskFilter(minimumFils: 342_15, maximumFils: 342_15))
    #expect(exact.rows.map(\.id) == ["carrefour"])
  }

  @Test func moneyIn() async throws {
    let a = try #require(await ask("money in this week", SearchModelReply(period: .thisWeek, flow: .received)))
    #expect(a.isIncome)
    #expect(a.rows.map(\.id) == ["transfer-in"])
    #expect(a.total == .aed(1_250_00))
    #expect(a.headline == "Money in this week")
  }

  @Test func periodsInTheLedgerClock() {
    let now = store.now
    func range(_ i: SearchIntent) -> (LocalDate, LocalDate)? {
      AskSearch.filter(i, now: now).period.map { ($0.from, $0.through) }
    }
    #expect(range(SearchIntent(period: .any)) == nil)
    #expect(range(SearchIntent(period: .today))! == (LocalDate(2026, 10, 10), LocalDate(2026, 10, 10)))
    #expect(range(SearchIntent(period: .yesterday))! == (LocalDate(2026, 10, 9), LocalDate(2026, 10, 9)))
    #expect(range(SearchIntent(period: .thisWeek))! == (LocalDate(2026, 10, 5), LocalDate(2026, 10, 10)))
    #expect(range(SearchIntent(period: .lastWeek))! == (LocalDate(2026, 9, 28), LocalDate(2026, 10, 4)))
    #expect(range(SearchIntent(period: .thisMonth))! == (LocalDate(2026, 10, 1), LocalDate(2026, 10, 10)))
    #expect(range(SearchIntent(period: .lastMonth))! == (LocalDate(2026, 9, 1), LocalDate(2026, 9, 30)))
    #expect(range(SearchIntent(period: .thisYear))! == (LocalDate(2026, 1, 1), LocalDate(2026, 10, 10)))
    #expect(range(SearchIntent(period: .lastYear))! == (LocalDate(2025, 1, 1), LocalDate(2025, 12, 31)))
    #expect(range(SearchIntent(period: .month, month: 2))! == (LocalDate(2026, 2, 1), LocalDate(2026, 2, 28)))
    #expect(range(SearchIntent(period: .month, month: 11))! == (LocalDate(2025, 11, 1), LocalDate(2025, 11, 30)))
    #expect(range(SearchIntent(period: .month, month: 2, year: 2024))! == (LocalDate(2024, 2, 1), LocalDate(2024, 2, 29)))
    #expect(range(SearchIntent(period: .lastDays, days: 7))! == (LocalDate(2026, 10, 4), LocalDate(2026, 10, 10)))
    #expect(AskSearch.filter(SearchIntent(period: .month, month: 11), now: now).period?.label == "November 2025")
    #expect(AskSearch.filter(SearchIntent(flow: .spent), now: now).direction == .out)
  }

  @Test func removingScopeRecomputesWithoutTheModel() async throws {
    let s = store.state, now = store.now
    let m = AskSearchModel(parser: SearchQueryParser(model: CannedSearchModel(replies: [
      "carrefour september": .reply(SearchModelReply(merchants: ["Carrefour"], period: .month, month: 9, flow: .spent)),
    ])))
    await m.run("carrefour september", s, now: now, debounce: .zero)
    #expect(m.answer(for: "carrefour september")?.total == .aed(689_80))
    m.remove(.period, s)
    let all = try #require(m.answer(for: "carrefour september"))
    #expect(all.total == .aed(1_031_95))
    #expect(all.scope.map(\.part) == [.merchant("Carrefour"), .direction])
    #expect(all.headline == "At Carrefour")
    m.remove(.merchant("Carrefour"), s)
    m.remove(.direction, s)
    #expect(m.phase == .keywords("carrefour september", .nothingUnderstood))
    await m.run("carrefour september", s, now: now, debounce: .zero)
    m.clearScope()
    #expect(m.answer(for: "carrefour september") == nil)
  }

  @Test func vocabularyFromTheLedger() {
    let v = AskSearch.vocabulary(store.state, now: store.now)
    #expect(v.today == "Saturday 10 October 2026")
    #expect(Array(v.merchants.prefix(2)) == ["Carrefour", "Talabat"])
    #expect(v.merchants.contains("Common Grounds"))
    #expect(!v.categories.contains { $0.id == "debt" })
  }

  @Test func searchModelFallsBackToKeywords() async {
    let s = store.state, now = store.now
    let off = AskSearchModel(parser: SearchQueryParser(model: CannedSearchModel(state: .notEligible)))
    #expect(!off.available)
    await off.run("coffee last month", s, now: now, debounce: .zero)
    #expect(off.phase == .keywords("coffee last month", .unavailable(.notEligible)))

    let on = AskSearchModel(parser: SearchQueryParser(model: CannedSearchModel(replies: [
      "carrefour september": .reply(SearchModelReply(merchants: ["Carrefour"], period: .month, month: 9)),
    ])))
    await on.run("كم صرفت في كارفور", s, now: now, debounce: .zero)
    #expect(on.phase == .idle)
    await on.run("carrefour", s, now: now, debounce: .zero)
    #expect(on.phase == .idle)
    await on.run("tell me a joke", s, now: now, debounce: .zero)
    #expect(on.phase == .keywords("tell me a joke", .nothingUnderstood))
    await on.run("carrefour september", s, now: now, debounce: .zero)
    #expect(on.answer(for: "carrefour september")?.total == .aed(689_80))
    #expect(on.answer(for: "carrefour") == nil)
  }
}
