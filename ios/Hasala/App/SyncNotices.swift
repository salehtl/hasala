import CoreSync
import Observation

@MainActor
@Observable
final class SyncNotices {
  private(set) var uploadsStuck = false
  @ObservationIgnored var eraseThisIPhone: (@MainActor () async -> Void)?

  func update(_ status: CoreSync.SyncStatus) {
    if uploadsStuck != status.uploadsStuck { uploadsStuck = status.uploadsStuck }
  }
}
