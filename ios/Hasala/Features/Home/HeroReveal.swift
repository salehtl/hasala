import HasalaDesign
import QuartzCore
import SwiftUI

/// The hero's first reveal after launch (owner's motion policy, B1.3): the bar fills over
/// 300 ms (`fill`) with the figure rolling on it, the today tick drops in as the bar lands
/// (`marker`, 120 ms), then the verdict fades in (`verdict`, 150 ms): 0–300–420–570 ms. It
/// plays once per process. Every later appearance, Reduce Motion and settled motion show the
/// final state at once; a later change of `target` moves the bar on `fillUpdate`.
///
/// The three steps start together, the tick and the verdict on delays, so the render clock
/// keeps their spacing whatever else the main thread does (started from each step's
/// completion, a frame trace of a launch put the tick at 375 ms and the verdict at 540). The
/// design system's `paceFillSequence` now starts them the same way (requests/p5.md 4), but
/// Home keeps its own sequence for the launch: its fill waits for the first frame to be on
/// screen, so the launch's own work cannot take the fill's first frames.
struct HeroReveal: ViewModifier {
  @Binding var phase: PaceFillPhase
  let target: Double
  let policy: MotionPolicy
  /// Set once this hero has shown its first state: the reveal, or the final state at once.
  @State private var shown = false

  /// Whether the reveal has played in this process.
  private static var played = false

  /// When each step starts, in seconds from the start of the fill, and when the last one ends.
  struct Schedule: Equatable {
    var tick: Double
    var verdict: Double
    var end: Double
  }

  /// The owner's sequence: the tick as the fill lands, the verdict as the tick lands.
  static let schedule = Schedule(
    tick: HMotion.fill, verdict: HMotion.fill + HMotion.marker,
    end: HMotion.fill + HMotion.marker + HMotion.verdict)

  func body(content: Content) -> some View {
    content
      .onAppear(perform: appear)
      .onChange(of: target) { _, new in
        // A change after the first state: the bar moves to its new width; the tick and the
        // verdict stay (the verdict cross-fades if its word changes).
        guard shown else { return }
        withAnimation(policy.animation(.fillUpdate)) { phase = .settled(new) }
      }
  }

  private func appear() {
    guard !shown else { return }
    shown = true
    let plays = !Self.played && !policy.isStill && target > 0
    Self.played = true
    guard plays else {
      // Already played, Reduce Motion, settled, or nothing spent: the final state at once,
      // before the first frame is drawn.
      phase = .settled(target)
      return
    }
    phase = PaceFillPhase()
    DisplayFrame.next { [target, policy, phase = $phase] in
      // A change of the figures while the frame was drawn has settled the bar already.
      guard !phase.wrappedValue.started else { return }
      let schedule = Self.schedule
      withAnimation(policy.animation(.fill)) { phase.wrappedValue.fill = target }
      withAnimation(policy.animation(.marker)?.delay(schedule.tick)) {
        phase.wrappedValue.tickVisible = true
      }
      withAnimation(policy.animation(.verdict)?.delay(schedule.verdict)) {
        phase.wrappedValue.verdictVisible = true
      }
    }
  }
}

extension View {
  /// Runs the Home hero's first reveal into `phase` (see `HeroReveal`).
  func heroReveal(_ phase: Binding<PaceFillPhase>, target: Double, policy: MotionPolicy) -> some View {
    modifier(HeroReveal(phase: phase, target: target, policy: policy))
  }
}

/// Calls back once the display starts its next frame. Asked for while a frame is being built
/// (at launch, the first one), the call comes after that frame has been committed.
enum DisplayFrame {
  static func next(_ action: @escaping @MainActor () -> Void) {
    FrameWaiter(action).start()
  }
}

/// Holds the display link's target until its one callback (the link retains it until then).
private final class FrameWaiter: NSObject {
  private let action: @MainActor () -> Void

  init(_ action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  func start() {
    CADisplayLink(target: self, selector: #selector(frame(_:))).add(to: .main, forMode: .common)
  }

  @objc private func frame(_ link: CADisplayLink) {
    link.invalidate()
    action()
  }
}
