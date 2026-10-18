import CoreCategorize
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

public enum SearchPeriod: String, Sendable, Equatable, CaseIterable {
  case any, today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear, month, lastDays
}

public enum SearchFlow: String, Sendable, Equatable, CaseIterable {
  case any, spent, received
}

public struct SearchModelReply: Sendable, Equatable {
  public var merchants: [String]
  public var category: String?
  public var minimumAmount: String?
  public var maximumAmount: String?
  public var period: SearchPeriod
  public var month: Int?
  public var year: Int?
  public var days: Int?
  public var flow: SearchFlow
  public var asksTotal: Bool

  public init(
    merchants: [String] = [], category: String? = nil, minimumAmount: String? = nil, maximumAmount: String? = nil,
    period: SearchPeriod = .any, month: Int? = nil, year: Int? = nil, days: Int? = nil, flow: SearchFlow = .any,
    asksTotal: Bool = false
  ) {
    self.merchants = merchants
    self.category = category
    self.minimumAmount = minimumAmount
    self.maximumAmount = maximumAmount
    self.period = period
    self.month = month
    self.year = year
    self.days = days
    self.flow = flow
    self.asksTotal = asksTotal
  }
}

public struct SearchIntent: Sendable, Equatable {
  public var merchants: [String]
  public var category: String?
  public var minimumFils: Int64?
  public var maximumFils: Int64?
  public var period: SearchPeriod
  public var month: Int?
  public var year: Int?
  public var days: Int?
  public var flow: SearchFlow
  public var asksTotal: Bool

  public init(
    merchants: [String] = [], category: String? = nil, minimumFils: Int64? = nil, maximumFils: Int64? = nil,
    period: SearchPeriod = .any, month: Int? = nil, year: Int? = nil, days: Int? = nil, flow: SearchFlow = .any,
    asksTotal: Bool = false
  ) {
    self.merchants = merchants
    self.category = category
    self.minimumFils = minimumFils
    self.maximumFils = maximumFils
    self.period = period
    self.month = month
    self.year = year
    self.days = days
    self.flow = flow
    self.asksTotal = asksTotal
  }

  public var narrows: Bool {
    !merchants.isEmpty || category != nil || minimumFils != nil || maximumFils != nil || period != .any
      || flow != .any
  }
}

public struct SearchVocabulary: Sendable, Equatable {
  public struct Category: Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  public static let merchantLimit = 80

  public var today: String
  public var categories: [Category]
  public var merchants: [String]

  public init(today: String, categories: [Category], merchants: [String]) {
    self.today = today
    self.categories = categories
    var seen = Set<String>()
    self.merchants = Array(merchants.filter { seen.insert($0.lowercased()).inserted }.prefix(Self.merchantLimit))
  }
}

public enum SearchParse: Sendable, Equatable {
  case intent(SearchIntent)
  case keywordsOnly(SearchFallback)
}

public enum SearchFallback: Sendable, Equatable {
  case script
  case unavailable(ModelAvailability)
  case failed(ModelFailure)
  case nothingUnderstood
}

public enum SearchModelAnswer: Sendable, Equatable {
  case reply(SearchModelReply)
  case failed(ModelFailure)
}

public protocol SearchQueryModel: Sendable {
  func availability() -> ModelAvailability
  func interpret(_ query: String, vocabulary: SearchVocabulary) async -> SearchModelAnswer
}

public struct SearchQueryParser: Sendable {
  public let model: any SearchQueryModel

  public init(model: any SearchQueryModel) {
    self.model = model
  }

  public static func accepts(_ query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return q.count <= 160 && LatinGate.passes(Self.plain(q))
  }

  public var isAvailable: Bool { model.availability() == .available }

  public func parse(_ query: String, vocabulary: SearchVocabulary) async -> SearchParse {
    guard Self.accepts(query) else { return .keywordsOnly(.script) }
    let a = model.availability()
    guard a == .available else { return .keywordsOnly(.unavailable(a)) }
    switch await model.interpret(Self.plain(query.trimmingCharacters(in: .whitespacesAndNewlines)), vocabulary: vocabulary) {
    case .failed(let f): return .keywordsOnly(.failed(f))
    case .reply(let r):
      let intent = Self.intent(r, vocabulary: vocabulary, query: query)
      return intent.narrows ? .intent(intent) : .keywordsOnly(.nothingUnderstood)
    }
  }

  public static func intent(_ r: SearchModelReply, vocabulary v: SearchVocabulary, query: String? = nil) -> SearchIntent {
    let i = intent(r, vocabulary: v)
    guard let query else { return i }
    return grounded(i, in: query, reply: r, vocabulary: v)
  }

  static let timeWords: Set<String> = [
    "today", "tonight", "yesterday", "day", "days", "week", "weeks", "weekend", "month", "months", "year", "years",
    "since", "ago", "recent", "recently", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct",
    "nov", "dec", "january", "february", "march", "april", "june", "july", "august", "september", "october",
    "november", "december",
  ]
  static let overWords = ["over", "above", "more than", "at least", "greater than", "bigger than", "min"]
  static let underWords = ["under", "below", "less than", "at most", "cheaper than", "smaller than", "max"]

  static func words(_ q: String) -> [String] {
    q.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
  }

  static func mentions(_ q: String, _ name: String) -> Bool {
    let n = words(name)
    guard !n.isEmpty else { return false }
    let w = words(q)
    guard w.count >= n.count else { return false }
    return (0...(w.count - n.count)).contains { Array(w[$0..<($0 + n.count)]) == n }
  }

  static func grounded(_ i: SearchIntent, in query: String, reply r: SearchModelReply, vocabulary v: SearchVocabulary) -> SearchIntent {
    var g = i
    let w = words(query)
    let lower = " " + w.joined(separator: " ") + " "
    let isCategory: (String) -> SearchVocabulary.Category? = { m in
      v.categories.first { $0.id.caseInsensitiveCompare(m) == .orderedSame || $0.name.caseInsensitiveCompare(m) == .orderedSame }
    }
    let candidates = ([i.category].compactMap { $0 }.compactMap { id in v.categories.first { $0.id == id } })
      + r.merchants.compactMap { isCategory($0.trimmingCharacters(in: .whitespaces)) }
    g.category = candidates.first { mentions(query, $0.name) || mentions(query, $0.id) }?.id
    g.merchants = i.merchants.filter { isCategory($0) == nil }
    if g.category != nil {
      g.merchants = g.merchants.filter { mentions(query, $0) }
    }
    if g.minimumFils == 0 { g.minimumFils = nil }
    if g.maximumFils == 0 { g.maximumFils = nil }
    if !query.contains(where: { $0.isASCII && $0.isNumber }) {
      g.minimumFils = nil
      g.maximumFils = nil
    }
    let over = overWords.contains { lower.contains(" \($0) ") }
    let under = underWords.contains { lower.contains(" \($0) ") }
    if let lo = g.minimumFils, let hi = g.maximumFils, lo == hi {
      if over && !under { g.maximumFils = nil } else if under && !over { g.minimumFils = nil }
    } else if g.minimumFils != nil && g.maximumFils == nil && under && !over {
      (g.minimumFils, g.maximumFils) = (nil, g.minimumFils)
    } else if g.maximumFils != nil && g.minimumFils == nil && over && !under {
      (g.minimumFils, g.maximumFils) = (g.maximumFils, nil)
    }
    if let n = Self.lastDays(w) {
      g.period = .lastDays
      g.days = n
      g.month = nil
      g.year = nil
    } else if !w.contains(where: timeWords.contains) {
      g.period = .any
      g.month = nil
      g.year = nil
      g.days = nil
    } else if g.period == .month, !w.contains(where: { $0.count == 4 && Int($0) != nil }) {
      g.year = nil
    }
    return g
  }

  static func lastDays(_ w: [String]) -> Int? {
    guard w.count >= 3 else { return nil }
    for k in 0..<(w.count - 2) where ["past", "last"].contains(w[k]) && ["day", "days"].contains(w[k + 2]) {
      if let n = Int(w[k + 1]), (1...366).contains(n) { return n }
    }
    return nil
  }

  static func intent(_ r: SearchModelReply, vocabulary v: SearchVocabulary) -> SearchIntent {
    let known = r.merchants.compactMap { m in
      v.merchants.first { $0.caseInsensitiveCompare(m.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
    let typed = r.merchants.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
    var seen = Set<String>()
    let merchants = (known.isEmpty ? typed : known).filter { seen.insert($0.lowercased()).inserted }
    let category = r.category.flatMap { c in
      v.categories.first { $0.id == c || $0.name.caseInsensitiveCompare(c) == .orderedSame }?.id
    }
    var lo = r.minimumAmount.flatMap(fils)
    var hi = r.maximumAmount.flatMap(fils)
    if let a = lo, let b = hi, a > b { (lo, hi) = (b, a) }
    var period = r.period
    let month = r.month.flatMap { (1...12).contains($0) ? $0 : nil }
    let year = r.year.flatMap { (2000...2100).contains($0) ? $0 : nil }
    let days = r.days.flatMap { (1...366).contains($0) ? $0 : nil }
    if period == .month && month == nil { period = .any }
    if period == .lastDays && days == nil { period = .any }
    return SearchIntent(
      merchants: merchants, category: category, minimumFils: lo, maximumFils: hi, period: period,
      month: period == .month ? month : nil, year: period == .month ? year : nil,
      days: period == .lastDays ? days : nil, flow: r.flow, asksTotal: r.asksTotal)
  }

  public static func fils(_ text: String) -> Int64? {
    var s = Substring(text.trimmingCharacters(in: .whitespaces))
    for prefix in ["AED", "aed", "Dhs", "dhs", "DHS"] where s.hasPrefix(prefix) {
      s = s.dropFirst(prefix.count)
    }
    s = Substring(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let whole = parts.first, !whole.isEmpty, whole.count <= 9,
          whole.allSatisfy({ $0.isASCII && $0.isNumber }), let units = Int64(whole) else { return nil }
    var fraction: Int64 = 0
    if parts.count == 2 {
      let f = parts[1]
      guard (1...2).contains(f.count), f.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int64(f) else {
        return nil
      }
      fraction = f.count == 1 ? n * 10 : n
    }
    return units * 100 + fraction
  }

  static func plain(_ q: String) -> String {
    let map: [Character: Character] = ["\u{2019}": "'", "\u{2018}": "'", "\u{201C}": "\"", "\u{201D}": "\""]
    return String(q.map { map[$0] ?? $0 })
  }

  public static func instructions(_ v: SearchVocabulary) -> String {
    var lines = [
      "You turn a question about a person's own card payments into a search filter.",
      "Money is in UAE dirhams (AED). Today is \(v.today).",
      "Fill only what the question says. Leave everything else empty, any, or false.",
      "merchants: names from the merchant list that the question is about. For a kind of place (coffee, groceries), pick every listed merchant of that kind. If none is listed, write the name as asked.",
      "category: the id of one listed category, only when the question names a category.",
      "period: today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear; month with month (1-12) and year when a month is named; lastDays with days for 'past N days'.",
      "flow: spent for spending or paying, received for income or money in.",
      "minimumAmount and maximumAmount: plain numbers such as 50 or 12.50, for 'over', 'under', 'between'.",
      "asksTotal: true when the question asks how much.",
      "Categories:",
    ]
    lines += v.categories.map { "- \($0.id): \($0.name)" }
    lines.append("Merchants: " + v.merchants.joined(separator: ", "))
    return lines.joined(separator: "\n")
  }
}

public struct UnavailableSearchQueryModel: SearchQueryModel {
  public init() {}
  public func availability() -> ModelAvailability { .notEligible }
  public func interpret(_ query: String, vocabulary: SearchVocabulary) async -> SearchModelAnswer {
    .failed(.assetsUnavailable)
  }
}

#if canImport(FoundationModels)
  @Generable
  struct GeneratedSearch {
    @Guide(description: "Merchant names the question is about", .maximumCount(8))
    var merchants: [String]
    @Guide(description: "One category id from the list, or empty")
    var category: String?
    @Guide(description: "Lowest amount in dirhams, e.g. 50 or 12.50")
    var minimumAmount: String?
    @Guide(description: "Highest amount in dirhams, e.g. 200")
    var maximumAmount: String?
    var period: GeneratedPeriod
    @Guide(description: "Month number 1-12 when period is month")
    var month: Int?
    @Guide(description: "Four-digit year when the question names one")
    var year: Int?
    @Guide(description: "Number of days when period is lastDays")
    var days: Int?
    var flow: GeneratedFlow
    @Guide(description: "True when the question asks how much")
    var asksTotal: Bool
  }

  @Generable
  enum GeneratedPeriod: String {
    case any, today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear, month, lastDays
  }

  @Generable
  enum GeneratedFlow: String {
    case any, spent, received
  }

  extension GeneratedSearch {
    var reply: SearchModelReply {
      SearchModelReply(
        merchants: merchants, category: category, minimumAmount: minimumAmount, maximumAmount: maximumAmount,
        period: SearchPeriod(rawValue: period.rawValue) ?? .any, month: month, year: year, days: days,
        flow: SearchFlow(rawValue: flow.rawValue) ?? .any, asksTotal: asksTotal)
    }
  }

  public struct FoundationModelsSearchQueryModel: SearchQueryModel {
    public init() {}

    static var options: GenerationOptions {
      #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160)
      #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: 160)
      #endif
    }

    public func availability() -> ModelAvailability {
      FoundationModelsCategoryModel().availability()
    }

    public func interpret(_ query: String, vocabulary: SearchVocabulary) async -> SearchModelAnswer {
      do {
        let session = LanguageModelSession(
          model: SystemLanguageModel(useCase: .general), instructions: SearchQueryParser.instructions(vocabulary))
        let reply = try await session.respond(
          to: query, generating: GeneratedSearch.self, includeSchemaInPrompt: true, options: Self.options)
        return .reply(reply.content.reply)
      } catch let error as LanguageModelSession.GenerationError {
        switch error {
        case .exceededContextWindowSize: return .failed(.contextOverflow)
        case .rateLimited: return .failed(.rateLimited)
        case .concurrentRequests: return .failed(.busy)
        case .guardrailViolation: return .failed(.guardrail)
        case .refusal: return .failed(.refusal)
        case .unsupportedLanguageOrLocale: return .failed(.unsupportedLanguage)
        case .assetsUnavailable: return .failed(.assetsUnavailable)
        case .decodingFailure: return .failed(.decoding)
        default: return .failed(.other)
        }
      } catch is CancellationError {
        return .failed(.timeout)
      } catch {
        return .failed(.other)
      }
    }
  }
#endif

extension HasalaModelFactory {
  public static func makeSearch() -> any SearchQueryModel {
    #if canImport(FoundationModels)
      return FoundationModelsSearchQueryModel()
    #else
      return UnavailableSearchQueryModel()
    #endif
  }
}
