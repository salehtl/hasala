import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct FirstScanUnreadStateTests {
  func scanning(count: Int = 10) async throws -> (Rig, UnreadableStateStore) {
    var wrapped: UnreadableStateStore?
    let rig = Rig(wrapStore: { base in
      let store = UnreadableStateStore(base)
      wrapped = store
      return store
    })
    FirstScanTests.backfill(rig, count: count)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    return (rig, try #require(wrapped))
  }

  @Test func aCycleThatCouldNotReadTheStateSaysSo() async throws {
    let (rig, store) = try await scanning()
    await store.setFailing(true)
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.stateUnread && r.haltedOn == .offline)
    await store.setFailing(false)
    #expect(await !rig.engine.runCycle(trigger: .refresh).stateUnread)
  }

  @Test func aReadThatFailsOnceDoesNotEndTheFirstScan() async throws {
    let (rig, store) = try await scanning()
    await store.setReadsToFail(1)
    let reports = await rig.engine.runFirstScan()
    #expect(reports.count == 2, "\(reports)")
    #expect(reports.first?.stateUnread == true)
    #expect(reports.last?.phase == .active && reports.last?.ops == 10)
  }

  @Test func aReadThatKeepsFailingGivesUpAfterTheStallWaits() async throws {
    let (rig, store) = try await scanning()
    await store.setFailing(true)
    let start = rig.clock.nowMs()
    let reports = await rig.engine.runFirstScan()
    #expect(reports.count == 5, "\(reports)")
    #expect(reports.allSatisfy { $0.stateUnread })
    #expect(rig.clock.nowMs() - start >= 52_000)
  }

  @Test func aStoppedCycleStaysAnEmptyReport() async throws {
    let (rig, _) = try await scanning()
    await rig.engine.stop()
    #expect(await rig.engine.runCycle(trigger: .refresh) == CycleReport())
  }
}
