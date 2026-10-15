import HasalaModels
import SwiftUI
import Testing

@testable import HasalaDesign

/// The motion vocabulary matches the owner's motion policy of 15 Oct (plan OWNER OVERRIDES,
/// hasala-v2-work/motion-policy.md), which replaces the longer page 04 values. If the owner
/// changes a value on purpose, these expectations change with it.
@Suite("Motion")
struct MotionTests {
  @Test func durationsAreTheOwnersValues() {
    #expect(HMotion.pressBack == 0.12)
    #expect(HMotion.highlight == 0.10)
    #expect(HMotion.fade == 0.18)
    #expect(HMotion.rise == 0.22)
    #expect(HMotion.toastIn == 0.22)
    #expect(HMotion.toastOut == 0.18)
    #expect(HMotion.count == 0.30)
    #expect(HMotion.fill == 0.30)
    #expect(HMotion.marker == 0.12)
    #expect(HMotion.verdict == 0.15)
    #expect(HMotion.fillUpdate == 0.25)
    #expect(HMotion.cardCommit == 0.20)
    #expect(HMotion.sheetContent == 0.25)
    #expect(HMotion.hideAmounts == 0.15)
    #expect(HMotion.reduceMotionFade == 0.15)
    #expect(HMotion.stagger == 0.08)
    #expect(HMotion.staggerLimit == 4)
    #expect(HMotion.storyDuration == 6.0)
    #expect(HMotion.celebrateLimit == 0.6)
    #expect(HMotion.toastDwell == 4.0)
    #expect(HMotion.toastDwellVoiceOver == 8.0)
  }

  @Test func springsAreTheOwnersValues() {
    #expect((HMotion.snappyResponse, HMotion.snappyDamping) == (0.28, 0.86))
    #expect((HMotion.dropStiffness, HMotion.dropDamping) == (420, 26))
    #expect((HMotion.cardReturnResponse, HMotion.cardReturnDamping) == (0.3, 0.8))
    #expect((HMotion.dealResponse, HMotion.dealDamping) == (0.5, 0.78))
  }

  @Test func distancesAndScales() {
    #expect(HMotion.travelRise == 12)
    #expect(HMotion.travelDeal == 40)
    #expect(HMotion.pressScale == 0.97)
    #expect(HMotion.dealScale == 0.94)
    #expect(HMotion.nextCardScale == 0.96)
    #expect(HMotion.nextCardLift == 8)
    #expect(HMotion.cardFlyOut == 1.4)
    #expect(HMotion.cardFlyTilt == 16)
    #expect(HMotion.commitTilt == 3)
    #expect(HMotion.markerDrop == 4)
    #expect((HMotion.idleFloat, HMotion.idlePeriod) == (4, 4.0))
  }

  @Test(arguments: [
    (HMotion.Kind.press, HMotion.Curve.easeOutSoft(duration: 0.12)),
    (.highlight, .easeOutSoft(duration: 0.10)),
    (.fade, .easeOutSoft(duration: 0.18)),
    (.stateSwap, .easeOutSoft(duration: 0.18)),
    (.rise, .easeOutSoft(duration: 0.22)),
    (.toastIn, .easeOutSoft(duration: 0.22)),
    (.toastOut, .easeOutSoft(duration: 0.18)),
    (.fill, .easeInOut(duration: 0.30)),
    (.fillUpdate, .easeInOut(duration: 0.25)),
    (.marker, .easeOutSoft(duration: 0.12)),
    (.verdict, .easeOutSoft(duration: 0.15)),
    (.count, .easeInOut(duration: 0.30)),
    (.thumbSlide, .spring(response: 0.28, damping: 0.86)),
    (.pagerSettle, .spring(response: 0.28, damping: 0.86)),
    (.cardNext, .interpolatingSpring(stiffness: 420, damping: 26)),
    (.cardSettle, .interpolatingSpring(stiffness: 420, damping: 26)),
    (.cardReturn, .spring(response: 0.3, damping: 0.8)),
    (.cardCommit, .easeOutSoft(duration: 0.20)),
    (.deal(index: 0), .spring(response: 0.5, damping: 0.78)),
    (.sheetContent, .easeOutSoft(duration: 0.25)),
    (.hideAmounts, .easeOutSoft(duration: 0.15)),
  ])
  func eachKindPlaysItsCurve(kind: HMotion.Kind, curve: HMotion.Curve) {
    #expect(MotionPolicy().curve(kind) == curve)
  }

  /// "UI animations stay under 300 ms": only fills and counts reach 300, and only the first-time
  /// moments (Welcome deal-in, a celebration) and the one loop run longer.
  @Test func uiMotionStaysShort() {
    let longAllowed: Set<HMotion.Kind> = [.deal(index: 0), .chipPop, .celebrate, .idleFloat]
    for kind in HMotion.Kind.allKinds where !longAllowed.contains(kind) {
      let curve = MotionPolicy().curve(kind)
      #expect((curve?.nominalDuration ?? 0) <= 0.30, "\(kind)")
    }
    #expect(HMotion.Curve.spring(response: HMotion.celebrateResponse, damping: HMotion.celebrateDamping)
      .nominalDuration <= HMotion.celebrateLimit)
  }

  /// Every kind has a Reduce Motion substitute: a short fade, or the final state at once. Travel,
  /// scale and springs never survive Reduce Motion.
  @Test func everyKindHasAReduceMotionSubstitute() {
    let reduce = MotionPolicy(reduceMotion: true)
    for kind in HMotion.Kind.allKinds {
      switch reduce.curve(kind) {
      case nil:
        break  // shown at once
      case .easeOutSoft(let d)?:
        #expect(d <= HMotion.fade, "\(kind)")
      case let other?:
        Issue.record("\(kind) keeps \(other) under Reduce Motion")
      }
    }
    // Travel becomes the 150 ms cross-fade; fills, ticks and counts show at once.
    #expect(reduce.curve(.rise) == .easeOutSoft(duration: 0.15))
    #expect(reduce.curve(.toastIn) == .easeOutSoft(duration: 0.15))
    #expect(reduce.curve(.deal(index: 2)) == .easeOutSoft(duration: 0.15))
    #expect(reduce.curve(.cardNext) == .easeOutSoft(duration: 0.15))
    #expect(reduce.curve(.fill) == nil)
    #expect(reduce.curve(.fillUpdate) == nil)
    #expect(reduce.curve(.count) == nil)
    #expect(reduce.curve(.thumbSlide) == nil)
    #expect(reduce.curve(.idleFloat) == nil)
    // A colour change is not motion: the press keeps its colour timing.
    #expect(reduce.curve(.press) == .easeOutSoft(duration: 0.12))
  }

  /// Debug `-HasalaMotion off`: every final state at once.
  @Test func settledMotionAnimatesNothing() {
    let settled = MotionPolicy(settled: true)
    for kind in HMotion.Kind.allKinds {
      #expect(settled.curve(kind) == nil, "\(kind)")
      #expect(settled.animation(kind) == nil, "\(kind)")
    }
    #expect(settled.isStill)
    #expect(MotionPolicy(reduceMotion: true).isStill)
    #expect(!MotionPolicy().isStill)
  }

  @Test func dealsStaggerEightyMillisecondsForFourCards() {
    #expect(HMotion.dealDelay(index: 0) == 0)
    #expect(abs(HMotion.dealDelay(index: 1) - 0.08) < 1e-9)
    #expect(abs(HMotion.dealDelay(index: 3) - 0.24) < 1e-9)
    // At most four are staggered: later cards enter with the fourth.
    #expect(HMotion.dealDelay(index: 7) == HMotion.dealDelay(index: 3))
  }

  @Test func washesFollowTheVerdict() {
    #expect(HWash(verdict: .onTrack) == .onTrack)
    #expect(HWash(verdict: .overPace) == .overPace)
    #expect(HWash(verdict: .overBudget) == .overBudget)
    #expect(HWash(verdict: .done) == .onTrack)
    #expect(HWash.onTrack.top == HPalette.washOnTrack)
    #expect(HWash.overPace.top == HPalette.washOverPace)
    #expect(HWash.overBudget.top == HPalette.washOverBudget)
    #expect([HWash.setup.height, HWash.itWorks.height, HWash.welcome.height, HWash.onTrack.height] == [360, 480, 560, 420])
    // Page 04's recipe: the wash, half the wash at 38%, then clear.
    let stops = HWash.onTrack.stops
    #expect(stops.map(\.location) == [0, 0.38, 1])
    #expect(stops.map(\.color.opacity) == [1, 0.5, 0])
  }

  @Test func theRevealShowsZeroUntilTheFillStarts() {
    let amount = Money.aed(10_288_34)
    #expect(PaceFillPhase().figure(amount) == .aed(0))
    #expect(PaceFillPhase(fill: 0.2).figure(amount) == amount)
    #expect(PaceFillPhase.settled(0.54) == PaceFillPhase(fill: 0.54, tickVisible: true, verdictVisible: true))
  }

  /// The Home hero's first reveal plays once per process; later appearances show the end state.
  @MainActor @Test func aPerProcessRevealIsRememberedForTheProcess() {
    let memory = PaceFillMemory.shared
    memory.reset()
    #expect(!memory.hasPlayed("test.hero"))
    memory.markPlayed("test.hero")
    #expect(memory.hasPlayed("test.hero"))
    #expect(!memory.hasPlayed("test.other"))
    memory.reset()
  }

  @Test func haptics() {
    #expect(HHaptic.allCases.count == 5)
    #expect(HHaptic.selection.feedback == .selection)
    #expect(HHaptic.success.feedback == .success)
  }
}
