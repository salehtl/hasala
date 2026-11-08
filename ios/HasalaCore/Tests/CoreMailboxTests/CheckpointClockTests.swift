import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct CheckpointClockTests {
  let day: Int64 = 86_400_000
  let t0 = Rig.t0

  func ranAhead(_ rig: Rig, by ahead: Int64) async {
    await rig.connectAndActivate()
    rig.clock.set(t0 + ahead)
    #expect(await rig.engine.runCycle(trigger: .refresh).completed)
    #expect(await rig.state().watermarkMs == t0 + ahead)
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func mailFromTheDaysTheClockRanAheadIsReadOnceTheClockIsBack(_ backend: Backend) async {
    let rig = Rig(backend: backend)
    await ranAhead(rig, by: 10 * day)
    rig.clock.set(t0 + 5 * day)
    rig.gmail.add(SyntheticMail.dibCard(id: "gap", dateMs: t0 + day))
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.completed, "\(r)")
    #expect(await rig.enqueued().map(\.messageID) == ["gap"])
    #expect(await rig.state().watermarkMs == t0 + 5 * day)
  }

  @Test func theListingGoesBackOverTheConnectWindowOnce() async {
    let rig = Rig()
    await ranAhead(rig, by: 10 * day)
    let now = t0 + 5 * day
    rig.clock.set(now)
    rig.gmail.clearRequests()
    _ = await rig.engine.runCycle(trigger: .refresh)
    func after() -> String { rig.listRequests.last?.query.first { $0.0 == "q" }?.1 ?? "" }
    #expect(after().contains("after:\((now - 92 * day) / 1000)"), "\(after())")
    rig.clock.advance(60_000)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(after().contains("after:\((now - 2 * day) / 1000)"), "\(after())")
  }

  @Test func aWakeWithNoNewHistoryStillListsAfterTheClockCameBack() async {
    let rig = Rig()
    await ranAhead(rig, by: 10 * day)
    rig.gmail.add(SyntheticMail.dibCard(id: "gap", dateMs: t0 + day))
    rig.clock.set(t0 + 12 * day)
    let hidden = await rig.engine.runCycle(trigger: .refresh)
    #expect(hidden.ops == 0 && hidden.completed)
    rig.clock.set(t0 + 5 * day)
    let r = await rig.engine.runCycle(trigger: .silentPush)
    #expect(r.ops == 1, "\(r)")
  }

  @Test func aCycleCutAfterTheClockCameBackKeepsTheWiderWindowAcrossARestart() async {
    let rig = Rig()
    await ranAhead(rig, by: 10 * day)
    rig.clock.set(t0 + 5 * day)
    rig.gmail.add(SyntheticMail.dibCard(id: "gap", dateMs: t0 + day))
    rig.gmail.fail("/messages/gap", with: [500, 500, 500])
    let cut = await rig.engine.runCycle(trigger: .refresh)
    #expect(!cut.completed && cut.haltedOn != nil, "\(cut)")
    #expect((await rig.state().watermarkMs ?? .max) <= t0 + day)
    let r = await rig.restarted().runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.completed, "\(r)")
  }

  @Test func mailAlreadyFiledIsNotFiledAgainByTheWiderWindow() async {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "filed", dateMs: t0 - day))
    await ranAhead(rig, by: 10 * day)
    #expect(await rig.enqueued().map(\.messageID) == ["filed"])
    await rig.ledger.setProjected(["filed"])
    rig.clock.set(t0 + 5 * day)
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 0 && r.completed, "\(r)")
    #expect(await rig.enqueued().map(\.messageID) == ["filed"])
  }

  @Test func onlyNewMailKeepsItsFloorWhenTheClockCameBack() async {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "before", dateMs: t0 - day))
    rig.clock.set(t0 + 10 * day)
    #expect(
      await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, pastMail: .skip())
        == .connected(address: rig.gmail.email))
    rig.clock.advance(day)
    #expect(await rig.engine.runCycle(trigger: .refresh).completed)
    rig.clock.set(t0 + day)
    rig.gmail.add(SyntheticMail.dibCard(id: "after", amount: "2.00", dateMs: t0 + 3_600_000))
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.completed, "\(r)")
    #expect(await rig.accounted("after") == .op)
    #expect(await rig.accounted("before") == nil)
    #expect(await rig.state().readFromMs == t0)
  }

  @Test func aClockThatNeverRanAheadListsFromTheCheckpoint() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.clock.advance(3_600_000)
    rig.gmail.clearRequests()
    _ = await rig.engine.runCycle(trigger: .refresh)
    let q = rig.listRequests.last?.query.first { $0.0 == "q" }?.1 ?? ""
    #expect(q.contains("after:\((t0 - 2 * day) / 1000)"), "\(q)")
  }
}
