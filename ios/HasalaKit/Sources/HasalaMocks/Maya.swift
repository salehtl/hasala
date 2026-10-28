import HasalaModels

// The Maya scenario (spec 04 §15.3, page 06 §6.8): Maya Rahman, Dubai Marina, with the clock
// fixed at Saturday 10 October 2026 13:40 in Dubai. Every figure is synthetic and matches the
// Paper Home board ("Home · Default", 14O7-0) where the ledger agrees with it, so a screen can
// be compared with its board side by side. Debug builds, previews and UI tests only: no Release
// code path reaches this module (spec 04 §1.4, AT-REV-4).

/// The mock scenarios a Debug build can launch with `-HasalaScenario <name>`.
public enum Scenario: String, Sendable, CaseIterable {
  /// Home · Default ("Home · Default").
  case maya
  /// Home · Amounts hidden ("Home · Amounts hidden"): the same data with Hide amounts on.
  case mayaHidden
  /// Review · All caught up: the same ledger with the review queue already sorted.
  case mayaCaughtUp
  /// The App Review demo account: the same ledger loaded as sample data, so every row read
  /// from a bank alert carries a `sample-<n>` message id instead of a Gmail one.
  case mayaSample
  case firstDays
  case mayaCopy
  case mayaRange
  case mayaSamePurchase
  case mayaUnreadMail
  case mayaSuggestions
  case mayaBacklog
  case mayaTexts
  case mayaWorst
  case mayaWorstTexts
  case mayaEmpty
  case mayaOne
  case mayaHuge

  /// Reads `-HasalaScenario <name>` from launch arguments; `maya` when absent or unknown.
  public static func fromLaunchArguments(_ arguments: [String]) -> Scenario {
    guard let i = arguments.firstIndex(of: "-HasalaScenario"), i + 1 < arguments.count else {
      return .maya
    }
    return Scenario(rawValue: arguments[i + 1]) ?? .maya
  }

  public var startsWithAmountsHidden: Bool { self == .mayaHidden }

  public var now: LocalDateTime { self == .firstDays ? MayaHistory.firstDaysNow : MayaLedger.now }

  /// The ledger the scenario starts from.
  public var state: LedgerState {
    if self == .firstDays { return MayaHistory.firstDays }
    switch self {
    case .mayaWorst: return MayaWorst.worst
    case .mayaWorstTexts:
      var s = MayaWorst.worst
      MayaTexts.apply(to: &s)
      MockReach.refresh(&s)
      return s
    case .mayaEmpty: return MayaWorst.empty
    case .mayaOne: return MayaWorst.one
    case .mayaHuge: return MayaWorst.huge
    default: break
    }
    var s = self == .mayaSample ? MayaLedger.state : MayaHistory.state
    if self == .mayaCaughtUp {
      for i in s.txns.indices where s.txns[i].needsReview {
        s.txns[i].needsReview = false
        s.txns[i].categoryID = s.txns[i].suggestion ?? (s.txns[i].direction == .in ? "freelance" : "transfer")
        s.txns[i].categorySource = .user
        s.txns[i].isTransfer = s.txns[i].categoryID == "transfer"
      }
    }
    if self == .mayaCopy, var copy = s.txn("starbucks") {
      copy.id = "starbucks-copy"
      copy.postedAt.minute += 4
      copy.heldCopy = HeldCopy(of: "starbucks", fromOtherInbox: true)
      copy.isNewMerchant = false
      s.txns.append(copy)
    }
    if self == .mayaSamePurchase {
      s.txns.append(
        Txn(id: "amazon-usd", merchant: "Amazon", amount: Money(minor: 25_00, currency: "USD"), homeMinor: 91_81,
            postedAt: MayaLedger.oct(7, 20, 15), accountID: "dib", categoryID: "shopping", categorySource: .dictionary,
            provenance: MayaLedger.alert(MayaLedger.dib, "20:15", "AMAZON")))
      s.txns.append(
        Txn(id: "amazon-aed", merchant: "Amazon", amount: .aed(93_00), postedAt: MayaLedger.oct(9, 8, 0), accountID: "dib",
            categoryID: "shopping", categorySource: .dictionary,
            provenance: MayaLedger.alert(MayaLedger.dib, "08:00", "AMAZON MKTPLACE"),
            samePurchase: SamePurchaseMatch(of: "amazon-usd")))
    }
    if self == .mayaUnreadMail {
      s.unreadMail = [
        UnreadMail(id: "unread-gmail", provider: .gmail, receivedOn: LocalDate(2026, 10, 9), bank: "DIB", accountID: "dib"),
        UnreadMail(id: "unread-outlook", provider: .outlook, receivedOn: LocalDate(2026, 10, 7)),
      ]
      s.mailbox.unreadable = 1
    }
    if self == .mayaSuggestions {
      for i in s.txns.indices where ["dubai-taxi", "apple"].contains(s.txns[i].id) {
        s.txns[i].categorySource = .model(tag: "cf-clef/1")
      }
      s.txns += MayaHistory.suggested
    }
    if self == .mayaRange {
      s.txns += MayaHistory.rangeReview
    }
    if self == .mayaBacklog {
      MayaBacklog.apply(to: &s)
    }
    if self == .mayaTexts {
      MayaTexts.apply(to: &s)
    }
    if self == .mayaSample {
      var n = 0
      for i in s.txns.indices where s.txns[i].provenance != nil {
        n += 1
        s.txns[i].mailboxMessageID = "sample-\(n)"
      }
    }
    return s
  }
}

public enum Maya {
  public static let displayName = "Maya Rahman"

  public static let home = HomeSnapshot(
    header: HeaderState(avatarInitial: "M"),
    hero: hero,
    notifications: notifications,
    widgets: widgets
  )

  // Spent: 11,115.62 of 19,000 (12,350 + 6,650), 7,884.38 left: needs and wants 10,288.34 plus
  // 827.28 not sorted yet (savings moves and the transfer in don't count). Today's tick is
  // the 8,005.89 of bills paid so far plus 9,954.96 (the plan less this month's 9,045.04 of
  // bills) × 10 ÷ 31 = 3,211.28: 11,217.17, so spending is behind it: on track.
  // Savings: both standing orders went out on the 2nd, so the ledger has the 5,000 saved (the
  // Paper Home board draws "0 of 5,000"; Paper's own Plan board and this ledger say 5,000, plan
  // D.3 open decision 5).
  static let hero = SpendHero(
    overline: "Day 10 of 31",
    spent: .aed(11_115_62),
    plan: .aed(19_000_00),
    tick: .aed(11_217_17),
    verdict: .onTrack,
    word: "On track",
    fact: MoneyPhrase([.text("AED "), .amount(.aed(7_884_38), hidden: 3), .text(" left")]),
    caption: MoneyPhrase([.text("spent of "), .amount(.aed(19_000_00), .rounded, hidden: 3), .text(" planned")]),
    tiles: [
      HeroTile("Needs", .aed(9_040_80)),
      HeroTile("Wants", .aed(1_247_54)),
      HeroTile("Savings", .aed(5_000_00)),
    ],
    wash: .sky,
    unsorted: .aed(827_28)
  )

  /// Home · Notifications (11Y9-0), "Needs a look", newest first: four items, the bell's 4.
  static let notifications = NotificationsSnapshot(needsALook: [
    NotificationItem(
      id: "review", disc: .hue(.sky, .review), title: "6 transactions to sort",
      line: MoneyPhrase([.text("AED "), .amount(.aed(827_28), hidden: 3), .text(" still to check")]),
      when: "Today", destination: .review(.allTime), count: 6),
    NotificationItem(
      id: "bill.axa", disc: .hue(.sand, .insurance), title: "\(Bidi.isolate("AXA Insurance")) may be late",
      line: "Usually on the 7th · no email yet", status: .error, when: "Thu", destination: .bill("axa")),
    NotificationItem(
      id: "found.apple-bill", disc: .hue(.lilac, .subscriptions), title: "Found a bill: \(Bidi.isolate("Apple.com/bill"))",
      line: "Seen 5× · every ~30 days", when: "Thu", destination: .bills),
    NotificationItem(
      id: "price.du", disc: .hue(.sand, .utilities), title: "\(Bidi.isolate("du")) has a new price",
      line: MoneyPhrase([
        .amount(.aed(427_90), hidden: 3), .text(" from "), .amount(.aed(389_00), hidden: 3), .text(" · accept or check"),
      ]),
      when: "Mon", destination: .bill("du")),
  ])

  static let widgets: [HomeWidget] = [
    .budgetPace(BudgetPaceWidget(
      monthGone: "32% of October gone",
      rows: [
        BucketPaceRow(bucket: .needs, spent: .aed(9_040_80), budget: .aed(12_350_00), verdict: .onTrack),
        BucketPaceRow(bucket: .wants, spent: .aed(1_247_54), budget: .aed(6_650_00), verdict: .onTrack),
        BucketPaceRow(bucket: .savings, spent: .aed(5_000_00), budget: .aed(5_000_00), verdict: .done),
      ]
    )),
    .nextBill(NextBillWidget(
      glyph: .utilities,
      hue: .sand,
      due: StatusPill("In 4 days", tone: .warning, showsDot: false),
      amount: .aed(489_15),
      caption: "Expected Wed · DEWA"
    )),
    .netWorth(NetWorthWidget(
      total: .aed(227_568_00),
      change: MoneyPhrase([.signedMoney(.aed(2_140_00), style: .rounded, hiddenGlyphs: 3), .text(" this month")]),
      // The board's sparkline, sampled every 18 pt, as permille of its 70 pt band.
      spark: [171, 229, 200, 329, 300, 429, 400, 557, 529, 686, 743].map(Permille.init)
    )),
    .project(ProjectWidget(
      name: "Japan trip",
      glyph: .travel,
      left: .aed(7_140_00),
      caption: MoneyPhrase([.text("of "), .amount(.aed(12_000_00), .rounded, hidden: 4), .text(" · flies 14 Dec")]),
      progress: Permille.ratio(4_860_00, of: 12_000_00)
    )),
    .goal(GoalWidget(
      name: "Emergency fund",
      glyph: .savingsJar,
      progress: Permille.ratio(38_500_00, of: 50_000_00),
      caption: MoneyPhrase([
        .amount(.aed(38_500_00), .rounded), .text(" of "), .amount(.aed(50_000_00), .rounded), .text(" · Jan"),
      ])
    )),
    .today(TodayWidget(
      summary: MoneyPhrase([.text("4 transactions · "), .amount(.aed(189_49), .rounded, hidden: 3)]),
      rows: [
        MiniTxnRow(id: "t.talabat", merchant: "Talabat", glyph: .dining, hue: .lilac,
                   detail: "Dining · 13:20", amount: .aed(64_50)),
        MiniTxnRow(id: "t.steam", merchant: "Steam", glyph: .review, hue: .other,
                   detail: "Uncategorized · 11:02", amount: .aed(59_49)),
        MiniTxnRow(id: "t.starbucks", merchant: "Starbucks", glyph: .dining, hue: .lilac,
                   detail: "Dining · 09:05 · DIFC", amount: .aed(27_00)),
      ]
    )),
  ]
}
