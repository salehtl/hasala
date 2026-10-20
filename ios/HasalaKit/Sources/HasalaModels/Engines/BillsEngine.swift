// Bills · Coming up and found: what is due, what needs a look, what the
// detector found in the history, upcoming and recently paid; and one bill's detail
// (Bills · AXA Insurance (late)).
//
// TODO(03b §3.12): the detector, late and price-change logic come from CoreDomain's
// Bills engine; here they are read from the bill records as the mock stores them.

public struct BillAttention: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable { case late(days: Int), priceChange(usual: Money) }

  public var id: BillID
  public var name: String
  public var glyph: Glyph
  public var kind: Kind
  /// What the bill pays for, as the ledger names it ("Car insurance", "Mobile and internet");
  /// the poster's glyph follows it where Paper's card does (du's wifi).
  public var billKind: String
  public var amount: Money
  /// "Car insurance usually arrives on the 7th. No bank email yet."
  public var body: MoneyPhrase
  /// The poster's pill: "3 days past usual" for a bill that may be late (a short chip says
  /// what we noticed, never "late"), "Price change" for a new amount.
  public var pill: StatusPill
}

public struct BillCandidateModel: Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var amount: Money
  /// "Seen 5×", "Every ~30 days", "Last on 8 Oct".
  public var evidence: [String]
  public var seenCount: Int
}

/// The hero's income line: "Salary +25,000.00 expected Wed 28 Oct".
public struct BillsIncome: Sendable, Hashable {
  /// "Salary".
  public var label: String
  public var amount: Money
  /// "expected Wed 28 Oct".
  public var expected: String

  public init(label: String, amount: Money, expected: String) {
    self.label = label
    self.amount = amount
    self.expected = expected
  }
}

public struct BillsSnapshot: Sendable, Hashable {
  public enum Range: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case week = 7, fortnight = 14, month = 30
    public var id: Int { rawValue }
    public var title: String { "\(rawValue) days" }
  }

  /// Bills due in the next 14 days, late ones included.
  public var next14: Money
  public var next14Mark: TotalMark?
  /// "+25,000.00 expected Wed 28 Oct".
  public var incomeLine: MoneyPhrase?
  /// The same line in its parts, for the hero (label, figure and date are drawn apart).
  public var income: BillsIncome?
  public var needsALook: [BillAttention]
  public var found: [BillCandidateModel]
  public var upcoming: [BillRowModel]
  public var range: Range
  public var tracked: Int
  public var recentlyPaid: [BillRowModel]
  /// Bills paid this month.
  public var paidThisMonth: Money
  /// A tag after a row's title, by row id ("Price change" on du's payment).
  public var tags: [String: StatusPill]
  public var paidMark: TotalMark?
}

/// One bill (Bills · AXA Insurance (late)): what we noticed, its payment history and what
/// can be done about it.
public struct BillDetail: Sendable, Hashable, Identifiable {
  public enum State: Sendable, Hashable {
    /// Past its usual day with no bank email yet.
    case late(days: Int)
    /// The last charge was outside the usual range.
    case priceChange(usual: Money)
    /// Expected, and not yet due.
    case upcoming
    /// Money in (a salary), expected.
    case income
  }

  public var id: BillID
  public var name: String
  /// The overline: "Car insurance".
  public var kind: String
  public var glyph: Glyph
  /// The hero disc's hue (the category's bucket).
  public var hue: Hue
  public var state: State
  /// "3 days past usual", "Price change", "Due in 4 days", "Expected in 18 days".
  public var pill: StatusPill
  public var amount: Money
  /// Shown with "~" (DEWA varies).
  public var approximate: Bool
  /// "every month · usually the 7th · Emirates NBD".
  public var cadence: String
  /// "What we noticed": a bill that may be late or changed price says why we think so.
  public var noticed: MoneyPhrase?
  /// The expected payment first (when one is due), then past payments, newest first.
  public var history: [BillHistoryStep]
  /// "6 on time" beside the Payment history title.
  public var historyNote: String?
  /// "Recurring payments are found from your history. Nothing is shared with AXA Insurance."
  public var footnote: String

  public var isLate: Bool {
    if case .late = state { return true }
    return false
  }

  public var isPriceChange: Bool {
    if case .priceChange = state { return true }
    return false
  }

  public var isIncome: Bool { state == .income }
}

/// One step of a bill's payment history timeline.
public struct BillHistoryStep: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable {
    /// The payment we expect: `late` when its day has passed with no bank email.
    case expected(late: Bool)
    case paid
  }

  public var id: Int { date.ordinal }
  public var date: LocalDate
  public var kind: Kind
  /// Under the date of an expected step: "Expected · no bank email yet", "Expected · in 4 days".
  public var note: String?
  public var amount: Money

  /// "Wed 7 Oct".
  public var title: String { date.short }
}

public enum BillsEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime, range: BillsSnapshot.Range = .month)
    -> BillsSnapshot
  {
    let today = now.date
    let tracked = s.bills.filter { $0.state == .tracked }
    let in14 = today.adding(days: 14)
    let next14 = s.homeTotal(tracked.filter { !$0.isIncome && $0.nextDue <= in14 }.map(\.amount))

    let incomeBill = tracked.filter { $0.isIncome && $0.nextDue >= today }.min { $0.nextDue < $1.nextDue }
    let incomeLine = incomeBill.map {
      MoneyPhrase([.signedMoney($0.amount, style: .exact, hiddenGlyphs: 4), .text(" expected \($0.nextDue.short)")])
    }
    let income = incomeBill.map {
      BillsIncome(label: $0.kind, amount: $0.amount, expected: "expected \($0.nextDue.short)")
    }

    var attention: [BillAttention] = []
    for b in tracked where !b.isIncome && b.nextDue < today {
      let days = b.nextDue.days(until: today)
      attention.append(BillAttention(
        id: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), kind: .late(days: days), billKind: b.kind,
        amount: b.amount,
        body: MoneyPhrase(stringLiteral:
          "\(b.kind) usually arrives on the \(PlanEngine.ordinal(b.usualDay)). No bank email yet."),
        pill: StatusPill(pastUsual(days), tone: .error)
      ))
    }
    for b in tracked where !b.isIncome {
      guard let usual = b.priceChangeFrom else { continue }
      attention.append(BillAttention(
        id: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), kind: .priceChange(usual: usual),
        billKind: b.kind, amount: b.amount, body: priceChange(b, usual: usual),
        pill: StatusPill("Price change", tone: .warning)
      ))
    }

    let found = s.billCandidates.map { c in
      BillCandidateModel(
        id: c.id, name: c.name, amount: c.amount,
        evidence: ["Seen \(c.seenCount)×", "Every ~\(c.everyDays) days", "Last on \(c.last.dayMonth)"],
        seenCount: c.seenCount
      )
    }

    let horizon = today.adding(days: range.rawValue)
    let upcoming = tracked.filter { $0.nextDue <= horizon && $0.priceChangeFrom == nil }
      .filter { s.category($0.categoryID)?.role != .saving }
      .sorted { $0.nextDue < $1.nextDue }
      .map { upcomingRow($0, s, today: today) }

    let month = today.yearMonth
    let paid = s.txns.filter {
      $0.countsInPlan && $0.billID != nil && $0.postedAt.date.yearMonth == month && $0.direction == .out
        && s.category($0.categoryID)?.role == .bill
    }.sorted { $0.postedAt > $1.postedAt }
    var tags: [String: StatusPill] = [:]
    let paidRows = paid.map { t in
      let b = t.billID.flatMap(s.bill)
      if b?.priceChangeFrom != nil { tags[t.id] = StatusPill("Price change", tone: .warning, showsDot: false) }
      let detail: [PlanDetailPart] = [.text(MoneyPhrase(stringLiteral:
        "\(t.postedAt.date.short)" + (s.account(t.accountID).map { " · \($0.shortName)" } ?? "")))]
      return BillRowModel(
        id: t.id, name: b?.name ?? t.merchant, glyph: s.category(t.categoryID)?.glyph ?? .utilities,
        hue: s.category(t.categoryID)?.hue ?? .sand, detail: detail, amount: t.amount, approximate: false,
        isIncome: false, trailingNote: nil
      )
    }

    return BillsSnapshot(
      next14: next14.money, next14Mark: next14.mark, incomeLine: incomeLine, income: income, needsALook: attention, found: found,
      upcoming: upcoming, range: range, tracked: tracked.count, recentlyPaid: paidRows,
      paidThisMonth: .aed(Fils.sum(paid) { $0.homeMinor ?? 0 }), tags: tags, paidMark: TotalMark.unrated(paid)
    )
  }

  static func upcomingRow(_ b: Bill, _ s: LedgerState, today: LocalDate) -> BillRowModel {
    let detail: [PlanDetailPart]
    if b.nextDue < today {
      // A short chip says what we noticed (page 16 §12): "Expected the 7th".
      detail = [.status("Expected the \(PlanEngine.ordinal(b.usualDay))", .error)]
    } else {
      detail = [.text(MoneyPhrase(stringLiteral:
        "\(b.nextDue.short) · \(ActivityEngine.inDays(today.days(until: b.nextDue)))"))]
    }
    return BillRowModel(
      id: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), hue: ActivityEngine.hue(b, s), detail: detail,
      amount: b.amount, approximate: b.approximate, isIncome: b.isIncome, trailingNote: nil
    )
  }

  /// "3 days past usual" (a day, or days).
  static func pastUsual(_ days: Int) -> String {
    "\(days) day\(days == 1 ? "" : "s") past usual"
  }

  /// "Charged 38.90 more than usual (389.00) on Mon 5 Oct."
  static func priceChange(_ b: Bill, usual: Money) -> MoneyPhrase {
    let last = b.history.first.map { " on \($0.short)" } ?? ""
    let difference = b.amount.minor.minus(usual.minor)
    return MoneyPhrase([
      .text("Charged "), .amount(.aed(Int64(clamping: difference.magnitude))), .text(" \(difference < 0 ? "less" : "more") than usual ("),
      .amount(usual), .text(")\(last)."),
    ])
  }

  // MARK: One bill

  /// A payment counts as on time within this many days of the usual day.
  static let onTimeWindow = 3

  /// One tracked bill, or nil when it isn't tracked (stopped, or never was).
  public static func detail(_ s: LedgerState, now: LocalDateTime, bill id: BillID) -> BillDetail? {
    guard let b = s.bill(id), b.state == .tracked else { return nil }
    let today = now.date
    let usualDay = PlanEngine.ordinal(b.usualDay)
    let untilDue = today.days(until: b.nextDue)

    let state: BillDetail.State
    let pill: StatusPill
    if b.isIncome {
      state = .income
      pill = StatusPill("Expected \(ActivityEngine.inDays(max(0, untilDue)))", tone: .success)
    } else if b.nextDue < today {
      state = .late(days: -untilDue)
      pill = StatusPill(pastUsual(-untilDue), tone: .error)
    } else if let usual = b.priceChangeFrom {
      state = .priceChange(usual: usual)
      pill = StatusPill("Price change", tone: .warning)
    } else {
      state = .upcoming
      pill = StatusPill("Due \(ActivityEngine.inDays(untilDue))", tone: .accent)
    }

    var cadence = ["every month", "usually the \(usualDay)"]
    if let account = s.account(b.accountID) { cadence.append(account.shortName) }

    let noticed: MoneyPhrase?
    switch state {
    case .late:
      noticed = MoneyPhrase(stringLiteral: lateNotice(b) + " This month there's no bank email yet.")
    case .priceChange(let usual):
      noticed = priceChange(b, usual: usual)
    case .upcoming, .income:
      noticed = nil
    }

    // The payment we expect leads the timeline, unless the bill changed price (its last
    // charge is the news, and the next one is a month away).
    var steps: [BillHistoryStep] = []
    switch state {
    case .late:
      steps.append(BillHistoryStep(date: b.nextDue, kind: .expected(late: true),
                                   note: "Expected · no bank email yet", amount: b.amount))
    case .upcoming, .income:
      steps.append(BillHistoryStep(date: b.nextDue, kind: .expected(late: false),
                                   note: "Expected · \(ActivityEngine.inDays(untilDue))", amount: b.amount))
    case .priceChange:
      break
    }
    for (i, date) in b.history.enumerated() {
      steps.append(BillHistoryStep(date: date, kind: .paid, note: nil, amount: paidAmount(b, s, on: date, index: i)))
    }

    let onTime = b.history.filter { abs($0.day - b.usualDay) <= onTimeWindow }.count
    let historyNote: String? = b.history.isEmpty
      ? nil : onTime == b.history.count ? "\(onTime) on time" : "\(onTime) of \(b.history.count) on time"

    return BillDetail(
      id: b.id, name: b.name, kind: b.kind, glyph: ActivityEngine.glyph(b, s), hue: ActivityEngine.hue(b, s),
      state: state, pill: pill, amount: b.amount, approximate: b.approximate,
      cadence: cadence.joined(separator: " · "), noticed: noticed, history: steps, historyNote: historyNote,
      footnote: "Recurring payments are found from your history. Nothing is shared with \(payee(b))."
    )
  }

  /// "Your last 6 payments arrived between the 6th and 8th." (or on one day, or the usual day).
  static func lateNotice(_ b: Bill) -> String {
    let days = b.history.map(\.day)
    guard let low = days.min(), let high = days.max() else {
      return "It usually arrives on the \(PlanEngine.ordinal(b.usualDay))."
    }
    let count = days.count
    let subject = count == 1 ? "Your last payment" : "Your last \(count) payments"
    return low == high
      ? "\(subject) arrived on the \(PlanEngine.ordinal(low))."
      : "\(subject) arrived between the \(PlanEngine.ordinal(low)) and \(PlanEngine.ordinal(high))."
  }

  /// What a past payment was: the bill's own transaction that day, or else the amount it
  /// had then (the usual one before a price change).
  static func paidAmount(_ b: Bill, _ s: LedgerState, on date: LocalDate, index: Int) -> Money {
    if let t = s.txns.first(where: { $0.billID == b.id && $0.postedAt.date == date }) { return t.amount }
    if let usual = b.priceChangeFrom, index > 0 { return usual }
    return b.amount
  }

  /// Who the bill is paid to: "Al Habtoor" in "Rent · Al Habtoor", else the bill's name.
  static func payee(_ b: Bill) -> String {
    guard let range = b.name.firstRange(of: " · ") else { return b.name }
    return String(b.name[range.upperBound...])
  }
}
