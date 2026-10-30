import CoreStore
import CoreSync
import Testing

@testable import Hasala

@MainActor
@Suite("Sync halts")
struct SyncHaltTests {
  static let shown: [HaltKind] =
    TamperReason.allCases.map(HaltKind.tampered) + [.tamperedResend, .serverRestored, .inconsistent("fold"), .rosterInvalid, .unprovedRevocation, .unexpectedGone]

  @Test func everyHaltButAnUpdatePutsUpTheHaltWall() {
    for halt in Self.shown {
      #expect(BootController.syncHalt(for: .halted(halt)) == halt, "\(halt)")
    }
    #expect(BootController.syncHalt(for: .halted(.updateRequired)) == nil)
    for stop: SyncStop in [.offline, .frozen, .wipe, .needsSignIn, .suspended, .notNow, .latched(.chainBreak)] {
      #expect(BootController.syncHalt(for: stop) == nil, "\(stop)")
    }
  }

  @Test func onlyARunThatGetsThroughTakesTheWallAway() {
    #expect(BootController.clearsSyncHalt(nil))
    #expect(BootController.clearsSyncHalt(.latched(.accountFull)))
    #expect(BootController.clearsSyncHalt(.rateLimited(retryAfter: 30)))
    #expect(!BootController.clearsSyncHalt(.halted(.tampered(.chainBreak))))
    #expect(!BootController.clearsSyncHalt(.halted(.serverRestored)))
    #expect(!BootController.clearsSyncHalt(.offline))
    #expect(!BootController.clearsSyncHalt(.protocolError("refused 409 cursor_ahead")))
  }

  @Test func aRestoredServerIsShownAsRestoredNotTampered() {
    #expect(
      AccountRuntime.shownStop(.halted(.tampered(.chainBreak)), phase: .halted(.serverRestored)) == .halted(.serverRestored))
    #expect(
      AccountRuntime.shownStop(.halted(.tamperedResend), phase: .halted(.serverRestored)) == .halted(.serverRestored))
    #expect(
      AccountRuntime.shownStop(.halted(.tampered(.chainBreak)), phase: .halted(.tampered(.chainBreak)))
        == .halted(.tampered(.chainBreak)))
    #expect(AccountRuntime.shownStop(.store(.notCreated), phase: .halted(.inconsistent("store"))) == .store(.notCreated))
    #expect(AccountRuntime.shownStop(.offline, phase: .offline(sinceMs: 1)) == .offline)
    #expect(AccountRuntime.shownStop(nil, phase: .idle) == nil)
  }

  @Test func theWallSaysWhatHappenedThatTheDataStaysAndWhatToDo() {
    #expect(SyncHaltWall.kept.contains("kept"))
    #expect(!SyncHaltWall.kept.localizedCaseInsensitiveContains("remove this"))
    var codes = Set<String>()
    for halt in Self.shown {
      let reason = SyncHaltWall.reason(halt)
      #expect(reason.contains("stopped"), "\(halt)")
      #expect(!reason.localizedCaseInsensitiveContains("erase") && !reason.localizedCaseInsensitiveContains("reset"))
      let next = SyncHaltWall.next(halt)
      #expect(next.contains("support@hasala.app") && next.contains(SyncHaltWall.code(halt)), "\(halt)")
      codes.insert(SyncHaltWall.code(halt))
    }
    #expect(codes.count == Self.shown.count)
    #expect(SyncHaltWall.reason(.serverRestored) != SyncHaltWall.reason(.tampered(.chainBreak)))
  }

  @Test func theDebugLaunchNamesEveryHaltByItsCode() {
    for halt in MockSyncHalt.kinds {
      #expect(MockSyncHalt.halt(SyncHaltWall.code(halt)) == halt)
    }
    #expect(MockSyncHalt.halt("nonsense") == nil)
    #expect(MockSyncHalt([]).halt == nil)
    #expect(MockSyncHalt(["-HasalaSyncHalt", "serverRestored"]).halt == .serverRestored)
  }
}
