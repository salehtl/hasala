public enum InsightsEngine {
  public static let merchantLimit = 20
  public static let changeLimit = 3
  public static let flowLength = 6
  public static let latestLimit = 10
  public static let collapsedCategories = 6

  // MARK: - Periods

  public static func title(of months: ClosedRange<YearMonth>) -> String {
    let a = months.lowerBound
    let b = months.upperBound
    if a == b { return b.title }
    if a.year == b.year { return "\(a.shortName)\u{2013}\(b.shortName) \(b.year)" }
    return "\(a.shortName) \(a.year) \u{2013} \(b.shortName) \(b.year)"
  }

  public static func window(_ month: YearMonth, now: LocalDateTime) -> InsightsWindow {
    let first = LocalDate(month.year, month.month, 1)
    if month == now.date.yearMonth { return InsightsWindow(from: first, through: now.date) }
    return InsightsWindow(from: first, through: LocalDate(month.year, month.month, month.days))
  }

  public static func wholeMonth(_ month: YearMonth) -> InsightsWindow {
    InsightsWindow(from: LocalDate(month.year, month.month, 1), through: LocalDate(month.year, month.month, month.days))
  }

  public static func comparisonWindow(_ month: YearMonth, now: LocalDateTime) -> (window: InsightsWindow, day: Int?) {
    let prev = month.previous
    guard month == now.date.yearMonth else { return (wholeMonth(prev), nil) }
    let through = LocalDate(prev.year, prev.month, min(now.date.day, prev.days))
    return (InsightsWindow(from: LocalDate(prev.year, prev.month, 1), through: through), now.date.day)
  }

  // MARK: - What counts

  public static func lines(_ s: LedgerState, in window: InsightsWindow? = nil) -> [InsightsLine] {
    var projects: [ProjectID: Project] = [:]
    for p in s.projects { projects[p.id] = p }
    var categories: [CategoryID: Category] = [:]
    for c in s.categories { categories[c.id] = c }
    var out: [InsightsLine] = []
    for t in s.txns where t.countsInPlan {
      if let window, !window.contains(t.postedAt.date) { continue }
      let carvedOut = t.projectID.flatMap { projects[$0] }.map { !$0.countInPlan } ?? false
      let parts: [(category: CategoryID, minor: Int64)] = t.splits.isEmpty
        ? (t.categoryID.map { [($0, t.amount.minor)] } ?? [])
        : t.splits.map { ($0.categoryID, $0.amount.minor) }
      let sign: Int64 = t.direction == .out ? 1 : -1
      for (i, part) in parts.enumerated() {
        guard let c = categories[part.category] else { continue }
        let kind: InsightsLine.Kind
        let minor: Int64
        switch c.kind {
        case .excluded:
          continue
        case .income:
          guard t.direction == .in else { continue }
          kind = .income
          minor = part.minor
        case .spending:
          guard !carvedOut else { continue }
          switch c.bucket {
          case .needs, .wants: kind = .spent
          case .savings: kind = .saved
          case .income, .project, .other: continue
          }
          minor = sign * part.minor
        }
        out.append(InsightsLine(txnID: t.id, part: i, merchant: t.merchant, postedAt: t.postedAt,
                                categoryID: c.id, bucket: c.bucket, kind: kind, minor: minor))
      }
    }
    return out
  }

  public struct Totals: Sendable, Hashable {
    public var needs: Int64 = 0
    public var wants: Int64 = 0
    public var saved: Int64 = 0
    public var income: Int64 = 0
    public var byCategory: [CategoryID: Int64] = [:]
    public var countByCategory: [CategoryID: Int] = [:]

    public init() {}

    public init(_ lines: [InsightsLine]) {
      for l in lines {
        switch l.kind {
        case .income:
          income += l.minor
        case .saved:
          saved += l.minor
          byCategory[l.categoryID, default: 0] += l.minor
          countByCategory[l.categoryID, default: 0] += 1
        case .spent:
          if l.bucket == .needs { needs += l.minor } else { wants += l.minor }
          byCategory[l.categoryID, default: 0] += l.minor
          countByCategory[l.categoryID, default: 0] += 1
        }
      }
    }

    public var spent: Int64 { needs + wants }

    public func bucket(_ b: Bucket) -> Int64 {
      switch b {
      case .needs: needs
      case .wants: wants
      case .savings: saved
      case .income: income
      case .project, .other: 0
      }
    }
  }

  // MARK: - Arithmetic (integers; only ratios divide, rounded at the end)

  public static func percent(_ part: Int64, of whole: Int64) -> Int {
    guard whole > 0 else { return 0 }
    let m = part.magnitude
    let w = UInt64(whole)
    let rounded = Int((m * 200 + w) / (w * 2))
    return part < 0 ? -rounded : rounded
  }

  public static func average(_ values: [Int64]) -> Int64 {
    guard !values.isEmpty else { return 0 }
    let sum = values.reduce(Int64(0), +)
    let n = Int64(values.count)
    let m = sum.magnitude
    let rounded = Int64((m * 2 + UInt64(n)) / (UInt64(n) * 2))
    return sum < 0 ? -rounded : rounded
  }

  public static func topChanges(current: [CategoryID: Int64], previous: [CategoryID: Int64],
                                limit: Int = changeLimit) -> [(category: CategoryID, change: Int64)] {
    let ids = Set(current.keys).union(previous.keys)
    var changes: [(category: CategoryID, change: Int64)] = []
    for id in ids {
      let change: Int64 = (current[id] ?? 0) - (previous[id] ?? 0)
      if change != 0 { changes.append((category: id, change: change)) }
    }
    changes.sort { a, b in
      let x = a.change.magnitude
      let y = b.change.magnitude
      return x != y ? x > y : a.category < b.category
    }
    return Array(changes.prefix(limit))
  }

  // MARK: - The screen

  struct Context {
    let focus: YearMonth
    let isCurrent: Bool
    let window: InsightsWindow
    let comparison: InsightsComparison?
    let all: [InsightsLine]
    let current: [InsightsLine]
    let previous: [InsightsLine]
  }

  static func context(_ s: LedgerState, months: ClosedRange<YearMonth>, now: LocalDateTime) -> Context {
    let focus = months.upperBound
    let window = window(focus, now: now)
    let all = lines(s)
    let whole = wholeMonth(focus.previous)
    let hasEarlier = all.contains { whole.contains($0.postedAt.date) }
    let compared = comparisonWindow(focus, now: now)
    let comparison = hasEarlier
      ? InsightsComparison(month: focus.previous, throughDay: compared.day, window: compared.window) : nil
    return Context(
      focus: focus, isCurrent: focus == now.date.yearMonth, window: window, comparison: comparison, all: all,
      current: all.filter { window.contains($0.postedAt.date) },
      previous: comparison.map { c in all.filter { c.window.contains($0.postedAt.date) } } ?? [])
  }

  public static func snapshot(_ s: LedgerState, months: ClosedRange<YearMonth>, now: LocalDateTime) -> InsightsSnapshot {
    let ctx = context(s, months: months, now: now)
    let cur = Totals(ctx.current)
    let prev = Totals(ctx.previous)
    let compared = ctx.comparison != nil
    func delta(_ a: Int64, _ b: Int64) -> InsightsDelta? { compared ? InsightsDelta.between(a, b) : nil }

    let order = Dictionary(s.categories.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    let spent = cur.spent
    let focus = ctx.focus

    let status: String
    if months.lowerBound != months.upperBound {
      status = "\(focus.shortName) · latest in range"
    } else if ctx.isCurrent {
      status = "Day \(now.date.day) of \(focus.days)"
    } else {
      status = "Closed month"
    }

    let summary = summary(cur: cur, prev: prev, compared: compared, isCurrent: ctx.isCurrent, focus: focus)

    let bucketRows: [InsightsRow] = [Bucket.needs, .wants].compactMap { b -> InsightsRow? in
      let amount = cur.bucket(b)
      guard amount != 0 else { return nil }
      return InsightsRow(
        id: "bucket.\(b.rawValue)", target: .bucket(b), title: b == .needs ? "Needs" : "Wants",
        glyph: b == .needs ? .rent : .shopping, hue: b.hue, bucket: b, amount: .aed(amount),
        sharePercent: percent(amount, of: spent), bar: Permille(0),
        count: ctx.current.filter { $0.kind == .spent && $0.bucket == b }.count,
        delta: delta(amount, prev.bucket(b)))
    }.sorted { $0.amount.minor > $1.amount.minor }

    let categoryRows: [InsightsRow] = cur.byCategory.compactMap { id, amount -> InsightsRow? in
      guard amount != 0, let c = s.category(id), c.bucket == .needs || c.bucket == .wants else { return nil }
      return InsightsRow(
        id: "category.\(id)", target: .category(id), title: c.name, glyph: c.glyph, hue: c.hue, bucket: c.bucket,
        amount: .aed(amount), sharePercent: percent(amount, of: spent), bar: Permille(0),
        count: cur.countByCategory[id] ?? 0, delta: delta(amount, prev.byCategory[id] ?? 0))
    }.sorted { a, b in
      a.amount.minor != b.amount.minor
        ? a.amount.minor > b.amount.minor : (order[a.id.dropCategory] ?? 0) < (order[b.id.dropCategory] ?? 0)
    }

    let merchantRows = merchants(ctx.current, s, spent: spent)

    let changes: [InsightsChange]
    let notice: InsightsNotice?
    if let comparison = ctx.comparison {
      let spentOnly = { (t: Totals) in t.byCategory.filter { s.category($0.key)?.bucket != .savings } }
      changes = topChanges(current: spentOnly(cur), previous: spentOnly(prev)).compactMap { item in
        guard let c = s.category(item.category) else { return nil }
        let now = cur.byCategory[item.category] ?? 0
        let before = prev.byCategory[item.category] ?? 0
        guard let d = InsightsDelta.between(now, before) else { return nil }
        let was: MoneyPhrase = before != 0
          ? MoneyPhrase([.amount(.aed(before)), .text(" \(comparison.when)")])
          : MoneyPhrase(stringLiteral: "None \(comparison.when)")
        return InsightsChange(categoryID: c.id, title: c.name, glyph: c.glyph, hue: c.hue, current: .aed(now),
                              previous: .aed(before), change: .aed(item.change), delta: d, before: was)
      }
      notice = changes.isEmpty
        ? InsightsNotice(title: "Nothing changed", message: "Spending in every category matches \(comparison.name).")
        : nil
    } else {
      changes = []
      let first = ctx.all.map(\.postedAt.date).min()
      let start = first.map { "Your first scan went back to \($0.day) \(CivilCalendar.monthNames[$0.month - 1]). " } ?? ""
      notice = InsightsNotice(title: "Nothing to compare yet",
                              message: start + "Changes show here once a month has a month before it.")
    }

    let (flow, flowEmpty) = flow(ctx, now: now)

    let footer: MoneyPhrase = MoneyPhrase([
      .text("Share of "), .amount(.aed(spent)),
      .text(ctx.isCurrent ? " spent so far." : " spent on needs and wants."),
      .text(" Tap a row to see its transactions."),
    ])
    let empty = ctx.isCurrent
      ? "Nothing spent on needs and wants in \(focus.name) yet."
      : "Nothing was spent on needs and wants in \(focus.name)."

    return InsightsSnapshot(
      months: months, focus: focus, isCurrent: ctx.isCurrent, title: title(of: months), status: status,
      window: ctx.window, comparison: ctx.comparison,
      lensNote: ctx.comparison?.label ?? (ctx.isCurrent ? "\(focus.name) so far" : focus.name),
      summary: summary, buckets: scaled(bucketRows), categories: scaled(categoryRows), merchants: scaled(merchantRows),
      lensFooter: footer, lensEmpty: empty, changes: changes, changesNotice: notice, flow: flow, flowEmpty: flowEmpty,
      reports: reports(s, ctx, cur: cur, now: now), share: share(focus: focus, isCurrent: ctx.isCurrent, totals: cur))
  }

  static func scaled(_ rows: [InsightsRow]) -> [InsightsRow] {
    let largest = rows.map(\.amount.minor).max() ?? 0
    return rows.map { r in
      var r = r
      r.bar = Permille.ratio(r.amount.minor, of: largest)
      return r
    }
  }

  static func summary(cur: Totals, prev: Totals, compared: Bool, isCurrent: Bool, focus: YearMonth) -> InsightsSummary {
    func delta(_ a: Int64, _ b: Int64) -> InsightsDelta? { compared ? InsightsDelta.between(a, b) : nil }
    var legend = [
      InsightsLegendRow(kind: .needs, title: "Needs", amount: .aed(cur.needs), delta: delta(cur.needs, prev.needs),
                        target: .bucket(.needs)),
      InsightsLegendRow(kind: .wants, title: "Wants", amount: .aed(cur.wants), delta: delta(cur.wants, prev.wants),
                        target: .bucket(.wants)),
    ]
    if cur.saved != 0 || prev.saved != 0 || cur.income > 0 {
      legend.append(InsightsLegendRow(kind: .savings, title: "Moved to savings", amount: .aed(cur.saved),
                                      delta: delta(cur.saved, prev.saved), target: .bucket(.savings)))
    }
    guard cur.income > 0 else {
      let note: MoneyPhrase = isCurrent
        ? "Where your income goes shows once your salary lands."
        : MoneyPhrase(stringLiteral: "No income came in during \(focus.name).")
      return InsightsSummary(
        label: isCurrent ? "Spent so far" : "Spent", figure: .aed(cur.spent), isNet: false, keptPercent: nil,
        income: .aed(0), spent: .aed(cur.spent), saved: .aed(cur.saved), split: nil, note: note, legend: legend)
    }
    let net = cur.income - cur.spent
    let unspent = max(0, cur.income - cur.spent - cur.saved)
    legend.append(InsightsLegendRow(kind: .unspent, title: "Not yet spent or saved", amount: .aed(unspent),
                                    delta: nil, target: nil))
    return InsightsSummary(
      label: "Net · in minus spent", figure: .aed(net), isNet: true, keptPercent: percent(net, of: cur.income),
      income: .aed(cur.income), spent: .aed(cur.spent), saved: .aed(cur.saved),
      split: InsightsSplit(needs: cur.needs, wants: cur.wants, savings: cur.saved, unspent: unspent),
      note: MoneyPhrase([.text("Where "), .amount(.aed(cur.income)), .text(" of income went")]),
      legend: legend)
  }

  static func merchants(_ lines: [InsightsLine], _ s: LedgerState, spent: Int64) -> [InsightsRow] {
    struct Acc {
      var amount: Int64 = 0
      var count = 0
      var byCategory: [CategoryID: Int64] = [:]
    }
    var acc: [String: Acc] = [:]
    for l in lines where l.kind == .spent {
      acc[l.merchant, default: Acc()].amount += l.minor
      acc[l.merchant, default: Acc()].count += 1
      acc[l.merchant, default: Acc()].byCategory[l.categoryID, default: 0] += l.minor
    }
    return acc.compactMap { name, a -> InsightsRow? in
      guard a.amount != 0 else { return nil }
      let main = a.byCategory.max { x, y in x.value != y.value ? x.value < y.value : x.key > y.key }?.key
      let c = s.category(main)
      return InsightsRow(
        id: "merchant.\(name)", target: .merchant(name), title: name, glyph: c?.glyph ?? .tag, hue: c?.hue ?? .other,
        bucket: c?.bucket ?? .other, monogram: name.first.map { String($0).uppercased() }, amount: .aed(a.amount),
        sharePercent: percent(a.amount, of: spent), bar: Permille(0), count: a.count, delta: nil)
    }
    .sorted { a, b in a.amount.minor != b.amount.minor ? a.amount.minor > b.amount.minor : a.title < b.title }
    .prefix(merchantLimit)
    .map { $0 }
  }

  static func flow(_ ctx: Context, now: LocalDateTime) -> (InsightsFlow, String?) {
    let none = InsightsFlow(span: ctx.focus.name, months: [], averageOut: nil, note: "")
    guard let first = ctx.all.map(\.postedAt.date.yearMonth).min() else {
      return (none, "Money in and out shows here once transactions arrive.")
    }
    var start = ctx.focus
    for _ in 1..<flowLength where start.previous >= first { start = start.previous }
    guard start <= ctx.focus, first <= ctx.focus else {
      return (none, "Nothing came in or went out by the end of \(ctx.focus.name).")
    }
    var months: [InsightsFlowMonth] = []
    var m = start
    while m <= ctx.focus {
      let w = window(m, now: now)
      let t = Totals(ctx.all.filter { w.contains($0.postedAt.date) })
      months.append(InsightsFlowMonth(month: m, income: .aed(t.income), out: .aed(t.spent),
                                      inProgress: m == now.date.yearMonth, isFocus: m == ctx.focus))
      m = m.next
    }
    let complete = months.filter { !$0.inProgress }
    guard !complete.isEmpty else {
      let next = first.next
      return (InsightsFlow(span: ctx.focus.name, months: [], averageOut: nil, note: ""),
              "Your first full month shows here on 1 \(next.name). Each month after that adds a bar, up to six.")
    }
    let avg = average(complete.map(\.out.minor))
    let span = months.count == 1
      ? months[0].month.name : "\(months[0].month.shortName)\u{2013}\(months[months.count - 1].month.shortName)"
    let note = MoneyPhrase([
      .text("Out is spending on needs and wants, "), .amount(.aed(avg)),
      .text(" a month on average. Transfers between your accounts and moves to savings are left out."),
    ])
    return (InsightsFlow(span: span, months: months, averageOut: .aed(avg), note: note), nil)
  }

  static func reports(_ s: LedgerState, _ ctx: Context, cur: Totals, now: LocalDateTime) -> [InsightsReport] {
    let netWorth: InsightsReport
    if s.accounts.isEmpty {
      netWorth = InsightsReport(kind: .netWorth, title: "Net worth", value: .missing, caption: "Needs a check-in",
                                opens: false)
    } else {
      let total = s.accounts.reduce(Int64(0)) { $0 + $1.balance.minor }
      let change = s.netWorth.monthChange.minor
      if ctx.isCurrent {
        let caption: String
        switch InsightsDelta.between(total, total - change)?.kind {
        case .up, .down: caption = InsightsDelta.between(total, total - change)!.text + " this month"
        default: caption = "No change this month"
        }
        netWorth = InsightsReport(kind: .netWorth, title: "Net worth", value: .money(.aed(total)), caption: caption,
                                  opens: true)
      } else if ctx.focus == now.date.yearMonth.previous {
        netWorth = InsightsReport(kind: .netWorth, title: "Net worth", value: .money(.aed(total - change)),
                                  caption: "End of \(ctx.focus.name)", opens: true)
      } else {
        netWorth = InsightsReport(kind: .netWorth, title: "Net worth", value: .missing,
                                  caption: "No check-in for \(ctx.focus.name)", opens: true)
      }
    }

    let inVsSpent = cur.income > 0
      ? InsightsReport(kind: .inVsSpent, title: "In vs spent", value: .signedMoney(.aed(cur.income - cur.spent)),
                       caption: "Each category by month", opens: false)
      : InsightsReport(kind: .inVsSpent, title: "In vs spent", value: .missing, caption: "Once income lands", opens: false)

    let age = InsightsReport(kind: .ageOfMoney, title: "Age of money", value: .missing, caption: "Needs more history",
                             opens: false)

    let lastYear = YearMonth(ctx.focus.year - 1, ctx.focus.month)
    let through = LocalDate(lastYear.year, lastYear.month, min(ctx.window.through.day, lastYear.days))
    let lastWindow = InsightsWindow(from: LocalDate(lastYear.year, lastYear.month, 1), through: through)
    let lastSpent = Totals(ctx.all.filter { lastWindow.contains($0.postedAt.date) }).spent
    let yoy: InsightsReport
    if lastSpent > 0, let d = InsightsDelta.between(cur.spent, lastSpent) {
      yoy = InsightsReport(kind: .yearOnYear, title: "Year on year", value: .delta(d),
                           caption: "Spent vs \(lastYear.shortName) \(lastYear.year)", opens: false)
    } else {
      yoy = InsightsReport(kind: .yearOnYear, title: "Year on year", value: .missing, caption: "Builds with history",
                           opens: false)
    }
    return [netWorth, inVsSpent, age, yoy]
  }

  static func share(focus: YearMonth, isCurrent: Bool, totals: Totals) -> MoneyPhrase {
    var parts: [MoneyPhrase.Part] = [.text(isCurrent ? "\(focus.title) so far in Hasala: " : "\(focus.title) in Hasala: ")]
    if totals.income > 0 {
      parts += [.text("AED "), .amount(.aed(totals.income)), .text(" in, ")]
    }
    parts += [.text("AED "), .amount(.aed(totals.spent)), .text(" spent on needs and wants, AED "),
              .amount(.aed(totals.saved)), .text(" moved to savings.")]
    if totals.income > 0 {
      parts.append(.text(" Kept \(percent(totals.income - totals.spent, of: totals.income))%."))
    }
    return MoneyPhrase(parts)
  }

  // MARK: - Drill-down

  public static func matches(_ l: InsightsLine, _ target: InsightsTarget) -> Bool {
    switch target {
    case .bucket(.savings): l.kind == .saved
    case .bucket(let b): l.kind == .spent && l.bucket == b
    case .category(let c): l.kind != .income && l.categoryID == c
    case .merchant(let m): l.kind == .spent && l.merchant == m
    }
  }

  public static func drill(_ s: LedgerState, target: InsightsTarget, months: ClosedRange<YearMonth>,
                           now: LocalDateTime) -> InsightsDrill {
    let ctx = context(s, months: months, now: now)
    let mine = ctx.current.filter { matches($0, target) }
    let total = mine.reduce(Int64(0)) { $0 + $1.minor }
    let count = Set(mine.map(\.txnID)).count

    let name: String
    switch target {
    case .bucket(.savings): name = "Savings"
    case .bucket(let b): name = b == .needs ? "Needs" : "Wants"
    case .category(let c): name = s.category(c)?.name ?? "Category"
    case .merchant(let m): name = m
    }

    var line: [MoneyPhrase.Part] = [.text("\(count) transaction\(count == 1 ? "" : "s")")]
    if let comparison = ctx.comparison {
      let before = ctx.previous.filter { matches($0, target) }.reduce(Int64(0)) { $0 + $1.minor }
      let diff = total - before
      if diff == 0 {
        line.append(.text(" · same as \(comparison.name)"))
      } else {
        line += [.text(" · "), .amount(.aed(abs(diff))),
                 .text(diff < 0 ? " less than \(comparison.name)" : " more than \(comparison.name)")]
      }
    }

    let order = Dictionary(s.categories.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    var categories: [InsightsDrillCategory] = []
    if case .bucket = target {
      var acc: [CategoryID: (count: Int, amount: Int64)] = [:]
      for l in mine {
        acc[l.categoryID, default: (0, 0)].count += 1
        acc[l.categoryID, default: (0, 0)].amount += l.minor
      }
      categories = acc.map { id, a in
        InsightsDrillCategory(id: id, title: s.category(id)?.name ?? id, count: a.count, amount: .aed(a.amount))
      }.sorted { a, b in
        a.amount.minor != b.amount.minor ? a.amount.minor > b.amount.minor : (order[a.id] ?? 0) < (order[b.id] ?? 0)
      }
    }

    let sorted = mine.sorted { a, b in
      a.postedAt != b.postedAt ? a.postedAt > b.postedAt : (a.txnID, a.part) < (b.txnID, b.part)
    }
    let shown: [InsightsLine]
    let rowsTitle: String
    if case .bucket = target, sorted.count > latestLimit {
      shown = Array(sorted.prefix(latestLimit))
      rowsTitle = "Latest of \(count)"
    } else {
      shown = sorted
      rowsTitle = "Transactions"
    }
    let rows = shown.map { l in
      let c = s.category(l.categoryID)
      return InsightsDrillRow(
        id: "\(l.txnID).\(l.part)", txnID: l.txnID, merchant: l.merchant, glyph: c?.glyph ?? .tag, hue: c?.hue ?? .other,
        detail: "\(c?.name ?? "Uncategorized") · \(l.postedAt.date.short)", amount: .aed(l.minor))
    }
    return InsightsDrill(
      target: target, title: "\(name) · \(ctx.focus.name)", total: .aed(total), transactions: count,
      line: MoneyPhrase(line), categories: categories, rowsTitle: rowsTitle, rows: rows)
  }
}

private extension String {
  var dropCategory: String { hasPrefix("category.") ? String(dropFirst("category.".count)) : self }
}
