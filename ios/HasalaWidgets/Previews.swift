#if HASALA_MOCKS
  import HasalaMocks
  import HasalaModels
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

  #Preview("To review", as: .systemSmall) {
    ToReviewHomeWidget()
  } timeline: {
    SampleGlance.filled
  }
#endif
