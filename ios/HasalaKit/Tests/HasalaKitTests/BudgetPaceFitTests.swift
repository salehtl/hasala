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

    @Test func theCanvasKeepsPapersSixteenAllRound() throws {
      #expect(try height(.canvas) >= 190)
    }
  }
#endif
