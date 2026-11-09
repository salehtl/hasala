import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct FirstScanListingTests {
  static let day: Int64 = 86_400_000

  func seeded(count: Int) -> Rig {
    let rig = Rig()
    for i in 0..<count { rig.gmail.add(SyntheticMail.dibCard(id: "d\(i)", dateMs: Rig.t0 - Int64(i + 1) * Self.day)) }
    return rig
  }

  func queries(_ rig: Rig) -> [String] {
    rig.listRequests.map { r in r.query.first { $0.0 == "q" }?.1 ?? "" }
  }

  @Test func aScanThatReadItsWholeWindowDoesNotListItAgain() async {
    let rig = seeded(count: 3)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)

    let done = await rig.engine.runCycle(trigger: .launch)

    #expect(done.completed && done.phase == .active && done.ops == 3 && done.listed == 3)
    let asked = queries(rig)
    #expect(!asked.isEmpty && Set(asked).count == asked.count)
  }

  @Test func aScanStoppedByTheCapStillListsTheRestOfItsWindow() async {
    let rig = Rig { $0.stagingCap = 2 }
    for i in 0..<4 { rig.gmail.add(SyntheticMail.dibCard(id: "d\(i)", dateMs: Rig.t0 - Int64(i + 1) * Self.day)) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)

    let done = await rig.engine.runCycle(trigger: .launch)

    #expect(done.completed && done.phase == .active && done.ops == 4)
    #expect(Set(queries(rig)).count < queries(rig).count)
  }

  @Test func aScanCancelledWhileParsingItsLastMessageDoesNotFinish() async throws {
    var gate: CancelOnParse?
    let rig = Rig(wrapStore: { base in
      let g = CancelOnParse(base)
      gate = g
      return g
    })
    let store = try #require(gate)
    rig.gmail.add(SyntheticMail.dibCard(id: "d0", dateMs: Rig.t0 - Self.day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    await store.arm()
    let engine = rig.engine

    let cancelled = await Task { await engine.runCycle(trigger: .launch) }.value

    #expect(!cancelled.completed)
    #expect(await rig.accounted("d0") == nil)
    #expect(await rig.state().watermarkMs == nil)

    let next = await rig.engine.runCycle(trigger: .launch)

    #expect(next.completed && next.phase == .active && next.ops == 1)
    #expect(await rig.accounted("d0") == .op)
  }

  @Test func anAuthoringPhaseFoundAfterARestartListsItsWindow() async throws {
    let rig = seeded(count: 3)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    var c = MailboxCommit()
    var s = await rig.state()
    s.phase = .authoringBackfill
    c.state = s
    try await rig.store.commit(c)

    let done = await rig.restarted().runCycle(trigger: .launch)

    #expect(done.completed && done.phase == .active && done.ops == 3)
    #expect(!rig.listRequests.isEmpty)
  }
}
