import CoreStore
import CoreSync
import HasalaMocks
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

  @Test func theSheetFollowsTheAlarmsAndOKAcknowledgesThemOnce() async {
    let notices = SyncNotices()
    var acknowledged = 0
    notices.acknowledge = { acknowledged += 1 }
    var status = CoreSync.SyncStatus()
    notices.update(status)
    #expect(notices.setAside == 0)
    #expect(notices.acknowledgeSetAside() == nil)
    status.integrityAlarms = 2
    status.rowAlarms = 2
    notices.update(status)
    #expect(notices.setAside == 2)

    let ack = notices.acknowledgeSetAside()
    #expect(notices.setAside == 0)
    notices.update(status)
    #expect(notices.setAside == 0)
    await ack?.value
    #expect(acknowledged == 1)
    #expect(notices.acknowledgeSetAside() == nil)
    #expect(acknowledged == 1)

    status.integrityAlarms = 1
    status.rowAlarms = 1
    notices.update(status)
    #expect(notices.setAside == 1)
  }

  @Test func anUploadAlarmAloneLeavesTheSheetDown() {
    let notices = SyncNotices()
    var acknowledged = 0
    notices.acknowledge = { acknowledged += 1 }
    var status = CoreSync.SyncStatus()
    status.latch = .hardStop
    status.integrityAlarms = 1
    notices.update(status)
    #expect(notices.uploadsStuck)
    #expect(notices.setAside == 0)
    #expect(notices.acknowledgeSetAside() == nil)
    #expect(acknowledged == 0)

    status.integrityAlarms = 2
    status.rowAlarms = 1
    notices.update(status)
    #expect(notices.setAside == 1)
  }

  @Test func onlyThePersonDismissingTheSheetAcknowledgesIt() {
    let app = AppModel(store: InMemoryLedger())
    var status = CoreSync.SyncStatus()
    status.integrityAlarms = 1
    status.rowAlarms = 1
    app.syncNotices.update(status)
    let showing = MainView.setAsideShowing(app)
    #expect(showing.wrappedValue)

    app.router.sheet = .search
    #expect(!showing.wrappedValue)
    showing.wrappedValue = false
    #expect(app.syncNotices.setAside == 1)
    app.router.sheet = nil
    app.router.cover = .review
    #expect(!showing.wrappedValue)
    showing.wrappedValue = false
    #expect(app.syncNotices.setAside == 1)
    app.router.cover = nil
    #expect(showing.wrappedValue)

    showing.wrappedValue = false
    #expect(app.syncNotices.setAside == 0)
    #expect(!showing.wrappedValue)
  }

  @Test func theSheetSaysWhatWasSetAsideWithNoContent() {
    #expect(SetAsideSheet.title == "Hasala set a change aside")
    #expect(SetAsideSheet.message == "A change from your account didn't open on this iPhone, so Hasala left it out. Everything else keeps syncing.")
    #expect(SetAsideSheet.codeLead == "If it happens again, email support@hasala.app and mention this code")
    #expect(SetAsideSheet.code == "integrityAlarm")
  }

  @Test func theBannerSaysReadingStillWorksAndOffersSupportAndTheErase() {
    #expect(UploadsStuckBanner.message == "Changes on this iPhone aren't uploading. Reading your bank alerts still works.")
    #expect(UploadsStuckBanner.emailTitle == "Email support@hasala.app")
    #expect(UploadsStuckBanner.eraseTitle == "Remove this iPhone's data")
    #expect(BootWallView.eraseAlertTitle == "Remove this iPhone's Hasala data?")
  }
}
