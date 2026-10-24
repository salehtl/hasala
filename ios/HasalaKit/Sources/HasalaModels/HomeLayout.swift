public enum HomeWidgetKind: String, Sendable, Hashable, CaseIterable, Codable, CanvasSized {
  case spentSoFar, budgetPace, categoryWatch, nextBill, netWorth, comingUp, project, goal, toReview, today

  public enum Group: String, Sendable, Hashable, CaseIterable {
    case thisMonth, billsAndMoney, goalsAndHabits

    public var title: String {
      switch self {
      case .thisMonth: "This month"
      case .billsAndMoney: "Bills and money"
      case .goalsAndHabits: "Goals and habits"
      }
    }

    public var kinds: [HomeWidgetKind] { HomeWidgetKind.allCases.filter { $0.group == self } }
  }

  public var group: Group {
    switch self {
    case .spentSoFar, .budgetPace, .categoryWatch: .thisMonth
    case .nextBill, .netWorth, .comingUp: .billsAndMoney
    case .project, .goal, .toReview, .today: .goalsAndHabits
    }
  }

  public var size: HomeWidget.Size {
    switch self {
    case .budgetPace, .comingUp, .today: .medium
    case .spentSoFar, .categoryWatch, .nextBill, .netWorth, .project, .goal, .toReview: .small
    }
  }

  public var sizes: [HomeWidget.Size] { [size] }

  public var title: String {
    switch self {
    case .spentSoFar: "Spent so far"
    case .budgetPace: "Budget pace"
    case .categoryWatch: "Category watch"
    case .nextBill: "Next bill"
    case .netWorth: "Net worth"
    case .comingUp: "Coming up"
    case .project: "Project"
    case .goal: "Goal"
    case .toReview: "To review"
    case .today: "Today"
    }
  }

  public var blurb: String {
    switch self {
    case .spentSoFar: "the Home hero, anywhere"
    case .budgetPace: "Needs, Wants and Savings"
    case .categoryWatch: "a category you pick"
    case .nextBill: "from bills Hasala found"
    case .netWorth: "after your first check-in"
    case .comingUp: "bills and salary for the next 14 days"
    case .project: "a project you pick"
    case .goal: "a savings goal you pick"
    case .toReview: "opens the review deck"
    case .today: "the day's transactions"
    }
  }

  public var sizeName: String { size == .small ? "Small" : "Medium" }

  public var caption: String { "\(sizeName) · \(blurb)" }

  public var configurable: Bool { configKind != nil }

  public var configKind: HomeWidgetConfig.Kind? {
    switch self {
    case .categoryWatch: .category
    case .project: .project
    case .goal: .goal
    default: nil
    }
  }

  public var waitingSentence: String {
    switch self {
    case .nextBill: "Bills Hasala finds will show here."
    case .netWorth: "Your first account check-in will fill this in."
    case .project: "Start a project in Plan to see it here."
    case .goal: "Add a savings goal in Plan to see it here."
    case .categoryWatch: "Set a budget in Plan to watch a category."
    case .comingUp: "Bills Hasala finds will show here."
    default: "Your first bank alert will fill this in."
    }
  }
}

public enum HomeWidgetConfig: Sendable, Hashable, Codable {
  case category(CategoryID)
  case project(ProjectID)
  case goal(GoalID)

  public enum Kind: String, Sendable, Hashable, Codable {
    case category, project, goal
  }

  public var kind: Kind {
    switch self {
    case .category: .category
    case .project: .project
    case .goal: .goal
    }
  }

  public var value: String {
    switch self {
    case .category(let id), .project(let id), .goal(let id): id
    }
  }

  public init(_ kind: Kind, _ value: String) {
    switch kind {
    case .category: self = .category(value)
    case .project: self = .project(value)
    case .goal: self = .goal(value)
    }
  }

  private enum Keys: String, CodingKey { case kind, id }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    let raw = try c.decode(String.self, forKey: .kind)
    guard let kind = Kind(rawValue: raw) else {
      throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown config \(raw)")
    }
    self.init(kind, try c.decode(String.self, forKey: .id))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(kind.rawValue, forKey: .kind)
    try c.encode(value, forKey: .id)
  }
}

public struct HomeLayout: Sendable, Hashable, Codable {
  public static let version = 1

  public struct Entry: Sendable, Hashable, Codable, Identifiable {
    public var kind: HomeWidgetKind
    public var size: HomeWidget.Size
    public var config: HomeWidgetConfig?

    public init(_ kind: HomeWidgetKind, config: HomeWidgetConfig? = nil, size: HomeWidget.Size? = nil) {
      self.kind = kind
      self.config = config
      self.size = size.flatMap { kind.sizes.contains($0) ? $0 : nil } ?? kind.size
    }

    public var id: String { config.map { "\(kind.rawValue).\($0.value)" } ?? kind.rawValue }

    public var isValid: Bool { config?.kind == kind.configKind && kind.sizes.contains(size) }

    private enum Keys: String, CodingKey { case kind, size, config }

    public init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      let raw = try c.decode(String.self, forKey: .kind)
      guard let kind = HomeWidgetKind(rawValue: raw) else {
        throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(raw)")
      }
      let size = (try? c.decodeIfPresent(String.self, forKey: .size)).flatMap { $0 }.flatMap(HomeWidget.Size.init)
      let config = try c.decodeIfPresent(HomeWidgetConfig.self, forKey: .config)
      self.init(kind, config: config, size: size)
    }

    public func encode(to encoder: any Encoder) throws {
      var c = encoder.container(keyedBy: Keys.self)
      try c.encode(kind.rawValue, forKey: .kind)
      try c.encode(size.rawValue, forKey: .size)
      try c.encodeIfPresent(config, forKey: .config)
    }
  }

  public private(set) var entries: [Entry]

  public init(_ entries: [Entry] = []) {
    var seen = Set<String>()
    self.entries = entries.filter { $0.isValid && seen.insert($0.id).inserted }
  }

  public var isEmpty: Bool { entries.isEmpty }
  public var ids: [String] { entries.map(\.id) }

  public func contains(_ id: String) -> Bool { entries.contains { $0.id == id } }

  public func index(of id: String) -> Int? { entries.firstIndex { $0.id == id } }

  public func canAdd(_ entry: Entry) -> Bool { entry.isValid && !contains(entry.id) }

  public func isOnHome(_ kind: HomeWidgetKind) -> Bool {
    !kind.configurable && entries.contains { $0.kind == kind }
  }

  @discardableResult
  public mutating func add(_ entry: Entry) -> Bool {
    guard canAdd(entry) else { return false }
    entries.append(entry)
    return true
  }

  @discardableResult
  public mutating func remove(_ id: String) -> Bool {
    guard let i = index(of: id) else { return false }
    entries.remove(at: i)
    return true
  }

  @discardableResult
  public mutating func move(_ id: String, to destination: Int) -> Bool {
    guard let i = index(of: id) else { return false }
    let target = min(max(destination, 0), entries.count - 1)
    guard target != i else { return false }
    let e = entries.remove(at: i)
    entries.insert(e, at: target)
    return true
  }

  public func canMove(_ id: String, by offset: Int) -> Bool {
    guard let i = index(of: id) else { return false }
    return entries.indices.contains(i + offset)
  }

  @discardableResult
  public mutating func move(_ id: String, by offset: Int) -> Bool {
    guard let i = index(of: id), entries.indices.contains(i + offset) else { return false }
    return move(id, to: i + offset)
  }

  @discardableResult
  public mutating func configure(_ id: String, _ config: HomeWidgetConfig) -> Bool {
    guard let i = index(of: id) else { return false }
    var e = entries[i]
    e.config = config
    guard e.isValid, e.id == id || !contains(e.id) else { return false }
    entries[i] = e
    return true
  }

  private enum Keys: String, CodingKey { case version, entries }

  private struct Lossy: Decodable {
    let entry: Entry?
    init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    let raw = try c.decode([Lossy].self, forKey: .entries)
    self.init(raw.compactMap(\.entry))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(Self.version, forKey: .version)
    try c.encode(entries, forKey: .entries)
  }
}

public struct HomeCanvasItem: Sendable, Hashable, Identifiable, CanvasSized {
  public var entry: HomeLayout.Entry
  public var widget: HomeWidget?

  public init(entry: HomeLayout.Entry, widget: HomeWidget?) {
    self.entry = entry
    self.widget = widget
  }

  public var id: String { entry.id }
  public var size: HomeWidget.Size { entry.size }
  public var kind: HomeWidgetKind { entry.kind }
  public var isWaiting: Bool { widget == nil }

  public var title: String {
    switch widget {
    case .project(let p)?: p.name
    case .goal(let g)?: g.name
    case .categoryWatch(let c)?: "\(c.name) watch"
    default: entry.kind.title
    }
  }
}

public struct HomeWidgetOption: Sendable, Hashable, Identifiable {
  public var config: HomeWidgetConfig
  public var title: String
  public var detail: MoneyPhrase?
  public var section: String
  public var glyph: Glyph
  public var hue: Hue

  public init(config: HomeWidgetConfig, title: String, detail: MoneyPhrase?, section: String, glyph: Glyph, hue: Hue) {
    self.config = config
    self.title = title
    self.detail = detail
    self.section = section
    self.glyph = glyph
    self.hue = hue
  }

  public var id: String { config.value }
}

public protocol CanvasSized {
  var size: HomeWidget.Size { get }
}
