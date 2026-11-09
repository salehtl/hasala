import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct QuotaStrikeTests {
  let day: Int64 = 86_400_000
  let limited = Array(repeating: 429, count: 5)

  func limitListing(_ rig: Rig) { rig.gmail.fail("/gmail/v1/users/me/messages", with: [429]) }

  @Test func threeCyclesThatReadNothingSayQuota() async {
    let rig = Rig()
    await rig.connectAndActivate()
    var seen: [MailboxHaltCode?] = []
    for _ in 0..<3 {
      limitListing(rig)
      seen.append(await rig.engine.runCycle(trigger: .refresh).haltedOn)
    }
    #expect(seen == [.gmail, .gmail, .quota])
  }

  @Test func anUnchangedCycleStartsTheCountAgain() async {
    let rig = Rig()
    await rig.connectAndActivate()
    for _ in 0..<2 {
      limitListing(rig)
      #expect(await rig.engine.runCycle(trigger: .refresh).haltedOn == .gmail)
    }
    let unchanged = await rig.engine.runCycle(trigger: .silentPush)
    #expect(unchanged.completed && unchanged.haltedOn == nil && unchanged.listed == 0)
    limitListing(rig)
    #expect(await rig.engine.runCycle(trigger: .refresh).haltedOn == .gmail)
  }

  @Test func aFinishedScanStartsTheCountAgain() async {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    for _ in 0..<2 {
      limitListing(rig)
      #expect(await rig.engine.runCycle(trigger: .refresh).haltedOn == .gmail)
    }
    let scan = await rig.engine.runCycle(trigger: .refresh)
    #expect(scan.phase == .active && scan.completed)
    limitListing(rig)
    #expect(await rig.engine.runCycle(trigger: .refresh).haltedOn == .gmail)
  }

  @Test func aScanCycleCutShortAfterReadingStartsTheCountAgain() async {
    let rig = Rig(config: { $0.downloadWidth = 1 })
    for i in 0..<4 {
      rig.gmail.add(SyntheticMail.dibCard(id: "m\(i)", amount: "\(i + 1).00", dateMs: Rig.t0 - Int64(i + 1) * day))
    }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    for _ in 0..<2 {
      limitListing(rig)
      #expect(await rig.engine.runCycle(trigger: .refresh).haltedOn == .gmail)
    }
    for id in ["m0", "m3"] { rig.gmail.fail("/messages/\(id)", with: [500]) }
    let cut = await rig.engine.runCycle(trigger: .processing, deadlineMs: rig.clock.nowMs() + 5_100)
    #expect(cut.haltedOn == nil && !cut.completed && cut.staged > 0)
    limitListing(rig)
    #expect(await rig.engine.runCycle(trigger: .refresh).haltedOn == .gmail)
  }

  @Test func threeRateLimitedScanCyclesInARowSayQuotaEvenWhenEachReadSome() async {
    let rig = Rig(config: { $0.downloadWidth = 1 })
    for i in 0..<6 {
      rig.gmail.add(SyntheticMail.dibCard(id: "m\(i)", amount: "\(i + 1).00", dateMs: Rig.t0 - Int64(i + 1) * day))
    }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    for id in ["m1", "m3", "m5"] { rig.gmail.fail("/messages/\(id)", with: limited) }
    var seen: [MailboxHaltCode?] = []
    for _ in 0..<3 { seen.append(await rig.engine.runCycle(trigger: .refresh).haltedOn) }
    #expect(seen == [.gmail, .gmail, .quota])
  }
}
