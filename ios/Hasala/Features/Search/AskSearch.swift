import HasalaModel
import HasalaModels
import Observation

enum AskSearch {
  static func vocabulary(_ s: LedgerState, now: LocalDateTime) -> SearchVocabulary {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for t in s.txns.sorted(by: { $0.postedAt > $1.postedAt }) where !t.archived {
      if counts[t.merchant] == nil { order.append(t.merchant) }
      counts[t.merchant, default: 0] += 1
    }
    let merchants = order.enumerated().sorted { a, b in
      let (ca, cb) = (counts[a.element] ?? 0, counts[b.element] ?? 0)
      return ca == cb ? a.offset < b.offset : ca > cb
    }.map(\.element)
    let d = now.date
    return SearchVocabulary(
      today: "\(weekdays[d.weekday]) \(d.day) \(d.yearMonth.name) \(d.year)",
      categories: s.categories.filter { !$0.archived }.map { .init(id: $0.id, name: $0.name) },
      merchants: merchants)
  }

  static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

  static func filter(_ i: SearchIntent, now: LocalDateTime) -> AskFilter {
    let d = now.date
    let period: AskPeriod? =
      switch i.period {
      case .any: nil
      case .today: .today(d)
      case .yesterday: .yesterday(d)
      case .thisWeek: .thisWeek(d)
      case .lastWeek: .lastWeek(d)
      case .thisMonth: .thisMonth(d)
      case .lastMonth: .lastMonth(d)
      case .thisYear: .thisYear(d)
      case .lastYear: .lastYear(d)
      case .month: i.month.map { .month($0, year: i.year, today: d) }
      case .lastDays: i.days.map { .lastDays($0, today: d) }
      }
    let direction: Direction? =
      switch i.flow {
      case .any: nil
      case .spent: .out
      case .received: .in
      }
    return AskFilter(
      merchants: i.merchants, category: i.category, minimumFils: i.minimumFils, maximumFils: i.maximumFils,
      period: period, direction: direction, asksTotal: i.asksTotal)
  }

  static func answer(_ i: SearchIntent, _ s: LedgerState, now: LocalDateTime) -> AskAnswer {
    AskEngine.answer(s, filter: filter(i, now: now))
  }

  static func isQuestion(_ q: String) -> Bool {
    q.split(separator: " ").count >= 2
  }

  #if HASALA_MOCKS
    static var launchParser: SearchQueryParser?
  #endif

  static func makeParser() -> SearchQueryParser {
    #if HASALA_MOCKS
      if let p = launchParser { return p }
    #endif
    return SearchQueryParser(model: HasalaModelFactory.makeSearch())
  }
}

@MainActor
@Observable
final class AskSearchModel {
  enum Phase: Equatable {
    case idle
    case thinking(String)
    case answered(String, AskAnswer)
    case keywords(String, SearchFallback)
  }

  private(set) var phase: Phase = .idle
  @ObservationIgnored let parser: SearchQueryParser
  @ObservationIgnored private(set) var available: Bool

  init(parser: SearchQueryParser = AskSearch.makeParser()) {
    self.parser = parser
    self.available = parser.isAvailable
  }

  func answer(for q: String) -> AskAnswer? {
    if case .answered(let asked, let a) = phase, asked == q { return a }
    return nil
  }

  func isThinking(about q: String) -> Bool {
    if case .thinking(let asked) = phase { return asked == q }
    return false
  }

  func run(_ q: String, _ s: LedgerState, now: LocalDateTime, debounce: Duration = .milliseconds(450)) async {
    guard AskSearch.isQuestion(q), SearchQueryParser.accepts(q) else {
      phase = .idle
      return
    }
    available = parser.isAvailable
    guard available else {
      phase = .keywords(q, .unavailable(parser.model.availability()))
      return
    }
    phase = .thinking(q)
    if debounce > .zero {
      try? await Task.sleep(for: debounce)
      if Task.isCancelled { return }
    }
    let parsed = await parser.parse(q, vocabulary: AskSearch.vocabulary(s, now: now))
    if Task.isCancelled { return }
    switch parsed {
    case .intent(let i): phase = .answered(q, AskSearch.answer(i, s, now: now))
    case .keywordsOnly(let why): phase = .keywords(q, why)
    }
  }

  func remove(_ part: AskScope.Part, _ s: LedgerState) {
    guard case .answered(let q, let a) = phase else { return }
    let f = a.filter.removing(part)
    phase = f.isEmpty ? .keywords(q, .nothingUnderstood) : .answered(q, AskEngine.answer(s, filter: f))
  }

  func clearScope() {
    guard case .answered(let q, _) = phase else { return }
    phase = .keywords(q, .nothingUnderstood)
  }

  func clear() { phase = .idle }
}
