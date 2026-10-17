import SwiftUI

/// The haptics map (spec 01 §4.11, B1.4, motion policy): one tap you can feel for each thing
/// the person did, fired when the motion settles. Nothing buzzes on its own: auto-advance,
/// timers and a scan finishing get none. Reduce Motion removes travel, never haptics. Every
/// kind goes through `.sensoryFeedback`, so the system haptics setting is respected.
public enum HHaptic: Sendable, Hashable, CaseIterable {
  /// A swipe or tap settles on a new Welcome story; a picker step (the payday day strip).
  case selection
  /// A review card crosses the commit point (or a pill files it); Welcome key moments.
  case impactLight
  /// The Welcome lock snaps shut (story 3), once.
  case impactRigid
  /// A keypad key, a split-handle step: light and low.
  case keyTick
  /// A mailbox connects; "You're set".
  case success

  /// The system feedback this kind plays.
  public var feedback: SensoryFeedback {
    switch self {
    case .selection: .selection
    case .impactLight: .impact(weight: .light)
    case .impactRigid: .impact(flexibility: .rigid)
    case .keyTick: .impact(weight: .light, intensity: 0.5)
    case .success: .success
    }
  }
}

public extension View {
  /// Plays `kind` each time `trigger` changes.
  func hHaptic<T: Equatable>(_ kind: HHaptic, trigger: T) -> some View {
    sensoryFeedback(kind.feedback, trigger: trigger)
  }

  /// Plays `kind` when `trigger` changes and `condition(old, new)` holds, for example only when
  /// the person (not a timer) moved a pager.
  func hHaptic<T: Equatable>(_ kind: HHaptic, trigger: T, condition: @escaping (T, T) -> Bool) -> some View {
    sensoryFeedback(kind.feedback, trigger: trigger, condition: condition)
  }
}
