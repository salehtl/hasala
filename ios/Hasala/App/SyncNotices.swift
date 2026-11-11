import CoreSync
import Observation

@MainActor
@Observable
final class SyncNotices {
  private(set) var uploadsStuck = false
  private(set) var setAside = 0
  @ObservationIgnored var eraseThisIPhone: (@MainActor () async -> Void)?
  @ObservationIgnored var acknowledge: @MainActor () async -> Void = {}
  @ObservationIgnored private var acknowledging = false

  func update(_ status: CoreSync.SyncStatus) {
    if uploadsStuck != status.uploadsStuck { uploadsStuck = status.uploadsStuck }
    let alarms = acknowledging ? 0 : status.rowAlarms
    if setAside != alarms { setAside = alarms }
  }

  @discardableResult
  func acknowledgeSetAside() -> Task<Void, Never>? {
    guard setAside > 0 else { return nil }
    setAside = 0
    acknowledging = true
    let acknowledge = acknowledge
    return Task { [weak self] in
      await acknowledge()
      self?.acknowledging = false
    }
  }
}
