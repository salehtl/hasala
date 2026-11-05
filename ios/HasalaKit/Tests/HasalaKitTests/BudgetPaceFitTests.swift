#if canImport(AppKit)
  import AppKit
  import HasalaDesign
  import HasalaMocks
  import HasalaModels
  import SwiftUI
  import Testing

  @MainActor
  @Suite("Budget pace fit")
  struct BudgetPaceFitTests {
    func height(_ host: WidgetHost) throws -> CGFloat {
      HasalaFonts.register()
      let s = MayaLedger.state
      let home = HomeEngine.snapshot(s, now: MayaLedger.now)
      let pace = try #require(GlanceEngine.snapshot(s, now: MayaLedger.now, home: home, amountsHidden: false).budgetPace)
      let view = NSHostingView(rootView: BudgetPaceWidgetView(pace, hidden: false).environment(\.widgetHost, host)
        .frame(width: 364).fixedSize(horizontal: false, vertical: true))
      return view.fittingSize.height
    }

    @Test func theSystemMediumKeepsEveryRowInsideItsEqualInsets() throws {
      #expect(try height(.system) <= 170)
    }

    func systemHeight(_ pace: BudgetPaceWidget, width: CGFloat) -> CGFloat {
      HasalaFonts.register()
      let view = NSHostingView(rootView: BudgetPaceWidgetView(pace, hidden: false).environment(\.widgetHost, .system)
        .frame(width: width).fixedSize(horizontal: false, vertical: true))
      return view.fittingSize.height
    }

    static let worst = BudgetPaceWidget(monthGone: "52% of November gone", rows: [
      BucketPaceRow(bucket: .needs, spent: .aed(1_084_100), budget: .aed(1_235_000), verdict: .overPace),
      BucketPaceRow(bucket: .wants, spent: .aed(744_400), budget: .aed(667_400), verdict: .overBudget),
      BucketPaceRow(bucket: .savings, spent: .aed(150_000), budget: .aed(500_000), verdict: .onTrack),
    ])

    @Test func threeRowsFitTheSmallestMediumAtDefaultSize() throws {
      #expect(systemHeight(Self.worst, width: 338) <= 158)
    }

    @Test func theCanvasKeepsPapersSixteenAllRound() throws {
      #expect(try height(.canvas) >= 190)
    }
  }
#endif
