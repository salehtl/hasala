import HasalaDesign
import Observation

struct AppLockSetting: Equatable {
  let title: String
  let icon: HIcon
  let note: String
  let offersSettings: Bool
  let canTurnOn: Bool

  init(biometry: LockBiometry, isAvailable: Bool, issue: BiometryIssue?) {
    title = biometry.lockTitle
    icon = biometry.icon
    guard isAvailable else {
      note = "Set a passcode on this iPhone first. The lock needs it."
      offersSettings = true
      canTurnOn = false
      return
    }
    canTurnOn = true
    switch issue {
    case .notEnrolled:
      note = "\(biometry.name) isn't set up on this iPhone, so Hasala asks for your passcode. You can set it up in Settings."
      offersSettings = true
    case .denied:
      note = "\(biometry.name) is off for Hasala, so it asks for your passcode. You can allow it in Settings."
      offersSettings = true
    case .lockedOut:
      note = "\(biometry.name) is locked after too many tries. Hasala asks for your passcode until you unlock your iPhone with it."
      offersSettings = false
    case nil:
      note = biometry == .none
        ? "Hasala asks for your iPhone passcode when you come back after a minute away."
        : "Hasala asks for \(biometry.name) when you come back after a minute away. Your passcode works too."
      offersSettings = false
    }
  }
}

@MainActor
@Observable
final class AppLockSettingModel {
  private(set) var failed = false

  @ObservationIgnored private let lock: AppLockController
  @ObservationIgnored private let read: () -> Bool
  @ObservationIgnored private let write: (Bool) -> Void

  init(lock: AppLockController, read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
    self.lock = lock
    self.read = read
    self.write = write
  }

  var isOn: Bool { read() }
  var busy: Bool { lock.busy }

  var setting: AppLockSetting {
    AppLockSetting(biometry: lock.biometry, isAvailable: lock.isAvailable, issue: lock.biometryIssue)
  }

  func refresh() { lock.refreshAvailability() }

  func setOn(_ on: Bool) async {
    guard on != isOn else { return }
    failed = false
    if !lock.isAvailable {
      if !on { write(false) }
      return
    }
    switch await lock.requestChange(to: on) {
    case .passed: write(on)
    case .cancelled: break
    case .failed: failed = true
    case .unavailable: if !on { write(false) }
    }
  }
}
