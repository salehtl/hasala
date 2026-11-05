import Foundation
import HasalaModels
import HasalaWidgetData
import SwiftUI
import Testing
import WidgetKit

@testable import HasalaDesign

@Suite("Widgets · ink with and without the container background")
struct WidgetInkTests {
  @Test func withTheBackgroundTheInksStay() {
    #expect(WidgetInk.primary(true) == HColor.textPrimary)
    #expect(WidgetInk.secondary(true) == HColor.textSecondary)
    #expect(WidgetInk.primary(true, Hue.sky.ink) == Hue.sky.ink)
    #expect(WidgetInk.secondary(true, HColor.textOnHueSecondary) == HColor.textOnHueSecondary)
  }

  @Test func withoutTheBackgroundEveryInkIsLight() {
    #expect(WidgetInk.primary(false) == HColor.widgetOnInverse)
    #expect(WidgetInk.secondary(false) == HColor.widgetOnInverseSecondary)
    #expect(WidgetInk.primary(false, Hue.sky.ink) == HColor.widgetOnInverse)
    #expect(WidgetInk.primary(false, HColor.paceOverBudget) == HColor.widgetOnInverse)
    #expect(WidgetInk.secondary(false, HColor.textOnHueSecondary) == HColor.widgetOnInverseSecondary)
  }

  @Test func theTrackFadesOutsideFullColour() {
    #expect(WidgetInk.trackOpacity(.fullColor) == 1)
    #expect(WidgetInk.trackOpacity(.accented) < 0.5)
    #expect(WidgetInk.trackOpacity(.vibrant) < 0.5)
  }
}

@Suite("Widgets · Budget pace words")
struct BudgetPaceWordsTests {
  func row(_ bucket: Bucket, spent: Int64, budget: Int64, _ verdict: Verdict) -> BucketPaceRow {
    BucketPaceRow(bucket: bucket, spent: .aed(spent), budget: .aed(budget), verdict: verdict)
  }

  @Test func onlyOverPaceGetsTheWord() {
    #expect(BudgetPaceWidgetView.paceWord(.overPace) == "over pace")
    #expect(BudgetPaceWidgetView.paceWord(.onTrack) == nil)
    #expect(BudgetPaceWidgetView.paceWord(.overBudget) == nil)
    #expect(BudgetPaceWidgetView.paceWord(.done) == nil)
  }

  @Test func theSystemPaddingIsElevenTopAndBottom() {
    #expect(BudgetPaceWidgetView.systemPadding.top == 11)
    #expect(BudgetPaceWidgetView.systemPadding.bottom == 11)
  }

  @Test func savingsFoldsIntoOneLine() {
    let saving = row(.savings, spent: 100_000, budget: 600_000, .onTrack)
    #expect(BudgetPaceWidgetView.savingsLine(saving, hidden: false) == "Savings · 5,000 to save")
    #expect(BudgetPaceWidgetView.savingsLine(saving, hidden: true) == "Savings · ••• to save")
    let saved = row(.savings, spent: 600_000, budget: 600_000, .done)
    #expect(BudgetPaceWidgetView.savingsLine(saved, hidden: false) == "Savings · Done")
  }

  @Test func theOverPaceRowSaysSoAloud() {
    let needs = row(.needs, spent: 900_000, budget: 1_200_000, .overPace)
    #expect(BudgetPaceWidgetView.rowSummary(needs, hidden: false).hasSuffix("3,000 dirhams left, over pace"))
    #expect(BudgetPaceWidgetView.rowSummary(needs, hidden: true) == "Amount hidden, over pace")
  }
}

@Suite("Widgets · Lock Screen values")
struct LockWidgetValuesTests {
  let model = SpentSoFarWidget(
    spent: .aed(420_000), plan: .aed(900_000), verdict: .overPace, progress: Permille(466), tick: Permille(400),
    caption: "Over pace", billWords: nil, billNamed: nil)

  @Test func theRingCaptionIsElevenOnThirteen() {
    #expect(HType.lockRingCaption.size == 11)
    #expect(HType.lockRingCaption.leading == 13)
    #expect(HType.lockRingCaption.weight == .semibold)
  }

  @Test func theGraysAreOpaque() {
    #expect(LockInk.secondary == Color(white: 0.8))
    #expect(LockInk.ringTrack == Color(white: 0.28))
  }

  @Test func theTitleIsThisMonth() {
    #expect(LockSpentRectView.title == "This month")
    #expect(LockSpentRingView.spoken(model, showsAmounts: false) == "This month, Over pace")
    #expect(LockSpentRingView.spoken(model, showsAmounts: true) == "This month, AED 4,200, Over pace")
    #expect(LockSpentRingView.spoken(nil, showsAmounts: false).hasPrefix("This month, "))
  }

  @Test func ringWordsWrapRatherThanCut() {
    #expect(LockSpentRingView.captionLines == 2)
  }
}

@Suite("Widgets · To sort copy")
struct ToSortCopyTests {
  @Test func theWidgetUsesTheQueueWords() {
    #expect(ToReviewWidgetView.title == "To sort")
    #expect(ToReviewWidgetView.action == "Start review")
  }
}

@Suite("Widgets · gallery preview")
struct WidgetGalleryPreviewTests {
  let day = LocalDate(2026, 11, 5)
  let at = ISO8601DateFormatter().date(from: "2026-11-05T08:00:00Z")!

  @Test func theSampleFillsEveryWidget() {
    let s = WidgetPreview.snapshot(asOf: day)
    #expect(s.asOf == day)
    #expect(!s.amountsHidden)
    #expect(s.spentSoFar != nil)
    #expect(s.budgetPace?.rows.count == 3)
    #expect(!s.categories.isEmpty)
    #expect(s.nextBill != nil)
    #expect(s.comingUp?.rows.isEmpty == false)
    #expect(s.projects.first?.id != nil)
    #expect(s.goals.first?.id != nil)
    #expect(s.toReview != nil)
    #expect(s.today?.rows.isEmpty == false)
  }

  @Test func theSampleNamesNoScenario() throws {
    let text = String(decoding: try WidgetSnapshotStore.encode(WidgetPreview.snapshot(asOf: day)), as: UTF8.self)
    for word in ["Maya", "maya", "Mock", "mock", "Sample", "sample"] {
      #expect(!text.contains(word))
    }
  }

  @Test func aPreviewWithNothingCurrentShowsTheSample() {
    let none = WidgetPreview.reading(nil, at: at, isPreview: true)
    #expect(none.snapshot == WidgetPreview.snapshot(asOf: day))
    #expect(!none.stale)
    let old = WidgetPreview.snapshot(asOf: LocalDate(2026, 11, 1))
    let stale = WidgetPreview.reading(old, at: at, isPreview: true)
    #expect(stale.snapshot == WidgetPreview.snapshot(asOf: day))
    #expect(!stale.stale)
  }

  @Test func aPreviewWithACurrentSnapshotShowsIt() {
    var mine = WidgetPreview.snapshot(asOf: day)
    mine.toReview = ToReviewWidget(count: 2, notCounted: .aed(1_000))
    #expect(WidgetPreview.reading(mine, at: at, isPreview: true).snapshot == mine)
  }

  @Test func outsideThePreviewNothingChanges() {
    #expect(WidgetPreview.reading(nil, at: at, isPreview: false) == WidgetReading(nil, at: at))
    let old = WidgetPreview.snapshot(asOf: LocalDate(2026, 11, 1))
    #expect(WidgetPreview.reading(old, at: at, isPreview: false) == WidgetReading(old, at: at))
  }
}
