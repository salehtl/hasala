// Bills · Coming up and found: what is due, what needs a look, what the
// detector found in the history, upcoming and recently paid.
//
// TODO(03b §3.12): the detector, late and price-change logic come from CoreDomain's
// Bills engine; here they are read from the bill records as the mock stores them.

public struct BillAttention: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable { case late(days: Int), priceChange(usual: Money) }

  public var id: BillID
  public var name: String
  public var glyph: Glyph
  public var kind: Kind
  public var amount: Money
  /// "Car insurance usually arrives on the 7th. No bank email yet."
  public var body: MoneyPhrase
}

public struct BillCandidateModel: Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var amount: Money
  /// "Seen 5×", "Every ~30 days", "Last on 8 Oct".
  public var evidence: [String]
  public var seenCount: Int
}

public struct BillsSnapshot: Sendable, Hashable {
  public enum Range: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case week = 7, fortnight = 14, month = 30
    public var id: Int { rawValue }
    public var title: String { "\(rawValue) days" }
  }

  /// Bills due in the next 14 days, late ones included.
  public var next14: Money
  /// "+25,000.00 expected Wed 28 Oct".
  public var incomeLine: MoneyPhrase?
  public var needsALook: [BillAttention]
  public var found: [BillCandidateModel]
  public var upcoming: [BillRowModel]
  public var range: Range
  public var tracked: Int
  public var recentlyPaid: [BillRowModel]
  /// Bills paid this month.
  public var paidThisMonth: Money
}

public enum BillsEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime, range: BillsSnapshot.Range = .month)
    -> BillsSnapshot
  {
    let today = now.date
    let tracked = s.bills.filter { $0.state == .tracked }
    let in14 = today.adding(days: 14)
    let next14 = tracked.filter { !$0.isIncome && $0.nextDue <= in14 }.reduce(Int64(0)) { $0 + $1.amount.minor }

    let income = tracked.filter { $0.isIncome && $0.nextDue >= today }.min { $0.nextDue < $1.nextDue }
    let incomeLine = income.map {
      MoneyPhrase([.signedMoney($0.amount, style: .exact, hiddenGlyphs: 4), .text(" expected \($0.nextDue.short)")])
    }

    var attention: [BillAttention] = []
    for b in tracked where !b.isIncome && b.nextDue < today {
      attention.append(BillAttention(
        id: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), kind: .late(days: b.nextDue.days(until: today)),
        amount: b.amount,
        body: MoneyPhrase(stringLiteral:
          "\(b.kind) usually arrives on the \(PlanEngine.ordinal(b.usualDay)). No bank email yet.")
      ))
    }
    for b in tracked where !b.isIncome {
      guard let usual = b.priceChangeFrom else { continue }
      let last = b.history.first.map { " on \($0.short)" } ?? ""
      attention.append(BillAttention(
        id: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), kind: .priceChange(usual: usual),
        amount: b.amount,
        body: MoneyPhrase([
          .text("Charged "), .amount(.aed(b.amount.minor - usual.minor)), .text(" more than usual ("),
          .amount(usual), .text(")\(last)."),
        ])
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
    let paidRows = paid.map { t in
      let b = t.billID.flatMap(s.bill)
      var detail: [PlanDetailPart] = []
      if b?.priceChangeFrom != nil { detail.append(.status("Price change", .warning)) }
      detail.append(.text(MoneyPhrase(stringLiteral:
        "\(t.postedAt.date.short)" + (s.account(t.accountID).map { " · \($0.shortName)" } ?? ""))))
      return BillRowModel(
        id: t.id, name: b?.name ?? t.merchant, glyph: s.category(t.categoryID)?.glyph ?? .utilities,
        hue: s.category(t.categoryID)?.hue ?? .sand, detail: detail, amount: t.amount, approximate: false,
        isIncome: false, trailingNote: nil
      )
    }

    return BillsSnapshot(
      next14: .aed(next14), incomeLine: incomeLine, needsALook: attention, found: found, upcoming: upcoming,
      range: range, tracked: tracked.count, recentlyPaid: paidRows,
      paidThisMonth: .aed(paid.reduce(0) { $0 + $1.amount.minor })
    )
  }

  static func upcomingRow(_ b: Bill, _ s: LedgerState, today: LocalDate) -> BillRowModel {
    let detail: [PlanDetailPart]
    if b.nextDue < today {
      detail = [.status("Late", .error), .text(MoneyPhrase(stringLiteral: "usually the \(PlanEngine.ordinal(b.usualDay))"))]
    } else {
      detail = [.text(MoneyPhrase(stringLiteral:
        "\(b.nextDue.short) · \(ActivityEngine.inDays(today.days(until: b.nextDue)))"))]
    }
    return BillRowModel(
      id: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), hue: ActivityEngine.hue(b, s), detail: detail,
      amount: b.amount, approximate: b.approximate, isIncome: b.isIncome, trailingNote: nil
    )
  }
}
