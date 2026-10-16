import Foundation

/// Where setup resumes: derived from facts every time, never stored (spec 04 §6.6; pwa
/// `stepFor`, the longest unbroken prefix of completed steps).
enum OnboardingStep: Int, Comparable, CaseIterable, Sendable {
  case passcode = 0
  case account
  case keys
  case bank
  case mailbox
  case scan
  case income
  case plan
  case notifications
  case done
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
    var mailboxSkipped = false
    var sampleLoaded = false
    /// "Set up your plan" was tapped in this process while the scan runs.
    var scanDeferred = false
    var incomeSet = false
    var incomeSkipped = false
    var planSet = false
    var planSkipped = false
    var notificationsAsked = false
    var finished = false
  }

  static func derive(_ f: Facts) -> OnboardingStep {
    guard f.hasPasscode else { return .passcode }
    guard f.hasSession else { return .account }
    guard f.keysReady else { return .keys }
    guard f.banksChosen || f.bankSkipped else { return .bank }
    // Skipping the bank skips the mailbox and the scan: nothing can be listed.
    let manual = f.bankSkipped && !f.banksChosen
    let mailboxDone = manual || f.mailbox != .unlinked || f.mailboxSkipped || f.sampleLoaded
    guard mailboxDone else { return .mailbox }
    let noScan = manual || f.mailboxSkipped || f.sampleLoaded || f.mailbox == .otherDevice
    if !noScan, f.mailbox == .scanning, !f.scanDeferred { return .scan }
    guard f.incomeSet || f.incomeSkipped || f.sampleLoaded else { return .income }
    guard f.planSet || f.planSkipped || f.sampleLoaded else { return .plan }
    // A scan still running doesn't hold setup up: it carries on in the background.
    guard f.notificationsAsked else { return .notifications }
    guard f.finished else { return .done }
    return .finished
  }

  /// The step indicator: bank 1, mailbox and scan 2, income 3, plan 4 "of 4"; later boards
  /// carry no number.
  var indicator: Int? {
    switch self {
    case .bank: 1
    case .mailbox, .scan: 2
    case .income: 3
    case .plan: 4
    default: nil
    }
  }
}
