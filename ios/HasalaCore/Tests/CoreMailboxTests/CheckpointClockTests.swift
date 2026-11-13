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

  func connectOnlyNew(_ rig: Rig) async {
    #expect(
      await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, pastMail: .skip())
        == .connected(address: rig.gmail.email))
  }

  func listedAfter(_ rig: Rig) -> String { rig.listRequests.last?.query.first { $0.0 == "q" }?.1 ?? "" }

  @Test func onlyNewMailSetWhileTheClockRanAheadKeepsItsFloorUntilThePersonImports() async {
    let rig = Rig()
    rig.clock.set(t0 + 10 * day)
    await connectOnlyNew(rig)
    rig.clock.advance(day)
    #expect(await rig.engine.runCycle(trigger: .refresh).completed)
    rig.clock.set(t0 + day)
    rig.gmail.add(SyntheticMail.dibCard(id: "between", amount: "2.00", dateMs: t0 + 3_600_000))
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 0 && r.completed, "\(r)")
    #expect(await rig.accounted("between") == nil)
    #expect(await rig.state().readFromMs == t0 + 10 * day)
    #expect(await rig.engine.importPastMail().completed)
    #expect(await rig.accounted("between") == .op)
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func onlyNewMailKeepsItsFloorWhenTheClockIsSetBack(_ backend: Backend) async {
    let rig = Rig(backend: backend)
    rig.gmail.add(SyntheticMail.dibCard(id: "before", dateMs: t0 - 5 * day))
    await connectOnlyNew(rig)
    rig.clock.set(t0 + 3 * day)
    #expect(await rig.engine.runCycle(trigger: .refresh).completed)
    rig.clock.set(t0 - 7 * day)
    rig.gmail.add(SyntheticMail.dibCard(id: "after", amount: "2.00", dateMs: t0 + day))
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.completed, "\(r)")
    #expect(await rig.accounted("before") == nil)
    #expect(await rig.accounted("after") == .op)
    #expect(await rig.state().readFromMs == t0)
    let again = await rig.restarted().runCycle(trigger: .refresh)
    #expect(again.ops == 0 && again.completed, "\(again)")
    #expect(await rig.accounted("before") == nil)
    #expect(await rig.state().readFromMs == t0)
  }

  @Test(arguments: [30, 90])
  func aClockSetBackDoesNotReadPastTheWindowTheConnectCovered(_ days: Int) async {
    let window = Int64(days) * day
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "old", dateMs: t0 - window - 20 * day))
    await rig.connectAndActivate(days: days)
    #expect(await rig.accounted("old") == nil)
    rig.clock.set(t0 - 30 * day)
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 0 && r.completed, "\(r)")
    #expect(await rig.accounted("old") == nil)
    #expect(listedAfter(rig).contains("after:\((t0 - window) / 1000)"), "\(listedAfter(rig))")
  }

  @Test func aClockSetBackPastTheWholeWindowGoesBackOnce() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.clock.set(t0 - 120 * day)
    rig.gmail.clearRequests()
    #expect(await rig.engine.runCycle(trigger: .refresh).completed)
    #expect(listedAfter(rig).contains("after:\((t0 - 90 * day) / 1000)"), "\(listedAfter(rig))")
    #expect(await rig.state().watermarkMs == t0 - 88 * day)
    rig.gmail.clearRequests()
    #expect(await rig.engine.runCycle(trigger: .silentPush).completed)
    #expect(rig.listRequests.isEmpty)
  }

  @Test func mailThatArrivesWhileTheClockIsSetBackIsReadOnceItIsCorrected() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.clock.set(t0 - 30 * day)
    #expect(await rig.engine.runCycle(trigger: .refresh).completed)
    #expect(await rig.state().watermarkMs == t0 - 30 * day)
    rig.gmail.add(SyntheticMail.dibCard(id: "new", dateMs: t0 + 3_600_000))
    rig.clock.set(t0 + day)
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.completed, "\(r)")
    #expect(await rig.accounted("new") == .op)
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
