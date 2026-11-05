import Foundation
import HasalaModels

public enum WidgetPreview {
  public static func reading(_ stored: WidgetSnapshot?, at date: Date, isPreview: Bool) -> WidgetReading {
    let reading = WidgetReading(stored, at: date)
    guard isPreview, reading.snapshot == nil else { return reading }
    return WidgetReading(snapshot(asOf: WidgetClock.today(at: date)), at: date)
  }

  public static func snapshot(asOf day: LocalDate) -> WidgetSnapshot {
    WidgetSnapshot(
      asOf: day, amountsHidden: false, lockScreenDetails: false,
      spentSoFar: SpentSoFarWidget(
        spent: .aed(612_000), plan: .aed(1_400_000), verdict: .onTrack, progress: Permille(437),
        tick: Permille(500),
        caption: MoneyPhrase([.text("On track · "), .amount(.aed(788_000), .rounded, hidden: 3), .text(" left")]),
        billWords: "1 bill due Thu", billNamed: "Thu · Electricity"),
      budgetPace: BudgetPaceWidget(monthGone: "50% of the month gone", rows: [
        BucketPaceRow(bucket: .needs, spent: .aed(410_000), budget: .aed(900_000), verdict: .onTrack),
        BucketPaceRow(bucket: .wants, spent: .aed(202_000), budget: .aed(500_000), verdict: .onTrack),
        BucketPaceRow(bucket: .savings, spent: .aed(150_000), budget: .aed(300_000), verdict: .onTrack),
      ]),
      categories: [
        CategoryWatchWidget(
          id: "groceries", name: "Groceries", glyph: .groceries, hue: .sand, left: .aed(84_000),
          perDay: .aed(5_600), verdict: .onTrack, progress: Permille(440), tick: Permille(500)),
      ],
      nextBill: NextBillWidget(
        glyph: .utilities, hue: .sand, due: StatusPill("In 3 days", tone: .warning, showsDot: false),
        amount: .aed(42_000), caption: "Expected Thu · Electricity"),
      netWorth: nil,
      comingUp: ComingUpWidget(days: 14, total: .aed(720_000), rows: [
        ComingUpRow(id: "rent", name: "Rent", glyph: .rent, hue: .sand, note: "In 3 days", late: false,
                    amount: .aed(650_000), isIncome: false),
        ComingUpRow(id: "salary", name: "Salary", glyph: .salary, hue: .mint, note: "In 9 days", late: false,
                    amount: .aed(1_800_000), isIncome: true),
        ComingUpRow(id: "phone", name: "Phone", glyph: .utilities, hue: .sky, note: "In 12 days", late: false,
                    amount: .aed(25_000), isIncome: false),
      ]),
      projects: [
        ProjectWidget(
          id: "home-repairs", name: "Home repairs", glyph: .flag, left: .aed(180_000),
          caption: MoneyPhrase([.text("of "), .amount(.aed(300_000), .rounded, hidden: 4)]), progress: Permille(400)),
      ],
      goals: [
        GoalWidget(
          id: "rainy-day", name: "Rainy day fund", glyph: .savingsJar, progress: Permille(620),
          caption: MoneyPhrase([
            .amount(.aed(1_240_000), .rounded), .text(" of "), .amount(.aed(2_000_000), .rounded), .text(" · Jun"),
          ])),
      ],
      toReview: ToReviewWidget(count: 3, notCounted: .aed(18_500)),
      today: TodayWidget(
        summary: MoneyPhrase([.text("2 transactions · "), .amount(.aed(6_400), .rounded, hidden: 3)]),
        rows: [
          MiniTxnRow(id: "coffee", merchant: "Corner café", glyph: .dining, hue: .lilac, detail: "Dining · 08:40",
                     amount: .aed(2_200)),
          MiniTxnRow(id: "market", merchant: "Fresh market", glyph: .groceries, hue: .sand,
                     detail: "Groceries · 12:15", amount: .aed(4_200)),
        ]))
  }
}
