import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct FirstScanProgressResetTests {
  func scannedThenDisconnected(_ rig: Rig, count: Int) async {
    FirstScanTests.backfill(rig, count: count)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(await rig.engine.runFirstScan().last?.phase == .active)
    #expect(await rig.engine.disconnect(removing: nil) == .disconnected)
    for i in 0..<count { rig.gmail.remove(i % 2 == 0 ? "d\(i)" : "e\(i)") }
  }

  func newMail(_ rig: Rig, count: Int) {
    for i in 0..<count {
      rig.gmail.add(SyntheticMail.dibCard(id: "n\(i)", amount: "\(i + 1).50", dateMs: Rig.t0 - 60_000 - Int64(i) * 3_600_000))
    }
  }

  @Test func aNewScanInTheSameProcessStartsWithThisMonthUnread() async {
    let rig = Rig()
    await scannedThenDisconnected(rig, count: 50)
    newMail(rig, count: 50)
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    _ = await rig.engine.runFirstScan()
    #expect(seen.all.first?.thisMonthRead == false, "\(seen.all.prefix(3))")
  }

  @Test func aPagedNewScanDoesNotCarryTheLastTotal() async {
    let rig = Rig()
    await scannedThenDisconnected(rig, count: 250)
    newMail(rig, count: 20)
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let r = await rig.engine.runCycle(trigger: .processing)
    #expect(r.phase == .active, "\(r)")
    let reading = seen.all.filter { $0.stage == .downloading }
    #expect(!reading.isEmpty && reading.allSatisfy { $0.total <= 20 }, "\(reading)")
    #expect(seen.all.last == MailboxProgress(stage: .done, done: 20, total: 20, thisMonthRead: true))
  }

  @Test func aReconnectInTheMiddleOfAScanKeepsItsTotal() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 250)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    rig.gmail.fail("/messages/d150", with: [500, 500, 500])
    let cut = await rig.engine.runCycle(trigger: .refresh)
    #expect(cut.phase == .scanning && cut.haltedOn != nil, "\(cut)")
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    let r = await rig.engine.runCycle(trigger: .processing)
    #expect(r.phase == .active, "\(r)")
    let reading = seen.all.filter { $0.stage == .downloading }
    #expect(!reading.isEmpty && reading.allSatisfy { $0.total == 250 }, "\(reading)")
  }
}
