import Foundation
import HasalaDesign

/// How far the playing welcome story is (spec 04 §2.3: the current segment fills over 6 s,
/// then the pager moves on). It runs only while the person can watch it: not while they
/// drag, not under the "Who can see what" sheet, not while VoiceOver runs, not in the
/// background and not under a pushed screen. Paused, it keeps what it had, so the story
/// carries on where it stopped. A value, so its rules are tested without a screen.
struct StoryClock: Equatable, Sendable {
  /// One story (`HMotion.storyDuration`, the progress bar and the orbit dot share it).
  static let duration = HMotion.storyDuration

  /// Time banked before the last pause.
  private(set) var banked: TimeInterval = 0
  /// When it last started running; nil while paused.
  private(set) var runningSince: Date?

  var isRunning: Bool { runningSince != nil }

  /// The story played so far, 0…1.
  func progress(at now: Date) -> Double {
    min(1, max(0, played(at: now) / Self.duration))
  }

  /// Time left before the story ends (0 once it has).
  func remaining(at now: Date) -> TimeInterval {
    max(0, Self.duration - played(at: now))
  }

  private func played(at now: Date) -> TimeInterval {
    banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
  }

  /// Runs from where it stopped. Running already, nothing changes.
  mutating func resume(at now: Date) {
    guard runningSince == nil, banked < Self.duration else { return }
    runningSince = now
  }

  /// Stops and keeps what was played.
  mutating func pause(at now: Date) {
    guard runningSince != nil else { return }
    banked = min(Self.duration, played(at: now))
    runningSince = nil
  }

  /// A new story starts from nothing, running or not.
  mutating func restart(at now: Date, running: Bool) {
    banked = 0
    runningSince = running ? now : nil
  }

  /// The story ran out: it stays full and stops (after the last story the pager waits).
  mutating func finish() {
    banked = Self.duration
    runningSince = nil
  }
}
