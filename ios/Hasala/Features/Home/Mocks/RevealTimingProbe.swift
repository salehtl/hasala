#if HASALA_MOCKS
  import HasalaDesign
  import QuartzCore
  import SwiftUI

  /// Debug only, with `-HasalaRevealTiming`: when the hero's first reveal reached the screen,
  /// in milliseconds from the start of the fill, as the value of `home.hero.revealTiming`:
  /// "fill 0, filled 295, tick 305, verdict 425, done 555" (the first frame with the bar at its
  /// width, with the tick and with the verdict showing, and with the verdict fully in), or
  /// "settled" when the final state showed at once.
  ///
  /// It times frames, not state: three invisible views take the bar's, the tick's and the
  /// verdict's values in the same transactions, so they animate as those do, and each frame
  /// they draw is stamped. The fill's start is worked back from its first moving frame (an
  /// animation starts when it is first drawn, which can be a while after the change).
  /// `SmokeTests` holds the owner's 0–300–420–570 sequence with it (an XCUITest query takes
  /// longer than the 120 ms tick, so the app times itself).
  struct RevealTimingProbe: ViewModifier {
    static let argument = "-HasalaRevealTiming"
    private static let enabled = ProcessInfo.processInfo.arguments.contains(argument)

    let phase: PaceFillPhase
    /// The fill's final width (spent as a share of the plan).
    let target: Double
    @State private var log = RevealFrameLog()

    func body(content: Content) -> some View {
      if Self.enabled {
        content
          .background(alignment: .topLeading) {
            HStack(spacing: 0) {
              FrameSampler(value: phase.fill) { log.fill($0, target: target) }
              FrameSampler(value: phase.tickVisible ? 1 : 0) { log.tick($0) }
              FrameSampler(value: phase.verdictVisible ? 1 : 0) { log.verdict($0) }
            }
            .accessibilityHidden(true)
          }
          .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
              .accessibilityElement()
              .accessibilityLabel("Reveal timing")
              .accessibilityValue(log.summary)
              .accessibilityIdentifier("home.hero.revealTiming")
          }
      } else {
        content
      }
    }
  }

  /// An invisible view that a value animates through, frame by frame.
  private struct FrameSampler: View, Animatable {
    var value: Double
    let record: (Double) -> Void

    nonisolated var animatableData: Double {
      get { value }
      set { value = newValue }
    }

    var body: some View {
      record(value)
      return Color.clear.frame(width: 1, height: 1)
    }
  }

  /// The frames the reveal drew, stamped on the media clock; the summary is published once the
  /// verdict is fully in (after the frame, never during a view update).
  @MainActor @Observable
  private final class RevealFrameLog {
    private(set) var summary = ""
    @ObservationIgnored private var start: CFTimeInterval?
    @ObservationIgnored private var marks: [(String, CFTimeInterval)] = []
    @ObservationIgnored private var finished = false

    func fill(_ value: Double, target: Double) {
      guard !finished else { return }
      let now = CACurrentMediaTime()
      guard value > 0 else { return }
      if start == nil {
        // At its width on the first frame it shows: the final state, at once.
        guard value < target - 0.0005 else { return publish("settled") }
        start = now - Self.fillElapsed(share: value / target)
      }
      if value >= target - 0.0005 { mark("filled", now) }
    }

    /// How far into the fill a frame showing `share` of its width is, in seconds: the inverse
    /// of the fill's curve, cubic-bezier(.65, 0, .35, 1), whose y is 3s² − 2s³.
    static func fillElapsed(share: Double) -> Double {
      var low = 0.0, high = 1.0
      for _ in 0..<40 {
        let s = (low + high) / 2
        if 3 * s * s - 2 * s * s * s < share { low = s } else { high = s }
      }
      let s = (low + high) / 2
      let x = 3 * (1 - s) * (1 - s) * s * 0.65 + 3 * (1 - s) * s * s * 0.35 + s * s * s
      return x * HMotion.fill
    }

    func tick(_ value: Double) {
      if value > 0 { mark("tick", CACurrentMediaTime()) }
    }

    func verdict(_ value: Double) {
      let now = CACurrentMediaTime()
      if value > 0 { mark("verdict", now) }
      guard value >= 0.999, let start, !finished else { return }
      mark("done", now)
      let text = (["fill 0"] + marks.map { "\($0.0) \(Int((($0.1 - start) * 1000).rounded()))" })
        .joined(separator: ", ")
      publish(text)
    }

    /// The first frame of a step, once the fill has started.
    private func mark(_ name: String, _ time: CFTimeInterval) {
      guard start != nil, !finished, !marks.contains(where: { $0.0 == name }) else { return }
      marks.append((name, time))
    }

    private func publish(_ text: String) {
      finished = true
      Task { @MainActor in self.summary = text }
    }
  }
#endif
