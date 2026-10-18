import Foundation
import HasalaDesign
import HasalaMocks
import HasalaModels
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("Widget renders")
struct WidgetRenderTests {
  static let outDir: URL? = ProcessInfo.processInfo.environment["HASALA_WIDGET_PNG_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
  }

  func snapshot(hidden: Bool = false, lockDetails: Bool = false) -> WidgetSnapshot {
    var s = MayaLedger.state
    s.prefs.notificationDetail = lockDetails
    let now = MayaLedger.now
    return GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: hidden)
  }

  func render<V: View>(_ name: String, _ view: V) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.uiImage, "\(name) did not render")
    let png = try #require(image.pngData())
    #expect(image.size.width > 0)
    if let dir = Self.outDir {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try png.write(to: dir.appendingPathComponent("\(name).png"))
    }
  }

  func canvas<V: View>(_ view: V, width: CGFloat) -> some View {
    view.frame(width: width).padding(24).background(HColor.surfaceCanvas)
  }

  func device<V: View, S: ShapeStyle>(_ view: V, fill: S, width: CGFloat, height: CGFloat = 170) -> some View {
    view.environment(\.widgetHost, .system)
      .frame(width: width, height: height)
      .background(fill)
      .clipShape(RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous))
      .padding(24)
      .background(Color(white: 0.55))
  }

  func lock<V: View>(_ view: V, width: CGFloat, circle: Bool, padding: CGFloat = 0) -> some View {
    view.padding(.horizontal, padding)
      .frame(width: width, height: 72)
      .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: circle ? 36 : 18))
      .padding(24)
      .background(Color(red: 0.16, green: 0.22, blue: 0.38))
  }

  @Test func theLaunchSetRenders() throws {
    let w = snapshot()
    let h = snapshot(hidden: true)
    let spent = try #require(w.spentSoFar)
    let dining = try #require(w.categories.first { $0.name == "Dining" })
    let pace = try #require(w.budgetPace)
    let bill = try #require(w.nextBill)
    let worth = try #require(w.netWorth)
    let coming = try #require(w.comingUp)
    let project = try #require(w.projects.first)
    let goal = try #require(w.goals.first)
    let review = try #require(w.toReview)
    let today = try #require(w.today)
    let unit = HContainer.widgetUnit
    let wide = HContainer.widgetWide

    try render("paper-01-spent-so-far", canvas(SpentSoFarWidgetView(spent, hidden: false), width: unit))
    try render("paper-02-budget-pace", canvas(BudgetPaceWidgetView(pace, hidden: false), width: wide))
    try render("paper-03-category-watch", canvas(CategoryWatchWidgetView(dining, hidden: false), width: unit))
    try render("paper-04-next-bill", canvas(NextBillWidgetView(bill, hidden: false), width: unit))
    try render("paper-05-net-worth", canvas(NetWorthWidgetView(worth, hidden: false), width: unit))
    try render("paper-06-coming-up", canvas(ComingUpWidgetView(coming, hidden: false), width: wide))
    try render("paper-07-project", canvas(ProjectWidgetView(project, hidden: false), width: unit))
    try render("paper-08-goal", canvas(GoalWidgetView(goal, hidden: false), width: unit))
    try render("paper-09-to-review", canvas(ToReviewWidgetView(review, hidden: false), width: unit))
    try render("paper-10-today", canvas(TodayWidgetView(today, hidden: false), width: wide))
    try render("paper-11-waiting", canvas(WaitingWidgetView(title: "Spent so far"), width: unit))
    try render("paper-12-project-hidden", canvas(ProjectWidgetView(try #require(h.projects.first), hidden: true),
                                                 width: unit))

    try render("device-01-spent-so-far", device(SpentSoFarWidgetView(spent, hidden: false),
                                                fill: HColor.widgetSurfaceInverse, width: 170))
    try render("device-02-budget-pace", device(BudgetPaceWidgetView(pace, hidden: false), fill: HColor.widgetSurface,
                                               width: 364))
    try render("device-03-category-watch", device(CategoryWatchWidgetView(dining, hidden: false),
                                                  fill: HColor.widgetSurface, width: 170))
    try render("device-06-coming-up", device(ComingUpWidgetView(coming, hidden: false), fill: HColor.widgetSurface,
                                             width: 364))
    try render("device-09-to-review", device(ToReviewWidgetView(review, hidden: false),
                                             fill: Hue.sky.perceptualGradient, width: 170))
    try render("device-10-today", device(TodayWidgetView(today, hidden: false), fill: HColor.widgetSurface,
                                         width: 364))
    try render("device-11-budget-pace-hidden", device(BudgetPaceWidgetView(try #require(h.budgetPace), hidden: true),
                                                      fill: HColor.widgetSurface, width: 364))
  }

  @Test func theLockScreenAccessoriesRender() throws {
    let w = snapshot()
    let o = snapshot(lockDetails: true)
    try render("lock-01-ring-default", lock(LockSpentRingView(w.spentSoFar, showsAmounts: w.lockShowsAmounts),
                                            width: 72, circle: true))
    try render("lock-02-rect-default", lock(LockSpentRectView(w.spentSoFar, showsAmounts: w.lockShowsAmounts),
                                            width: 172, circle: false, padding: 14))
    try render("lock-03-review", lock(LockReviewCircleView(w.toReview), width: 72, circle: true))
    try render("lock-04-ring-opted-in", lock(LockSpentRingView(o.spentSoFar, showsAmounts: o.lockShowsAmounts),
                                             width: 72, circle: true))
    try render("lock-05-rect-opted-in", lock(LockSpentRectView(o.spentSoFar, showsAmounts: o.lockShowsAmounts),
                                             width: 172, circle: false, padding: 14))
  }
}
