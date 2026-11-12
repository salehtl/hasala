import HasalaModel
import HasalaModels
import Observation
import os

enum AskSearch {
  static func vocabulary(_ s: LedgerState, now: LocalDateTime) -> SearchVocabulary {
    let d = now.date
    return SearchVocabulary(
      today: "\(weekdays[d.weekday]) \(d.day) \(d.yearMonth.name) \(d.year)",
      categories: s.categories.filter { !$0.archived }.map { .init(id: $0.id, name: $0.name) },
      merchants: merchantCounts(s).map(\.name))
  }

  static func merchantCounts(_ s: LedgerState) -> [(name: String, count: Int)] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for t in s.txns.sorted(by: { $0.postedAt > $1.postedAt }) where !t.archived {
      if counts[t.merchant] == nil { order.append(t.merchant) }
      counts[t.merchant, default: 0] += 1
    }
    return order.enumerated().sorted { a, b in
      let (ca, cb) = (counts[a.element] ?? 0, counts[b.element] ?? 0)
      return ca == cb ? a.offset < b.offset : ca > cb
    }.map { ($0.element, counts[$0.element] ?? 0) }
  }

  static func merchantChoices(_ s: LedgerState, excluding taken: [String]) -> [(name: String, count: Int)] {
    merchantCounts(s).filter { c in
      !c.name.trimmedSpaces.isEmpty && !taken.contains { $0.caseInsensitiveCompare(c.name) == .orderedSame }
    }
  }

  static func countLabel(_ n: Int) -> String {
    "\(MoneyFormat.count(n)) transaction\(n == 1 ? "" : "s")"
  }

  static func words(_ q: String) -> [String] {
    SearchText.fold(q).lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
  }

  static func mentions(_ q: String, _ name: String) -> Bool {
    let n = words(name)
    let w = words(q)
    guard !n.isEmpty, w.count >= n.count else { return false }
    return (0...(w.count - n.count)).contains { Array(w[$0..<($0 + n.count)]) == n }
  }

  static func mentionedNames(in q: String, _ s: LedgerState) -> [String] {
    let names = merchantCounts(s).map(\.name) + s.categories.filter { !$0.archived }.map(\.name)
    var seen = Set<String>()
    return names.filter { mentions(q, $0) && seen.insert($0.lowercased()).inserted }
  }

  static func matchedNote(_ q: String, merchants n: Int) -> String {
    "Matched “\(Bidi.isolate(q))” to \(MoneyFormat.count(n)) merchant\(n == 1 ? "" : "s"). It may have missed some."
  }

  static func seeAllLabel(_ a: AskAnswer, _ s: LedgerState) -> String? {
    guard a.activity != nil else { return nil }
    let f = a.filter
    if f.merchants.isEmpty, let c = s.category(f.category) {
      return "\(Bidi.isolate(c.name)) in Activity"
    }
    guard let m = f.merchants.first else { return nil }
    let widens = f.category != nil || f.period != nil || f.direction != nil || f.minimumFils != nil || f.maximumFils != nil
    return widens ? "All \(Bidi.isolate(m)) transactions" : "See all"
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
    AskEngine.answer(s, filter: filter(i, now: now), today: now.date)
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
  private(set) var added: [String] = []
  private static let log = Logger(subsystem: "app.hasala.ios", category: "search")
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
    case .intent(let i):
      added = []
      phase = .answered(q, AskSearch.answer(i, s, now: now))
    case .keywordsOnly(let why):
      Self.log.info("ask search fell back: \(String(describing: why), privacy: .public)")
      phase = .keywords(q, why)
    }
  }

  func fallback(for q: String) -> SearchFallback? {
    if case .keywords(let asked, let why) = phase, asked == q { return why }
    return nil
  }

  @discardableResult
  func remove(_ part: AskScope.Part, _ s: LedgerState, now: LocalDateTime? = nil) -> Bool {
    guard case .answered(let q, let a) = phase else { return false }
    let f = a.filter.removing(part)
    if f.isEmpty {
      phase = .idle
      added = []
      return false
    }
    phase = .answered(q, AskEngine.answer(s, filter: f, today: now?.date))
    return true
  }

  func clearScope() {
    guard case .answered = phase else { return }
    phase = .idle
    added = []
  }

  func add(merchant m: String, _ s: LedgerState, now: LocalDateTime? = nil) {
    guard case .answered(let q, let a) = phase,
          !a.filter.merchants.contains(where: { $0.caseInsensitiveCompare(m) == .orderedSame }) else { return }
    var f = a.filter
    f.merchants.append(m)
    added.append(m)
    phase = .answered(q, AskEngine.answer(s, filter: f, today: now?.date))
  }

  func inferredMerchants(_ a: AskAnswer, _ q: String) -> [String] {
    a.filter.merchants.filter { m in !AskSearch.mentions(q, m) && !added.contains(m) }
  }
}
