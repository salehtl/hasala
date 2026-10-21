import CoreCategorize
import CoreDomain
import CoreMailbox
import CoreProjection
import CoreReplay
import CoreTime
import Foundation
import HasalaModels

/// The projection (`projection.sqlite` through `LedgerReader`) as the screens' read model,
/// HasalaKit's `LedgerState` (spec 04 §15.1-§15.2): categories, accounts, transactions,
/// the plan, bills, projects, goals and rules at one instant. The screens' engines
/// (`HomeEngine`, `PlanEngine`, `ActivityEngine`, `BillsEngine`, `ReviewEngine`) run over it
/// unchanged, so a live account shows the same boards as the Maya mock (AT-REV-3).
///
/// Every figure comes from the fold: budgets are CoreDomain's `PlanEngine.assigned`
/// (carry-forward and moves applied), a bill's next due date is its schedule minus the
/// resolved occurrences, a balance is the latest check-in. What no op family holds (the
/// detector's bill proposals, review suggestions, row detail overrides) is left empty.
nonisolated enum LedgerStateMapper {
  typealias BillRecord = CoreReplay.Bill

  /// What the projection doesn't hold: who is signed in, the mailbox's health and the
  /// device's own preferences.
  struct Context: Sendable {
    var today: LocalDate
    var profile: ProfileInfo
    var mailbox = MailboxHealth(status: .notConnected, lastEmail: "", banks: "")
    var prefs = DevicePrefs()
    /// The review cards skipped today, as digests (`DevicePrefsStore`), and their salt.
    var skippedDigests: Set<String> = []
    var digestSalt = ""
    var unreadSenders: [String: String] = [:]
    var dismissedNotices: Set<String> = []
    var forkRecords: [String: CoreReplay.Bill] = [:]
  }

  enum MapError: Error { case date }

  /// Display names of the banks the beta reads (card accounts name their bank by id).
  static let bankNames = RuntimeMailboxLedger.bankNames

  static func map(_ r: LedgerReader, context c: Context) throws -> LedgerState {
    guard let today = CivilDate(year: c.today.year, month: c.today.month, day: c.today.day) else { throw MapError.date }
    let month = today.yearMonth
    let taxonomy = try r.taxonomy()
    let records = try r.bills()
    let resolutions = try r.billResolutions()
    var rows = try r.activity(limit: 1_000_000)
    rows += try r.archived(limit: 1_000_000)
    let home = try r.homeCurrency() ?? "AED"
    let derived = derive(records, resolutions: resolutions, rows: rows, today: today)
    let roles = CoreDomain.PlanEngine(plan: try r.planState(), taxonomy: taxonomy, lines: [], today: today)
    let expectations = expectations(
      records, derived: derived, month: month, today: today, home: home, role: { roles.role($0) })
    let engine = try r.planEngine(month: month, today: today, bills: expectations)

    let categories = taxonomy.ordered.map { category($0, engine: engine) }
    let matched = derived.matched
    let billOfTxn = billOfTxn(records, resolutions: resolutions, matched: matched)

    // Accounts: the latest check-in is the balance (03b §4.6).
    let cards = try r.cards()
    let checkins = try r.checkins()
    let liveAccounts = try r.accounts().filter(\.active)
    let accounts: [HasalaModels.Account] = liveAccounts.map { a in
      let card = cards.first { $0.account == a.id && $0.state == "mine" }
      let balance = checkins.first { $0.account == a.id && !$0.void }?.balanceMinor ?? 0
      return HasalaModels.Account(
        id: a.id, name: a.name, shortName: shortName(a), last4: card?.last4, kind: accountKind(a.kind),
        balance: Money(minor: balance, currency: a.currency), inPlan: a.inPlan, detail: "")
    }

    // Transactions: every live, parsed row (archived ones too, flagged).
    let rules = try r.rules()
    let ruleByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var txns: [HasalaModels.Txn] = []
    txns.reserveCapacity(rows.count)
    for row in rows {
      txns.append(try txn(row, r: r, ruleByID: ruleByID, billID: billOfTxn[row.id]))
    }
    markSamePurchases(&txns, rows: rows, home: home)
    let unreadMail = try r.review(lanes: [.unreadable], limit: 1_000_000).map {
      unreadMail($0, senders: c.unreadSenders, accounts: liveAccounts)
    }

    // The plan: CoreDomain's assigned budgets around this month, the income sources.
    var budgets: [String: Money] = [:]
    var incomeByMonth: [YearMonth: Money] = [:]
    let months = [month.adding(months: -1), month, month.adding(months: 1)].compactMap { $0 }
    for m in months {
      incomeByMonth[YearMonth(m.year, m.month)] = .aed(engine.income(m).total)
      for info in taxonomy.ordered where info.kind == .spending {
        let v = engine.assigned(m, info.id)
        if v != 0 { budgets[HasalaModels.PlanState.key(info.id, YearMonth(m.year, m.month))] = .aed(v) }
      }
    }
    let sources = engine.plan.incomeSources.values.filter(\.active)
    let split = try r.budgetTemplate()
    let plan = HasalaModels.PlanState(
      income: .aed(Fils.sum(sources.map(\.amountMinor))), payday: Int(sources.first?.payday ?? 28),
      startingSplit: split.map { [Int($0.need), Int($0.want), Int($0.saving)] } ?? [50, 30, 20], budgets: budgets,
      incomeByMonth: incomeByMonth)

    var bills: [HasalaModels.Bill] = []
    let paidAmount = Dictionary(txns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var byBill: [String: [BillResolution]] = [:]
    for res in resolutions { byBill[res.bill, default: []].append(res) }
    let current = Dictionary(records.map { ($0.id, $0.bill) }, uniquingKeysWith: { a, _ in a })
    let forks = forkNotices(try r.forkNotices(kind: "bill"), records: current, losers: c.forkRecords)
    for (id, b) in records {
      if var mapped = bill(
        id: id, b, resolutions: byBill[id] ?? [], matched: matched[id] ?? [], result: derived.result,
        notices: derived.notices[id] ?? [], today: c.today, taxonomy: taxonomy, paidAmount: paidAmount)
      {
        mapped.notices += forks[id] ?? []
        mapped.notices = notices(mapped.notices, dismissed: c.dismissedNotices, salt: c.digestSalt)
        if let usual = mapped.priceChangeFrom, let txn = mapped.payments.first?.txnID,
          !mapped.notices.contains(where: { $0.id == "priceChange.\(txn)" })
        {
          mapped.amount = usual
          mapped.priceChangeFrom = nil
        }
        bills.append(mapped)
      }
    }
    let billCandidates = candidates(derived.candidates, taxonomy: taxonomy)
    for s in engine.plan.incomeSources.values {
      bills.append(income(s, today: c.today, taxonomy: taxonomy))
    }

    let projects: [HasalaModels.Project] = try r.projects().map { id, p in
      HasalaModels.Project(
        id: id, name: p.name, glyph: glyph(p.icon ?? "flag"), budget: p.budgetMinor.map { .aed($0) },
        starts: p.startsOn.flatMap(CivilDate.init(wire:)).map(local),
        ends: p.endsOn.flatMap(CivilDate.init(wire:)).map(local), countInPlan: p.countInPlan,
        complete: p.status == "completed", completedOn: p.completedOn.flatMap(CivilDate.init(wire:)).map(local),
        startVerb: p.icon == "plane" ? "flies" : "starts")
    }

    let goals: [HasalaModels.Goal] = try r.goals().compactMap { id, g in
      guard g.status == "active", let category = g.source.categoryID else { return nil }
      let by = g.targetMonth.flatMap(CivilMonth.init(wire:)).map { YearMonth($0.year, $0.month) } ?? c.today.yearMonth
      let progress = engine.goalProgress(id: id, g, month: month)
      return HasalaModels.Goal(
        id: id, name: g.name, glyph: glyph(g.icon ?? "jar"), categoryID: category, target: .aed(g.targetMinor),
        saved: .aed(progress.progress), by: by)
    }

    let mappedRules: [HasalaModels.Rule] = rules.map { rule in
      HasalaModels.Rule(
        id: rule.id, patterns: rule.patterns, match: ruleMatch(rule.match), categoryID: rule.category,
        enabled: rule.enabled,
        learnedToday: rule.origin == "learned" && rule.createdAt.flatMap(localDay) == c.today)
    }

    return LedgerState(
      categories: categories, accounts: accounts, txns: txns, plan: plan, bills: bills, billCandidates: billCandidates,
      projects: projects, goals: goals, rules: mappedRules, profile: c.profile, mailbox: c.mailbox, prefs: c.prefs,
      netWorth: NetWorthHistory(), skippedReview: skipped(txns, c),
      rates: try r.rates().map { CurrencyRate(currency: $0.currency, rateMicro: $0.rateMicro, updatedAt: $0.updatedAt) },
      unreadMail: unreadMail)
  }

  static func unreadMail(_ row: TxnRow, senders: [String: String] = [:], accounts: [CoreReplay.Account] = []) -> UnreadMail {
    let bank = row.mailboxMessageID.flatMap { senders[$0] }.flatMap { Self.bank(domain: $0) }
    let ofBank = accounts.filter { a in bank.map { a.institution == $0 } ?? false }
    return UnreadMail(
      id: row.id, provider: row.sourceProvider.flatMap(MailProviderKind.init(rawValue:)),
      receivedOn: CivilDate(wire: row.localDate).map(local) ?? LocalDate(1970, 1, 1),
      bank: bank.flatMap { bankNames[$0] }, accountID: (ofBank.first(where: \.inPlan) ?? ofBank.first)?.id)
  }

  /// The transactions whose digest is among the skipped cards'.
  static func skipped(_ txns: [HasalaModels.Txn], _ c: Context) -> Set<TxnID> {
    guard !c.skippedDigests.isEmpty else { return [] }
    return Set(txns.lazy.map(\.id).filter { c.skippedDigests.contains(LocalAccountData.digest($0, salt: c.digestSalt)) })
  }

  // MARK: Categories

  static func category(_ info: CategoryInfo, engine: CoreDomain.PlanEngine) -> HasalaModels.Category {
    let kind: HasalaModels.CategoryKind
    let bucket: HasalaModels.Bucket
    let role: CategoryRole
    switch (info.kind, info.bucket) {
    case (.spending, .saving?):
      (kind, bucket, role) = (.spending, .savings, .saving)
    case (.spending, let b):
      let isBill = engine.role(info.id) == "bills"
      (kind, bucket, role) = (.spending, b == .want ? .wants : .needs, isBill ? .bill : .everyday)
    case (.income, _):
      (kind, bucket, role) = (.income, .income, .none)
    case (.excluded, _):
      (kind, bucket, role) = (.excluded, .other, .none)
    }
    return HasalaModels.Category(
      id: info.id, name: info.name, kind: kind, bucket: bucket, glyph: glyph(info.icon), role: role,
      archived: !info.active)
  }

  /// 03c §1.7 icon tokens → HasalaModels' glyphs (the inverse of the seed export's table).
  static let glyphs: [String: Glyph] = [
    "house": .rent, "bolt": .utilities, "basket": .groceries, "car": .transport, "cross": .healthcare,
    "shield_check": .insurance, "fork_knife": .dining, "ticket": .entertainment, "bag": .shopping, "plane": .travel,
    "repeat": .subscriptions, "jar": .savingsJar, "trend": .investments, "card": .debt, "briefcase": .salary,
    "laptop": .freelance, "arrows_swap": .transfer, "receipt": .refunds, "flag": .flag, "tag": .tag,
  ]

  static func glyph(_ icon: String) -> Glyph { glyphs[icon] ?? .tag }

  static func icon(_ glyph: Glyph) -> String {
    glyphs.filter { $0.value == glyph }.map(\.key).sorted().first ?? "flag"
  }

  // MARK: Accounts

  static func accountKind(_ kind: String) -> AccountKind {
    switch kind {
    case "credit_card": .credit
    case "cash": .cash
    case "investment": .investment
    default: .current
    }
  }

  /// How rows name an account: "Emirates NBD", "DIB card"; otherwise its own name.
  static func shortName(_ a: CoreReplay.Account) -> String {
    guard let bank = a.institution, let name = bankNames[bank] else { return a.name }
    return a.kind == "credit_card" ? "\(name) card" : name
  }

  // MARK: Transactions

  static func txn(_ row: TxnRow, r: LedgerReader, ruleByID: [String: RuleRow], billID: String?) throws
    -> HasalaModels.Txn
  {
    let date = CivilDate(wire: row.localDate).map(local) ?? LocalDate(1970, 1, 1)
    let minutes = Int(((row.postedMs + LocalClock.offsetMs) % 86_400_000 + 86_400_000) % 86_400_000 / 60_000)
    let at = LocalDateTime(date: date, hour: minutes / 60, minute: minutes % 60)
    let timeKnown = row.postedPrecision != "day"
    var splits: [SplitLine] = []
    if row.split {
      splits = try r.parts(row.id).map {
        SplitLine(id: $0.idx, categoryID: $0.category, amount: Money(minor: $0.amountMinor, currency: row.currency),
                  homeMinor: .some($0.amountHomeMinor), note: $0.note ?? "")
      }
    }
    let source: HasalaModels.CategorySource? =
      switch row.categorySource {
      case "rule": .rule(pattern: row.categorySourceRef.flatMap { ruleByID[$0]?.patterns.first } ?? "")
      case "dictionary": .dictionary
      case "model": .model(tag: row.categorySourceRef)
      case "user", "held": .user
      default: nil
      }
    let provenance = row.entryMethod == "mailbox"
      ? Provenance(
        title: "\(row.bank.flatMap { bankNames[$0] } ?? "Bank") transaction alert",
        readAt: timeKnown ? "Read automatically at \(at.time)" : "Read automatically", rawMerchant: row.merchantRaw,
        senderCheck: row.senderCheck)
      : nil
    return HasalaModels.Txn(
      id: row.id, merchant: row.displayName, place: row.location, amount: Money(minor: row.amountMinor, currency: row.currency),
      homeMinor: .some(row.amountHomeMinor),
      homeSource: .some(row.homeSource.flatMap { HasalaModels.HomeSource(rawValue: $0.rawValue) }), homeRateMicro: row.homeRateMicro,
      direction: row.direction == "credit" ? .in : .out, postedAt: at, postedTimeKnown: timeKnown, accountID: row.effectiveAccountID,
      categoryID: row.category, categorySource: source, needsReview: row.needsReview, isNewMerchant: row.isNewMerchant,
      suggestion: nil, note: row.note ?? "", splits: splits,
      isRefund: row.category == "refunds" || row.refundState != nil,
      isTransfer: row.category == "transfer" || row.transferState != nil, archived: row.archived != nil,
      projectID: row.projectID, billID: billID, provenance: provenance,
      detailOverride: billID != nil ? "monthly bill" : nil, mailboxMessageID: row.mailboxMessageID,
      heldCopy: try heldCopy(row, r: r),
      reviewReason: row.reviewReason.flatMap { TxnReviewReason(rawValue: $0.rawValue) }, merchantKey: row.merchantKey)
  }


  static func samePurchaseRow(_ row: TxnRow) -> SamePurchase.Row {
    SamePurchase.Row(
      id: row.id, live: row.supersededBy == nil, unparsed: row.unparsed, archived: row.archived != nil,
      manual: row.entryMethod == "manual", amountMinor: row.amountMinor, currency: row.currency,
      amountHomeMinor: row.amountHomeMinor, direction: row.direction, bank: row.bank, last4: row.last4,
      postedMs: row.postedMs, merchantKey: row.merchantKey, possibleDuplicateOf: row.possibleDuplicateOf,
      duplicateDisposition: row.duplicateDisposition, heldCopy: row.heldCopy)
  }

  static func markSamePurchases(_ txns: inout [HasalaModels.Txn], rows: [TxnRow], home: String) {
    let pairs = SamePurchase.pairs(rows.map(samePurchaseRow), home: home)
    guard !pairs.isEmpty else { return }
    let index = Dictionary(txns.indices.map { (txns[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
    for p in pairs {
      guard let i = index[p.home], index[p.foreign] != nil else { continue }
      txns[i].samePurchase = SamePurchaseMatch(of: p.foreign, merchantMissing: p.merchantMissing)
    }
  }

  static func heldCopy(_ row: TxnRow, r: LedgerReader) throws -> HeldCopy? {
    guard row.heldCopy, let other = row.copyOf else { return nil }
    let source = try r.txn(other)?.sourceMailbox
    return HeldCopy(of: other, fromOtherInbox: source != row.sourceMailbox)
  }

  // MARK: Bills

  struct DerivedMatch: Sendable, Equatable {
    var due: CivilDate
    var txnID: String
  }

  struct Derived: Sendable {
    var result: BillMatcherResult
    var matched: [String: [DerivedMatch]]
    var notices: [String: [BillNoticeCore]]
    var days: [String: CivilDate]
    var candidates: [BillCandidateCore]
  }

  static func billEligible(_ row: TxnRow) -> Bool {
    row.direction == "debit" && BillEdits.linkable(row, direction: "debit")
  }

  static func derive(
    _ records: [(id: String, bill: CoreReplay.Bill)], resolutions: [BillResolution], rows: [TxnRow], today: CivilDate
  ) -> Derived {
    var match: [MatchRow] = []
    var detect: [DetectRow] = []
    var days: [String: CivilDate] = [:]
    match.reserveCapacity(rows.count)
    detect.reserveCapacity(rows.count)
    for row in rows {
      guard let day = CivilDate(wire: row.localDate) else { continue }
      days[row.id] = day
      let eligible = billEligible(row)
      match.append(
        MatchRow(
          txnID: row.id, merchantKey: row.merchantKey, direction: row.direction, amountMinor: row.amountMinor,
          currency: row.currency, homeMinor: row.amountHomeMinor, day: day, eligible: eligible))
      detect.append(
        DetectRow(
          txnID: row.id, merchantKey: row.merchantKey, merchantName: row.displayName, direction: row.direction,
          amountMinor: row.amountMinor, currency: row.currency, day: day, category: row.category,
          eligible: eligible && Grammar.isBillKey(row.merchantKey)))
    }
    let result = BillMatcher.run(
      bills: records.map { BillMatchInput(id: $0.id, bill: $0.bill) }, resolutions: resolutions, rows: match, today: today)
    var matched: [String: [DerivedMatch]] = [:]
    for m in result.matches where !m.explicit {
      matched[m.bill, default: []].append(DerivedMatch(due: m.due, txnID: m.txnID))
    }
    var notices: [String: [BillNoticeCore]] = [:]
    for n in result.notices { notices[n.bill, default: []].append(n) }
    let covered = Set(records.flatMap(\.bill.keys))
    let candidates = BillDetector.run(rows: detect, coveredKeys: covered, today: today)
    return Derived(result: result, matched: matched, notices: notices, days: days, candidates: candidates)
  }

  static func detect(_ records: [(id: String, bill: CoreReplay.Bill)], rows: [TxnRow], today: CivilDate)
    -> [BillCandidateCore]
  {
    derive(records, resolutions: [], rows: rows, today: today).candidates
  }

  static func candidates(_ found: [BillCandidateCore], taxonomy: TaxonomyView) -> [BillCandidate] {
    found.map { c in
      let category = c.category.flatMap { id in taxonomy.info(id).flatMap { $0.kind == .spending ? id : nil } }
      return BillCandidate(
        id: c.id, name: c.name, categoryID: category ?? "subscriptions",
        amount: Money(minor: c.amountMinor, currency: c.currency), seenCount: c.seen,
        everyDays: everyDays(c.unit, every: Int(c.every)), last: local(c.last))
    }
  }

  static func everyDays(_ unit: String, every: Int) -> Int {
    switch unit {
    case "day": every
    case "week": 7 * every
    case "year": 365 * every
    default: 30 * every
    }
  }

  static func expectations(
    _ records: [(id: String, bill: CoreReplay.Bill)], derived: Derived, month: CivilMonth, today: CivilDate, home: String,
    role: (String) -> String?
  ) -> [BillExpectation] {
    var out: [BillExpectation] = []
    for (id, b) in records where b.status == "active" && b.direction == "debit" && b.currency == home {
      let category = b.category ?? "utilities"
      guard role(category) == "bills", let v = BillScheduleView(b) else { continue }
      for d in v.dues(from: month.firstDay, through: month.lastDay) {
        let status: BillExpectation.Status
        var paidDay: CivilDate?
        switch derived.result.status(bill: id, due: d, today: today) {
        case .paid(let txn, _):
          status = .paid
          paidDay = txn.flatMap { derived.days[$0] }
        case .skipped: status = .skipped
        case .snoozed(let until): status = until > today ? .upcoming : until == today ? .due : .late
        case .paused, .notTracked: continue
        case .upcoming: status = .upcoming
        case .due: status = .due
        case .late: status = .late
        }
        let terms = v.terms(at: d)
        out.append(
          BillExpectation(
            billID: id, categoryID: category, payee: b.name, expectedDay: d, amount: terms.amountMinor,
            isEstimate: terms.variable, status: status, paidDay: paidDay,
            usualDayOfMonth: v.unit == "month" ? v.anchor.day : nil))
      }
    }
    return out
  }

  static func kitNotices(_ core: [BillNoticeCore], currency: String, paidAmount: [String: HasalaModels.Txn])
    -> [BillNotice]
  {
    var out: [BillNotice] = []
    var latestPrice: (due: CivilDate, notice: BillNotice)?
    for n in core {
      switch n.kind {
      case .priceChange(let due, let usual, let charged):
        let notice = BillNotice(
          id: "priceChange.\(n.txnID)",
          kind: .priceChange(
            usual: Money(minor: usual, currency: currency), charged: Money(minor: charged, currency: currency),
            from: local(due)), txnID: n.txnID)
        if latestPrice.map({ due > $0.due }) ?? true { latestPrice = (due, notice) }
      case .chargedWhilePaused(let due):
        let t = paidAmount[n.txnID]
        let charged = t.flatMap { charged($0, in: currency) } ?? Money(minor: 0, currency: currency)
        out.append(
          BillNotice(
            id: "chargedWhilePaused.\(n.txnID)", kind: .chargedWhilePaused(charged: charged, on: t?.postedAt.date ?? local(due)),
            txnID: n.txnID))
      case .chargedAfterEnd(let day, let chargedMinor):
        out.append(
          BillNotice(
            id: "chargedAfterEnd.\(n.txnID)",
            kind: .chargedAfterEnd(charged: Money(minor: chargedMinor, currency: currency), on: local(day)), txnID: n.txnID))
      }
    }
    if let p = latestPrice { out.insert(p.notice, at: 0) }
    return out
  }

  static func forkNotices(_ forks: [ForkNotice], records: [String: CoreReplay.Bill], losers: [String: CoreReplay.Bill])
    -> [String: [BillNotice]]
  {
    var out: [String: [BillNotice]] = [:]
    var seen = Set<String>()
    for f in forks where f.entityKind == "bill" && seen.insert(f.loserOp).inserted {
      guard let current = records[f.entityID], current.status != "dismissed" || losers[f.loserOp] != nil else { continue }
      let summary: String
      if let loser = losers[f.loserOp] {
        guard let s = forkSummary(loser: loser, current: current) else { continue }
        summary = s
      } else {
        summary = "A change made on your other iPhone was replaced"
      }
      out[f.entityID, default: []].append(BillNotice(id: "fork.\(f.loserOp)", kind: .changedOnTwoDevices(summary: summary)))
    }
    return out
  }

  static func forkSummary(loser l: CoreReplay.Bill, current c: CoreReplay.Bill) -> String? {
    func day(_ wire: String?) -> String { wire.flatMap(CivilDate.init(wire:)).map { local($0).dayMonth } ?? "" }
    func amount(_ minor: Int64, _ mode: String) -> String { (mode == "variable" ? "~" : "") + MoneyFormat.string(minor) }
    if l.status != c.status {
      switch l.status {
      case "dismissed": return "Deleted"
      case "cancelled": return "Ended \(day(l.end))"
      default: return "Tracking again"
      }
    }
    var parts: [String] = []
    if l.name != c.name { parts.append("Name \(l.name)") }
    if l.amountMinor != c.amountMinor || l.amountMode != c.amountMode { parts.append("Amount \(amount(l.amountMinor, l.amountMode))") }
    for ch in l.changes where !c.changes.contains(ch) {
      parts.append("Amount \(amount(ch.amountMinor, ch.amountMode)) from \(day(ch.from))")
    }
    for p in l.pauses where !c.pauses.contains(p) {
      if p.until == nil {
        parts.append("Paused")
      } else if c.pauses.contains(where: { $0.from == p.from }) {
        parts.append("Resumed \(day(p.until))")
      } else {
        parts.append("Paused until \(day(p.until))")
      }
    }
    if l.cadence != c.cadence || l.anchor != c.anchor || l.start != c.start { parts.append("Schedule") }
    if l.status == "cancelled", l.end != c.end { parts.append("Ended \(day(l.end))") }
    if parts.isEmpty {
      var a = l
      a.createdAt = c.createdAt
      a.firstSeq = c.firstSeq
      a.version = c.version
      if a != c { parts.append("Other details") }
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  static func billOfTxn(
    _ records: [(id: String, bill: CoreReplay.Bill)], resolutions: [BillResolution], matched: [String: [DerivedMatch]]
  ) -> [String: String] {
    let live = Set(records.filter { $0.bill.status != "dismissed" }.map(\.id))
    var out: [String: String] = [:]
    for (bill, list) in matched where live.contains(bill) {
      for m in list { out[m.txnID] = bill }
    }
    for res in resolutions where res.resolution == "paid" && live.contains(res.bill) {
      if let t = res.txn { out[t] = res.bill }
    }
    return out
  }

  static func notices(_ list: [BillNotice], dismissed: Set<String>, salt: String) -> [BillNotice] {
    guard !dismissed.isEmpty else { return list }
    return list.filter { !dismissed.contains(LocalAccountData.digest($0.id, salt: salt)) }
  }

  static func payments(
    explicit resolutions: [BillResolution], matched: [DerivedMatch], paidAmount: [String: HasalaModels.Txn],
    currency: String
  ) -> [BillPayment] {
    var out: [BillPayment] = []
    var dues = Set<String>()
    for r in resolutions where r.resolution == "paid" {
      guard let due = CivilDate(wire: r.due), dues.insert(r.due).inserted else { continue }
      let amount = r.txn.flatMap { paidAmount[$0] }.flatMap { charged($0, in: currency) }
      out.append(BillPayment(due: local(due), txnID: r.txn, amount: amount, link: r.txn == nil ? .marked : .linked))
    }
    let decided = Set(resolutions.filter { $0.resolution != "clear" }.map(\.due))
    for m in matched where !decided.contains(m.due.wire) && dues.insert(m.due.wire).inserted {
      let amount = paidAmount[m.txnID].flatMap { charged($0, in: currency) }
      out.append(BillPayment(due: local(m.due), txnID: m.txnID, amount: amount, link: .matched))
    }
    return out.sorted { $0.due > $1.due }
  }

  static func cadence(_ unit: String, every: Int) -> (HasalaModels.BillCadence, Int) {
    switch unit {
    case "week": (.weekly, every)
    case "year": (.yearly, every)
    case "day": (.weekly, max(1, every / 7))
    default: (.monthly, every)
    }
  }

  static func bill(
    id: String, _ b: CoreReplay.Bill, resolutions: [BillResolution], matched: [DerivedMatch] = [],
    result: BillMatcherResult? = nil, notices core: [BillNoticeCore] = [], today: LocalDate,
    taxonomy: TaxonomyView, paidAmount: [String: HasalaModels.Txn]
  ) -> HasalaModels.Bill? {
    guard b.direction == "debit", let v = BillScheduleView(b),
      let t = CivilDate(year: today.year, month: today.month, day: today.day)
    else { return nil }
    let payments = payments(explicit: resolutions, matched: matched, paidAmount: paidAmount, currency: b.currency)
    let paidDues = Set(payments.map(\.due))
    let statuses = result ?? BillMatcher.run(bills: [BillMatchInput(id: id, bill: b)], resolutions: resolutions, rows: [], today: t)
    func open(_ d: CivilDate) -> Bool {
      if paidDues.contains(local(d)) { return false }
      switch statuses.status(bill: id, due: d, today: t) {
      case .upcoming, .due, .late: return true
      case .snoozed(let until): return until < t
      case .paid, .skipped, .paused, .notTracked: return false
      }
    }
    var next: CivilDate?
    var cursor = v.due(onOrAfter: v.trackingSince)
    var steps = 0
    while let d = cursor, steps < 5_000 {
      if open(d) {
        next = d
        break
      }
      steps += 1
      cursor = d.adding(days: 1).flatMap { v.due(onOrAfter: $0) }
    }
    let fallback = next ?? v.end.flatMap { e in e.adding(days: 1).flatMap { v.due(before: $0) } } ?? v.due(onOrAfter: t)
      ?? v.anchor
    let shownDue = next ?? fallback
    let terms = v.terms(at: shownDue)
    var amount = Money(minor: terms.amountMinor, currency: b.currency)
    let history = payments.map(\.due)
    var priceChangeFrom: Money?
    if !terms.variable, let last = payments.first, let txn = last.txnID,
      let lastDue = CivilDate(year: last.due.year, month: last.due.month, day: last.due.day),
      v.terms(at: lastDue) == terms, let charged = paidAmount[txn].flatMap({ charged($0, in: b.currency) })
    {
      let tolerance = Fils.mulDiv(terms.amountMinor, terms.toleranceBp, 10_000)
      if charged.minor.minus(terms.amountMinor).magnitude > tolerance.magnitude {
        priceChangeFrom = amount
        amount = charged
      }
    }
    let state: HasalaModels.Bill.State
    var pausedSince: LocalDate?
    var pausedUntil: LocalDate?
    switch b.status {
    case "active":
      if let p = v.pauses.last(where: { $0.from <= t && ($0.until.map { t < $0 } ?? true) }) {
        state = .paused
        pausedSince = local(p.from)
        pausedUntil = p.until.map(local)
      } else {
        state = .tracked
      }
    case "cancelled": state = .ended
    default: state = .dismissed
    }
    let upcoming = v.changes.first { $0.from > t }
    let (cadence, every) = cadence(v.unit, every: v.every)
    let category = b.category ?? "utilities"
    return HasalaModels.Bill(
      id: id, name: b.name, kind: taxonomy.info(category)?.name ?? "Bill", categoryID: category, amount: amount,
      approximate: terms.variable, isIncome: false, usualDay: v.anchor.day, nextDue: local(shownDue),
      accountID: b.account, state: state, priceChangeFrom: priceChangeFrom, history: history,
      source: b.source == "manual" ? .manual : .detected, cadence: cadence, every: every, pausedSince: pausedSince,
      pausedUntil: pausedUntil, endedOn: b.status == "cancelled" ? v.end.map(local) : nil,
      trackingSince: local(v.trackingSince), nextAmount: upcoming.map { Money(minor: $0.terms.amountMinor, currency: b.currency) },
      nextAmountFrom: upcoming.map { local($0.from) }, payments: payments,
      notices: kitNotices(core, currency: b.currency, paidAmount: paidAmount), keys: b.keys)
  }

  static func income(_ s: IncomeSource, today: LocalDate, taxonomy: TaxonomyView) -> HasalaModels.Bill {
    HasalaModels.Bill(
      id: LedgerEditAuthor.incomePrefix + s.id, name: s.name, kind: taxonomy.info(s.categoryID)?.name ?? "Income",
      categoryID: s.categoryID, amount: .aed(s.amountMinor), isIncome: true, usualDay: Int(s.payday),
      nextDue: nextPayday(Int(s.payday), after: today), state: s.active ? .tracked : .ended)
  }

  static func charged(_ t: HasalaModels.Txn, in currency: String) -> Money? {
    if t.amount.currency == currency { return t.amount }
    return currency == Money.home ? t.homeMinor.map(Money.aed) : nil
  }

  static func clamp(_ year: Int, _ month: Int, _ day: Int) -> LocalDate {
    LocalDate(year, month, min(day, CivilCalendar.daysIn(year: year, month: month)))
  }

  /// The next payday on or after `after` (day clamped to short months).
  static func nextPayday(_ day: Int, after: LocalDate) -> LocalDate {
    let this = clamp(after.year, after.month, day)
    if this >= after { return this }
    let n = after.yearMonth.next
    return clamp(n.year, n.month, day)
  }

  // MARK: Mailbox

  /// Bank alerts' health for Profile (spec 04 §7.10; content-free).
  static func health(_ st: MailboxStatus, nowMs: Int64) -> MailboxHealth {
    let status: MailboxHealth.Status
    switch st.hero {
    case .working, .otherDevice: status = .working
    case .catchingUp:
      // The first import (scan and backfill) is "importing"; an active lane that hasn't
      // succeeded for a while is still working.
      switch st.phase {
      case .scanning, .awaitingCards, .authoringBackfill: status = .importing
      default: status = .working
      }
    case .needsYou: status = .reconnect
    case .notConnected: status = .notConnected
    }
    let newest = st.health.compactMap(\.lastEmailAtMs).max() ?? st.lastSuccessAtMs
    let names = Set(st.health.compactMap { bankName(domain: $0.domain) }).sorted()
    return MailboxHealth(
      status: status, lastEmail: newest.map { ago(nowMs - $0) } ?? "", banks: names.joined(separator: " and "),
      unreadable: st.unreadable)
  }

  /// Each bank's sender domains, from its bundled templates (03c §7.2), e.g. Emirates NBD
  /// → emiratesnbd.com: a health row names its bank by the template it matched.
  static let bankDomains: [(bank: String, domains: [String])] = bankNames.keys.sorted().map {
    (bank: $0, domains: MailboxLane.senderDomains(bank: $0))
  }

  static func bank(domain: String) -> String? {
    bankDomains.first { BankDomains.isMember(domain, of: $0.domains) }?.bank
  }

  /// The bank a sender domain belongs to, if it is one the beta reads.
  static func bankName(domain: String) -> String? {
    bank(domain: domain).flatMap { bankNames[$0] }
  }

  /// "4 min ago", "3 h ago", "2 days ago".
  static func ago(_ ms: Int64) -> String {
    let minutes = max(0, ms / 60_000)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
    return "\(minutes / (24 * 60)) days ago"
  }

  // MARK: Rules

  static func ruleMatch(_ m: String) -> RuleMatch {
    switch m {
    case "starts_with": .startsWith
    case "exact": .exact
    default: .contains
    }
  }

  // MARK: Dates

  static func local(_ d: CivilDate) -> LocalDate { LocalDate(d.year, d.month, d.day) }

  /// The local day of an RFC 3339 instant.
  static func localDay(_ instant: String) -> LocalDate? {
    guard let ms = try? parseInstantMs(instant), let d = LocalClock.localDate(ms) else { return nil }
    return local(d)
  }
}
