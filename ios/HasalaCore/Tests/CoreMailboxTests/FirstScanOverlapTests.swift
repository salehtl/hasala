import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct FirstScanOverlapTests {
  func reach(_ gate: Gate) async {
    for _ in 0..<100_000 where !gate.reached { await Task.yield() }
    #expect(gate.reached)
  }

  func failed(_ seen: ProgressLog) -> [MailboxProgress] {
    seen.all.filter { if case .failed = $0.stage { true } else { false } }
  }

  @Test func aRunThatEndsEarlyLeavesTheOtherRunsPassingStopsQuiet() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 10)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    rig.gmail.fail("/messages/d0", with: [500, 500, 500])
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    let gate = Gate()
    await rig.ledger.setSyncGate { await gate.pass() }
    let first = Task { await rig.engine.runFirstScan() }
    await reach(gate)
    await rig.ledger.setSyncGate(nil)
    let second = Task { () -> [CycleReport] in
      while !Task.isCancelled { await Task.yield() }
      return await rig.engine.runFirstScan()
    }
    second.cancel()
    #expect(await second.value.isEmpty)
    gate.open()
    let reports = await first.value
    #expect(reports.contains { $0.haltedOn == .gmail }, "\(reports)")
    #expect(reports.last?.phase == .active, "\(reports)")
    #expect(failed(seen).isEmpty, "\(failed(seen))")
  }

  @Test func aPassingStopOutsideAnyRunIsStillReported() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 10)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    _ = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await rig.engine.runFirstScan()
    }.value
    rig.gmail.fail("/messages/d0", with: [500, 500, 500])
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .gmail)
    #expect(seen.all.contains(MailboxProgress(stage: .failed(.gmail), done: 0, total: 0)))
  }
}
