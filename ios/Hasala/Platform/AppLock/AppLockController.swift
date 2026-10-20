import Foundation
import HasalaDesign
import LocalAuthentication
import Observation
import SwiftUI

enum LockBiometry: Equatable, Sendable {
  case faceID, touchID, opticID, none

  init(_ type: LABiometryType) {
    switch type {
    case .faceID: self = .faceID
    case .touchID: self = .touchID
    case .opticID: self = .opticID
    default: self = .none
    }
  }

  var name: String {
    switch self {
    case .faceID: "Face ID"
    case .touchID: "Touch ID"
    case .opticID: "Optic ID"
    case .none: "passcode"
    }
  }

  var lockTitle: String {
    switch self {
    case .faceID: "Face ID lock"
    case .touchID: "Touch ID lock"
    case .opticID: "Optic ID lock"
    case .none: "Passcode lock"
    }
  }

  var unlockTitle: String {
    switch self {
    case .faceID: "Unlock with Face ID"
    case .touchID: "Unlock with Touch ID"
    case .opticID: "Unlock with Optic ID"
    case .none: "Unlock with passcode"
    }
  }

  var icon: HIcon { self == .faceID ? .faceID : .lock }
}

enum LockCheck: Equatable, Sendable {
  case passed, cancelled, failed, unavailable

  nonisolated init(_ error: (any Error)?) {
    guard let code = (error as? LAError)?.code else {
      self = .failed
      return
    }
    switch code {
    case .userCancel, .appCancel, .systemCancel, .userFallback, .notInteractive: self = .cancelled
    case .passcodeNotSet, .biometryNotAvailable: self = .unavailable
    default: self = .failed
    }
  }
}

enum BiometryIssue: Equatable, Sendable {
  case notEnrolled, denied, lockedOut
}

protocol LockContext {
  var biometry: LockBiometry { get }
  var biometryIssue: BiometryIssue? { get }
  func canEvaluate() -> Bool
  func evaluate(reason: String) async -> LockCheck
}

extension LockContext {
  var biometryIssue: BiometryIssue? { nil }
}

final class SystemLockContext: LockContext {
  private let context = LAContext()

  var biometry: LockBiometry { LockBiometry(context.biometryType) }

  var biometryIssue: BiometryIssue? {
    var error: NSError?
    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return nil }
    switch error.flatMap({ LAError.Code(rawValue: $0.code) }) {
    case .biometryNotEnrolled: return .notEnrolled
    case .biometryLockout: return .lockedOut
    case .biometryNotAvailable: return context.biometryType == .none ? nil : .denied
    default: return nil
    }
  }

  func canEvaluate() -> Bool {
    var error: NSError?
    return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
  }

  func evaluate(reason: String) async -> LockCheck {
    await withCheckedContinuation { (done: CheckedContinuation<LockCheck, Never>) in
      context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { @Sendable ok, error in
        done.resume(returning: ok ? .passed : LockCheck(error))
      }
    }
  }
}

@MainActor
@Observable
final class AppLockController {
  static let grace: Duration = .seconds(60)

  static let live = AppLockController(
    makeContext: { SystemLockContext() }, isEnabled: { DevicePrefsStore().prefs.faceIDLock })

  private(set) var isLocked = false
  private(set) var isCovered = false
  private(set) var busy = false
  private(set) var confirming = false
  private(set) var failed = false
  private(set) var isAvailable = false
  private(set) var biometry: LockBiometry = .none
  private(set) var biometryIssue: BiometryIssue?

  @ObservationIgnored private let makeContext: () -> any LockContext
  @ObservationIgnored private let isEnabled: () -> Bool
  @ObservationIgnored private let now: () -> ContinuousClock.Instant
  @ObservationIgnored private let grace: Duration
  @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
  @ObservationIgnored private var promptsOnActive = false

  init(
    makeContext: @escaping () -> any LockContext, isEnabled: @escaping () -> Bool,
    now: @escaping () -> ContinuousClock.Instant = { .now }, grace: Duration = AppLockController.grace
  ) {
    self.makeContext = makeContext
    self.isEnabled = isEnabled
    self.now = now
    self.grace = grace
    refreshAvailability()
    if isAvailable, isEnabled() {
      isLocked = true
      promptsOnActive = true
    }
  }

  var showsShield: Bool { isLocked || isCovered }

  func scenePhaseChanged(_ phase: ScenePhase) {
    isCovered = phase == .background || (SnapshotCover.covers(phase) && !confirming)
    switch phase {
    case .background:
      if backgroundedAt == nil { backgroundedAt = now() }
      promptsOnActive = isLocked
    case .active:
      refreshAvailability()
      if let at = backgroundedAt {
        backgroundedAt = nil
        if !isLocked, isAvailable, isEnabled(), at.duration(to: now()) >= grace {
          isLocked = true
          failed = false
          promptsOnActive = true
        }
      }
      if isLocked, !isAvailable { isLocked = false }
      if isLocked, promptsOnActive {
        promptsOnActive = false
        Task { await unlock() }
      }
    default:
      break
    }
  }

  func unlock() async {
    guard isLocked, !busy else { return }
    busy = true
    failed = false
    let check = await makeContext().evaluate(reason: "Unlock Hasala to see your money.")
    busy = false
    switch check {
    case .passed:
      isLocked = false
    case .unavailable:
      refreshAvailability()
      if isAvailable { failed = true } else { isLocked = false }
    case .failed:
      failed = true
    case .cancelled:
      break
    }
  }

  func confirmChange(to on: Bool) async -> Bool {
    await requestChange(to: on) == .passed
  }

  func requestChange(to on: Bool) async -> LockCheck {
    guard !busy else { return .cancelled }
    busy = true
    confirming = true
    let check = await makeContext().evaluate(
      reason: on ? "Turn on \(biometry.lockTitle) for Hasala." : "Turn off \(biometry.lockTitle) for Hasala.")
    busy = false
    confirming = false
    if check == .unavailable { refreshAvailability() }
    return check
  }

  func refreshAvailability() {
    let context = makeContext()
    isAvailable = context.canEvaluate()
    biometryIssue = context.biometryIssue
    biometry = context.biometry
  }
}
