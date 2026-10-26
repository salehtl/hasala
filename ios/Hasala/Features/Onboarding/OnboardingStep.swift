import Foundation

/// Where setup resumes: derived from facts every time, never stored (spec 04 §6.6; pwa
/// `stepFor`, the longest unbroken prefix of completed steps).
enum OnboardingStep: Int, Comparable, CaseIterable, Sendable {
  case passcode = 0
  case account
  case keys
  case bank
  /// Your email: a provider's read-only connect (or the review account's sample).
  case mail
  /// Every step is complete: the app opens.
  case finished

  static func < (a: OnboardingStep, b: OnboardingStep) -> Bool { a.rawValue < b.rawValue }

  /// The facts §6.6's table reads.
  struct Facts: Equatable, Sendable {
    var hasPasscode = true
    var hasSession = false
    var keysReady = false
    /// ≥ 1 bank projected, or "Skip" (manual-entry mode).
    var banksChosen = false
    var bankSkipped = false
    enum Mailbox: Equatable, Sendable { case unlinked, scanning, linked, otherDevice }
    var mailbox: Mailbox = .unlinked
    /// "Skip" on your email's step.
    var mailSkipped = false
    var sampleLoaded = false
    var textsChosen = false
  }

  static func derive(_ f: Facts) -> OnboardingStep {
    guard f.hasPasscode else { return .passcode }
    guard f.hasSession else { return .account }
    guard f.keysReady else { return .keys }
    guard f.banksChosen || f.bankSkipped || f.sampleLoaded || f.textsChosen else { return .bank }
    let manual = f.bankSkipped && !f.banksChosen
    let mailDone = manual || f.mailbox != .unlinked || f.mailSkipped || f.sampleLoaded || f.textsChosen
    guard mailDone else { return .mail }
    return .finished
  }
}
