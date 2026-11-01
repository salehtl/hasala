import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

extension FakeLedger {
  func setPlan(grantID: String, provider: String, total: Int) {
    plans[grantID] = MailboxRetirePlan(grantID: grantID, provider: provider, legacy: false, total: total, edited: 0)
  }
}

@Suite struct PastMailChoiceTests {
  static let day: Int64 = 86_400_000
  let t0 = Rig.t0

  func skip(_ rig: Rig, catchUp: Int64? = nil) async -> ConnectResult {
    await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, pastMail: .skip(catchUpFromMs: catchUp))
  }

  func seedPast(_ rig: Rig) {
    rig.gmail.add(SyntheticMail.dibCard(id: "old", dateMs: t0 - 20 * Self.day))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "yesterday", dateMs: t0 - Self.day))
  }

  @Test func theDefaultStillScansTheWindow() async {
    let rig = Rig()
    seedPast(rig)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let s = await rig.state()
    #expect(s.phase == .scanning && s.readFromMs == nil && s.backfillDays == 90)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .active && r.ops == 2)
  }

  @Test func onlyNewMailReadsNothingFromBeforeTheConnect() async {
    let rig = Rig()
    seedPast(rig)
    #expect(await skip(rig) == .connected(address: rig.gmail.email))
    let s = await rig.state()
    #expect(s.phase == .active && s.watermarkMs == t0 && s.readFromMs == t0 && s.backfillDays == 90)
    #expect(s.scanStartedMs == nil)
    let first = await rig.engine.runCycle(trigger: .launch)
    #expect(first.ops == 0 && first.completed)
    #expect(await rig.accounted("yesterday") == nil)
    #expect(await rig.accounted("old") == nil)
    #expect(rig.rawRequests.isEmpty)

    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "new", amount: "9.00", dateMs: t0 + 60_000))
    let next = await rig.engine.runCycle(trigger: .refresh)
    #expect(next.ops == 1)
    #expect(await rig.accounted("new") == .op)
    #expect(await rig.accounted("yesterday") == nil)
  }

  @Test func theListingNeverGoesBehindTheFloorEvenAfterTheWatermarkOverlap() async {
    let rig = Rig()
    _ = await skip(rig)
    _ = await rig.engine.runCycle(trigger: .launch)
    let query = rig.listRequests.last?.query.first { $0.0 == "q" }?.1 ?? ""
    #expect(query.contains("after:\(t0 / 1000)"))
  }

  @Test func theChoiceSurvivesTheStoreAndTheStatusReportsIt() async {
    for backend in [Backend.sqlite, .memory] {
      let rig = Rig(backend: backend)
      _ = await skip(rig)
      #expect(await rig.state().readFromMs == t0)
      #expect(await rig.engine.status().readFromMs == t0)
    }
  }

  @Test func aSkippedAccountCanImportThePastLater() async {
    let rig = Rig()
    seedPast(rig)
    rig.gmail.add(SyntheticMail.dibCard(id: "tooOld", amount: "5.00", dateMs: t0 - 120 * Self.day))
    _ = await skip(rig)
    _ = await rig.engine.runCycle(trigger: .launch)
    rig.clock.advance(5 * Self.day)
    let before = await rig.state().watermarkMs

    let r = await rig.engine.importPastMail()
    #expect(r.ops == 2 && r.completed)
    #expect(await rig.accounted("old") == .op)
    #expect(await rig.accounted("yesterday") == .op)
    #expect(await rig.accounted("tooOld") == nil)
    let s = await rig.state()
    #expect(s.readFromMs == nil && s.phase == .active && s.watermarkMs == before)
    #expect(await rig.engine.importPastMail() == {
      var quiet = CycleReport()
      quiet.phase = .active
      return quiet
    }())
  }

  @Test func aLaterImportThatStopsFinishesOnALaterCycle() async throws {
    let rig = Rig()
    seedPast(rig)
    _ = await skip(rig)
    _ = await rig.engine.runCycle(trigger: .launch)
    await rig.ledger.setSyncFails(true)
    let cut = await rig.engine.importPastMail()
    #expect(cut.haltedOn == .offline && cut.ops == 0)
    #expect(await rig.state().readFromMs == nil)
    #expect(try await rig.store.pendingImports().count > 0)

    await rig.ledger.setSyncFails(false)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(await rig.accounted("old") == .op)
    #expect(try await rig.store.pendingImports().isEmpty)
  }

  @Test func nothingImportsWithoutATrustedSenderAndTheOfferStays() async {
    let rig = Rig()
    _ = await skip(rig)
    await rig.ledger.setTrust(["dib.ae": false, "emiratesnbd.com": false])
    _ = await rig.engine.importPastMail()
    #expect(await rig.state().readFromMs == t0)
  }

  @Test func anImportOnlyRunsFromTheActivePhase() async {
    let rig = Rig()
    seedPast(rig)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(await rig.engine.importPastMail().ops == 0)
    #expect(await rig.state().phase == .scanning)
  }

  @Test func aNewBankOnASkippedAccountStartsAtTheFloorUntilThePastIsImported() async {
    let rig = Rig()
    await rig.ledger.setTrust(["dib.ae": true])
    rig.gmail.add(SyntheticMail.enbdAlert(id: "enbdOld", dateMs: t0 - 20 * Self.day))
    _ = await skip(rig)
    _ = await rig.engine.runCycle(trigger: .launch)
    rig.clock.advance(Self.day)
    rig.gmail.add(SyntheticMail.enbdAlert(id: "enbdNew", amount: "3.00", dateMs: t0 + 60_000))
    await rig.ledger.setTrust(["dib.ae": true, "emiratesnbd.com": true])

    let added = await rig.engine.backfill(senders: ["emiratesnbd.com"])
    #expect(added.ops == 1 && added.completed)
    #expect(await rig.accounted("enbdNew") == .op)
    #expect(await rig.accounted("enbdOld") == nil)

    let imported = await rig.engine.importPastMail()
    #expect(imported.ops == 1)
    #expect(await rig.accounted("enbdOld") == .op)
  }

  @Test func aReconnectKeepsTheChoiceAndCatchesUpFromTheWatermark() async {
    let rig = Rig()
    seedPast(rig)
    _ = await skip(rig)
    _ = await rig.engine.runCycle(trigger: .launch)
    rig.clock.advance(Self.day)
    let gap = t0 + 3_600_000
    rig.gmail.add(SyntheticMail.dibCard(id: "gap", amount: "7.00", dateMs: gap))
    await rig.tokens.invalidate()
    rig.gmail.invalidGrant = true
    #expect(await rig.engine.runCycle(trigger: .refresh).phase == .reconnectRequired)
    rig.gmail.invalidGrant = false
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let s = await rig.state()
    #expect(s.phase == .active && s.readFromMs == t0)
    let r = await rig.engine.runCycle(trigger: .retry)
    #expect(r.ops == 1)
    #expect(await rig.accounted("gap") == .op)
    #expect(await rig.accounted("yesterday") == nil)
  }

  @Test func aDisconnectForgetsTheChoice() async {
    let rig = Rig()
    _ = await skip(rig)
    #expect(await rig.engine.disconnect())
    let s = await rig.state()
    #expect(s.phase == .unlinked && s.readFromMs == nil)
    seedPast(rig)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(await rig.state().phase == .scanning)
  }

  @Test func anotherAddressOnSignInAgainKeepsTheSkip() async {
    let rig = Rig()
    _ = await skip(rig)
    rig.clock.advance(Self.day)
    rig.gmail.email = "other.synthetic@gmail.example"
    let r = await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, confirm: { _ in .keep })
    #expect(r == .connected(address: "other.synthetic@gmail.example", anotherAddress: true))
    let s = await rig.state()
    #expect(s.phase == .active && s.readFromMs == t0 + Self.day && s.watermarkMs == t0 + Self.day)
  }

  @Test func anotherAddressOnSignInAgainStillScansWhenThePastWasRead() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.email = "other.synthetic@gmail.example"
    _ = await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, confirm: { _ in .keep })
    let s = await rig.state()
    #expect(s.phase == .scanning && s.readFromMs == nil)
  }

  @Test func aTakeoverOfAMailboxWithRowsPicksUpWhereTheOtherIPhoneStopped() async {
    let rig = Rig()
    let grant = await rig.engine.config.grantID(provider: .gmail, address: rig.gmail.email)
    await rig.ledger.setPlan(grantID: grant, provider: "gmail", total: 3)
    let newest = t0 - 10 * Self.day
    rig.gmail.add(SyntheticMail.dibCard(id: "beforeOverlap", dateMs: newest - 3 * Self.day))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "missed", dateMs: newest + Self.day))
    _ = await skip(rig, catchUp: newest)
    let s = await rig.state()
    let from = newest - BankDomains.overlapMs
    #expect(s.phase == .active && s.readFromMs == from && s.watermarkMs == from)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.ops == 1)
    #expect(await rig.enqueued().map(\.messageID) == ["missed"])
  }

  @Test func aTakeoverOfAMailboxWithNoRowsStartsNow() async {
    let rig = Rig()
    _ = await skip(rig, catchUp: t0 - 10 * Self.day)
    #expect(await rig.state().readFromMs == t0)
  }

  @Test func anExistingLinkWithNoChoiceIsUntouched() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let s = await rig.state()
    #expect(s.readFromMs == nil)
    #expect(await rig.engine.importPastMail().ops == 0)
    let after = await rig.state()
    #expect(after.watermarkMs == s.watermarkMs)
  }
}

@Suite struct OutlookPastMailChoiceTests {
  static let day: Int64 = 86_400_000
  let t0 = OutlookRig.t0

  func seed(_ rig: OutlookRig) {
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-old", dateMs: t0 - 20 * Self.day))
    rig.graph.add(SyntheticOutlookMail.enbdAlert(id: "AAkALgAA-yday", dateMs: t0 - Self.day))
  }

  func skip(_ rig: OutlookRig) async {
    _ = await rig.engine.connect(
      presenter: OutlookPresenter(graph: rig.graph), backfillDays: 90, pastMail: .skip(catchUpFromMs: nil))
  }

  @Test func onlyNewMailAndTheLaterImportWorkOnOutlook() async {
    let rig = OutlookRig()
    seed(rig)
    await skip(rig)
    #expect(await rig.state().phase == .active)
    #expect(await rig.state().readFromMs == t0)
    let first = await rig.engine.runCycle(trigger: .launch)
    #expect(first.ops == 0)
    #expect(rig.accounted("AAkALgAA-yday") == nil)

    rig.clock.advance(3_600_000)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-new", amount: "9.00", dateMs: t0 + 60_000))
    #expect(await rig.engine.runCycle(trigger: .refresh).ops == 1)
    #expect(rig.accounted("AAkALgAA-new") == .op)

    let imported = await rig.engine.importPastMail()
    #expect(imported.ops == 2 && imported.completed)
    #expect(rig.accounted("AAkALgAA-old") == .op)
    #expect(rig.accounted("AAkALgAA-yday") == .op)
    #expect(await rig.state().readFromMs == nil)
  }

  @Test func theDefaultStillScansOnOutlook() async {
    let rig = OutlookRig()
    seed(rig)
    _ = await rig.connect()
    #expect(await rig.state().phase == .scanning)
    #expect(await rig.engine.runCycle(trigger: .launch).ops == 2)
  }
}
