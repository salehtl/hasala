import CoreStore
import CoreSync
import Testing

@testable import Hasala

@MainActor
@Suite("Sync notices")
struct SyncNoticesTests {
  @Test func theBannerShowsOnlyWhileAHardStopOrASealerFaultHoldsTheUploads() {
    let notices = SyncNotices()
    var status = CoreSync.SyncStatus()
    notices.update(status)
    #expect(!notices.uploadsStuck)
    for latch in OutboxLatch.allCases {
      status.latch = latch
      notices.update(status)
      #expect(notices.uploadsStuck == (latch == .hardStop || latch == .sealerFault), "\(latch)")
    }
    status.latch = nil
    notices.update(status)
    #expect(!notices.uploadsStuck)
  }

  @Test func theBannerSaysReadingStillWorksAndOffersSupportAndTheErase() {
    #expect(UploadsStuckBanner.message == "Changes on this iPhone aren't uploading. Reading your bank alerts still works.")
    #expect(UploadsStuckBanner.emailTitle == "Email support@hasala.app")
    #expect(UploadsStuckBanner.eraseTitle == "Remove this iPhone's data")
    #expect(BootWallView.eraseAlertTitle == "Remove this iPhone's Hasala data?")
  }
}
