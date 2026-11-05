#if HASALA_MOCKS
  import HasalaMocks
  import HasalaModels
  import HasalaWidgetData
  import SwiftUI
  import WidgetKit

  enum SampleGlance {
    static func snapshot(hidden: Bool = false, lockDetails: Bool = false) -> WidgetSnapshot {
      var s = MayaLedger.state
      s.prefs.notificationDetail = lockDetails
      let now = MayaLedger.now
      return GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: hidden)
    }

    static let filled = GlanceEntry(date: .now, snapshot: snapshot())
    static let hidden = GlanceEntry(date: .now, snapshot: snapshot(hidden: true))
    static let opted = GlanceEntry(date: .now, snapshot: snapshot(lockDetails: true))
    static let waiting = GlanceEntry(date: .now, snapshot: nil)
  }

  #Preview("Spent so far", as: .systemSmall) {
    SpentSoFarHomeWidget()
  } timeline: {
    SampleGlance.filled
    SampleGlance.hidden
    SampleGlance.waiting
  }

  #Preview("Lock ring", as: .accessoryCircular) {
    SpentSoFarHomeWidget()
  } timeline: {
    SampleGlance.filled
    SampleGlance.opted
  }

  #Preview("Lock rectangle", as: .accessoryRectangular) {
    SpentSoFarHomeWidget()
  } timeline: {
    SampleGlance.filled
    SampleGlance.opted
  }

  #Preview("Budget pace", as: .systemMedium) {
    BudgetPaceHomeWidget()
  } timeline: {
    SampleGlance.filled
    SampleGlance.hidden
  }

  #Preview("Coming up", as: .systemMedium) {
    ComingUpHomeWidget()
  } timeline: {
    SampleGlance.filled
  }

  #Preview("Today", as: .systemMedium) {
    TodayHomeWidget()
  } timeline: {
    SampleGlance.filled
  }

  #Preview("Next bill", as: .systemSmall) {
    NextBillHomeWidget()
  } timeline: {
    SampleGlance.filled
  }

  #Preview("Net worth", as: .systemSmall) {
    NetWorthHomeWidget()
  } timeline: {
    SampleGlance.filled
  }

  #Preview("To sort", as: .systemSmall) {
    ToReviewHomeWidget()
  } timeline: {
    SampleGlance.filled
  }

  #Preview("Gallery sample", as: .systemMedium) {
    BudgetPaceHomeWidget()
  } timeline: {
    GlanceEntry(date: .now, snapshot: WidgetPreview.snapshot(asOf: WidgetClock.today()))
  }

  private struct Accented<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
      content()
        .environment(\.widgetRenderingMode, .accented)
        .frame(width: width, height: 158)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
  }

  #Preview("Accented · Budget pace") {
    Accented(width: 338) { BudgetPaceEntryView(entry: SampleGlance.filled) }
  }

  #Preview("Accented · Spent so far") {
    Accented(width: 158) { SpentSoFarEntryView(entry: SampleGlance.filled) }
  }

  #Preview("Accented · Category watch") {
    Accented(width: 158) { CategoryWatchEntryView(entry: SampleGlance.filled) }
  }

  #Preview("Accented · Project") {
    Accented(width: 158) { ProjectEntryView(entry: SampleGlance.filled) }
  }

  #Preview("Accented · Goal") {
    Accented(width: 158) { GoalEntryView(entry: SampleGlance.filled) }
  }

  #Preview("Accented · To sort") {
    Accented(width: 158) { ToReviewEntryView(entry: SampleGlance.filled) }
  }

  #Preview("Accented · Coming up") {
    Accented(width: 338) { ComingUpEntryView(entry: SampleGlance.filled) }
  }
#endif
