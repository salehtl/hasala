import HasalaModels

// The Maya scenario (spec 04 §15.3): Maya Rahman, Dubai Marina, with the clock
// fixed at Saturday 10 October 2026 13:40 in Dubai. Every figure is synthetic and
// matches the Paper Home board ("Home · Default") exactly, so a screen can be compared with
// its board side by side. Debug builds, previews and UI tests only: no Release
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

  /// Reads `-HasalaScenario <name>` from launch arguments; `maya` when absent or unknown.
  public static func fromLaunchArguments(_ arguments: [String]) -> Scenario {
    guard let i = arguments.firstIndex(of: "-HasalaScenario"), i + 1 < arguments.count else {
      return .maya
    }
    return Scenario(rawValue: arguments[i + 1]) ?? .maya
  }

  public var startsWithAmountsHidden: Bool { self == .mayaHidden }

  /// The ledger the scenario starts from.
  public var state: LedgerState {
    var s = MayaLedger.state
    if self == .mayaCaughtUp {
      for i in s.txns.indices where s.txns[i].needsReview {
        s.txns[i].needsReview = false
        s.txns[i].categoryID = s.txns[i].suggestion ?? (s.txns[i].direction == .in ? "freelance" : "transfer")
        s.txns[i].categorySource = .user
        s.txns[i].isTransfer = s.txns[i].categoryID == "transfer"
      }
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
  /// The fixed scenario clock: 2026-10-10 13:40 Asia/Dubai = 09:40 UTC.
  public static let nowUTC = "2026-10-10T09:40:00Z"
  public static let displayName = "Maya Rahman"

  public static let home = HomeSnapshot(
    header: HeaderState(unreadNotifications: 2, avatarInitial: "M"),
    hero: hero,
    needsYou: needsYou,
    widgets: widgets
  )

  // Everyday budget 9,700.00: 2,282.45 spent, 7,417.55 left, 22 days to go
  // (7,417.55 / 22 = 337.16, "about AED 337 a day"). Ten of 31 days is 32%.
  static let hero = EverydayHero(
    overline: "October · day 10 of 31",
    left: .aed(7_417_55),
    caption: "left for everyday spending",
    spent: Permille.ratio(2_282_45, of: 9_700_00),
    today: Permille(320),
    verdict: .onTrack,
    verdictDetail: MoneyPhrase([.text("about AED "), .amount(.aed(337_16), .rounded, hidden: 3), .text(" a day")]),
    stats: [
      HeroStat("Spent", .aed(2_282_45)),
      HeroStat("Bills paid", .aed(8_005_89)),
      HeroStat("Bills to come", .aed(1_039_15)),
    ],
    wash: .sky
  )

  static let needsYou = NeedsYouRail(
    count: 4,
    subtitle: "1 bill looks late",
    cards: [
      NeedsYouCard(
        id: "review",
        hue: .sky,
        glyph: .review,
        label: "To review",
        status: StatusPill("2 new today", tone: .accent),
        figure: .count(6, unit: "to sort"),
        title: "Sort new transactions",
        subtitle: MoneyPhrase([.text("AED "), .amount(.aed(827_28)), .text(" isn't in your plan yet")]),
        primaryAction: "Start",
        secondaryAction: "Later"
      ),
      NeedsYouCard(
        id: "bill.axa",
        hue: .rose,
        glyph: .insurance,
        label: "AXA Insurance",
        status: StatusPill("3 days late", tone: .error),
        figure: .money(.aed(550_00)),
        title: "Car insurance didn't arrive",
        subtitle: "Usually on the 7th · no email yet",
        primaryAction: "I paid it",
        secondaryAction: "Details"
      ),
    ]
  )

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
      caption: "DEWA · expected Wed"
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
      caption: MoneyPhrase([.text("of "), .amount(.aed(12_000_00), .compact), .text(" · flies 14 Dec")]),
      progress: Permille.ratio(4_860_00, of: 12_000_00)
    )),
    .goal(GoalWidget(
      name: "Emergency fund",
      glyph: .savingsJar,
      progress: Permille.ratio(38_500_00, of: 50_000_00),
      caption: MoneyPhrase([
        .amount(.aed(38_500_00), .compact), .text(" of "), .amount(.aed(50_000_00), .compact), .text(" · Jan"),
      ])
    )),
    .today(TodayWidget(
      summary: MoneyPhrase([.text("2 transactions · "), .amount(.aed(91_50), hidden: 3)]),
      rows: [
        MiniTxnRow(id: "t.talabat", merchant: "Talabat", glyph: .dining, hue: .lilac,
                   detail: "Dining · 13:20", amount: .aed(64_50)),
        MiniTxnRow(id: "t.starbucks", merchant: "Starbucks", glyph: .dining, hue: .lilac,
                   detail: "Dining · 09:05 · DIFC", amount: .aed(27_00)),
      ]
    )),
  ]
}
