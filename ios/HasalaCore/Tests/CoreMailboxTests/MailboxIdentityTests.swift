import CoreJSON
import CoreMailbox
import CoreTestSupport
import CoreTime
import Foundation
import Testing

@Suite struct MailboxIdentityTests {
  let day: Int64 = 86_400_000
  let account = "00000000-0000-4000-8000-000000000001"

  @Test func theGrantIDNamesTheMailbox() {
    let c = MailboxEngineConfig(grantID: account)
    let grant = c.grantID(provider: .gmail, address: "Synthetic.User@Example.com")
    #expect(grant.hasPrefix("\(account)/mbx-"))
    #expect(grant.utf8.count == account.utf8.count + 5 + 32)
    #expect(c.grantID(provider: .gmail, address: "  synthetic.user@example.com\n") == grant)
    #expect(c.grantID(provider: .outlook, address: "synthetic.user@example.com") != grant)
    #expect(c.grantID(provider: .gmail, address: "other.user@example.com") != grant)
    let elsewhere = MailboxEngineConfig(grantID: "00000000-0000-4000-8000-000000000002")
      .grantID(provider: .gmail, address: "synthetic.user@example.com")
    #expect(elsewhere.split(separator: "/").last != grant.split(separator: "/").last)
    #expect(c.grantID(provider: .gmail, address: nil) == account)
    #expect(c.grantID(provider: .gmail, address: "") == account)
    #expect(!grant.contains("synthetic"))
  }

  @Test func everyImportCarriesItsMailbox() async throws {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "e1", dateMs: Rig.t0 - 2 * day))
    await rig.connectAndActivate()
    let drafts = await rig.enqueued()
    #expect(Set(drafts.map(\.messageID)) == ["d1", "e1"])
    let grant = MailboxEngineConfig(grantID: account).grantID(provider: .gmail, address: "synthetic.user@example.com")
    for d in drafts {
      #expect(d.payload["provenance"]?["grant_id"] == .string(grant))
      #expect(d.payload["provenance"]?["provider"] == .string("gmail"))
    }
  }

  @Test func aMailboxOnAnotherAccountIsRefusedAndNothingIsKept() async throws {
    let rig = Rig()
    await rig.server.setLinkRefusal(.refused(409, "mailbox_in_use"))
    let r = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(r == .failed(.mailboxInUse))
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.state().phase == .unlinked)
    #expect(await rig.enqueued().isEmpty)
  }

  @Test func anyOtherLinkRefusalStaysServerRefused() async throws {
    let rig = Rig()
    await rig.server.setLinkRefusal(.refused(403, "link_rejected"))
    let r = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(r == .failed(.serverRefused))
  }

  @Test func theReconnectWindowCoversTheGap() {
    let now = Rig.t0
    #expect(MailboxEngine.backfillDays(newestImportMs: nil, nowMs: now) == 90)
    #expect(MailboxEngine.backfillDays(newestImportMs: now - 10 * day, nowMs: now) == 90)
    #expect(MailboxEngine.backfillDays(newestImportMs: now - 88 * day, nowMs: now) == 90)
    #expect(MailboxEngine.backfillDays(newestImportMs: now - 89 * day, nowMs: now) == 365)
    #expect(MailboxEngine.backfillDays(newestImportMs: now - 200 * day, nowMs: now) == 365)
  }

  @Test func aDisconnectAndReconnectOfTheSameMailboxLeavesNoGapAndNoDuplicate() async throws {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    await rig.connectAndActivate()
    #expect(Set(await rig.enqueued().map(\.messageID)) == ["d1"])
    await rig.ledger.setProjected(["d1"])

    #expect(await rig.engine.disconnect())
    #expect(await rig.state().phase == .unlinked)

    rig.clock.advance(120 * day)
    rig.gmail.add(SyntheticMail.dibCard(id: "gap1", dateMs: Rig.t0 + 20 * day))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "new1", dateMs: rig.clock.nowMs() - day))
    let days = MailboxEngine.backfillDays(newestImportMs: Rig.t0 - 5 * day, nowMs: rig.clock.nowMs())
    #expect(days == 365)
    let r = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: days)
    #expect(r == .connected(address: "synthetic.user@example.com"))
    let done = await rig.engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.haltedOn == nil)
    let ids = await rig.enqueued().map(\.messageID)
    #expect(ids.sorted() == ["d1", "gap1", "new1"])
  }
}

@Suite struct MailboxDisconnectChoiceTests {
  let day: Int64 = 86_400_000
  let account = "00000000-0000-4000-8000-000000000001"

  @Test func thePlanNamesThisMailboxAndRemoveAuthorsTheRetireAfterTheDisconnect() async throws {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    await rig.connectAndActivate()
    let grant = MailboxEngineConfig(grantID: account).grantID(provider: .gmail, address: "synthetic.user@example.com")
    await rig.ledger.setPlan(MailboxRetirePlan(grantID: grant, provider: "gmail", legacy: true, total: 7, edited: 2))
    let plan = try #require(await rig.engine.retirePlan())
    #expect(plan == MailboxRetirePlan(grantID: grant, provider: "gmail", legacy: true, total: 7, edited: 2))
    let flushes = await rig.ledger.flushes
    #expect(await rig.engine.disconnect(removing: plan) == .removed(7))
    #expect(await rig.ledger.retired == [plan])
    #expect(await rig.ledger.flushes == flushes + 1)
    #expect(await rig.state().phase == .unlinked)
    #expect(await rig.engine.retirePlan() == nil)
  }

  @Test func keepAuthorsNothing() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    #expect(await rig.engine.disconnect(removing: nil) == .disconnected)
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func aDisconnectThatFailsRemovesNothing() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let plan = try #require(await rig.engine.retirePlan())
    rig.gmail.fail("/revoke", with: [503])
    #expect(await rig.engine.disconnect(removing: plan) == .failed)
    #expect(await rig.ledger.retired.isEmpty)
    #expect(await rig.state().phase == .active)
  }

  @Test func aCancelledStepUpRemovesNothing() async throws {
    let rig = Rig(stepUpFails: true)
    await rig.connectAndActivate()
    let plan = MailboxRetirePlan(grantID: "g", provider: "gmail", legacy: false, total: 1, edited: 0)
    #expect(await rig.engine.disconnect(removing: plan) == .failed)
    #expect(await rig.ledger.retired.isEmpty)
  }
}

@Suite struct AnotherAddressTests {
  let day: Int64 = 86_400_000
  let account = "00000000-0000-4000-8000-000000000001"
  let other = "other.user@example.com"

  func linkedThenSignedOut(_ rig: Rig) async {
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    await rig.connectAndActivate()
    await rig.tokens.invalidate()
    rig.gmail.invalidGrant = true
    _ = await rig.engine.runCycle(trigger: .launch)
    rig.gmail.invalidGrant = false
    rig.clock.advance(day)
  }

  @Test func signingInAgainWithTheSameAddressResumes() async throws {
    let rig = Rig()
    await linkedThenSignedOut(rig)
    let before = await rig.state()
    #expect(before.phase == .reconnectRequired && before.watermarkMs == Rig.t0)
    let r = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    #expect(r == .connected(address: "synthetic.user@example.com"))
    let s = await rig.state()
    #expect(s.phase == .active && s.watermarkMs == Rig.t0 && s.scanStartedMs == before.scanStartedMs)
    #expect(await rig.accounted("d1") == .op)
    #expect(try await !rig.store.bankHealth().isEmpty)
  }

  @Test func theAddressIsComparedWithoutCaseOrBlanks() async throws {
    let rig = Rig()
    await linkedThenSignedOut(rig)
    rig.gmail.email = " Synthetic.User@Example.COM"
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    let s = await rig.state()
    #expect(s.phase == .active && s.watermarkMs == Rig.t0)
    #expect(await rig.accounted("d1") == .op)
  }

  @Test func anotherAddressStartsThatMailboxFreshAsAConfirmedReplaceDoes() async throws {
    let signIn = Rig()
    let replace = Rig()
    for rig in [signIn, replace] {
      await linkedThenSignedOut(rig)
      rig.gmail.remove("d1")
      rig.gmail.email = other
      rig.gmail.add(SyntheticMail.enbdAlert(id: "b-old", dateMs: Rig.t0 - 40 * day))
    }
    let r = await signIn.engine.connect(presenter: FakePresenter(gmail: signIn.gmail), backfillDays: 90)
    #expect(r == .connected(address: other, anotherAddress: true))
    #expect(
      await replace.engine.connect(presenter: FakePresenter(gmail: replace.gmail), backfillDays: 90, replacing: true)
        == .connected(address: other))

    let s = await signIn.state()
    #expect(s.phase == .scanning && s.address == other && s.watermarkMs == nil)
    #expect(s.scanStartedMs == Rig.t0 + day && s.backfillDays == 90 && s.haltedOn == nil && s.haltedDetail == nil)
    #expect(s == (await replace.state()))
    #expect(await signIn.accountedCount() == 0)
    #expect(try await signIn.store.bankHealth().isEmpty)
    #expect(await signIn.server.puts.count == 2)
    #expect(await signIn.server.puts.last?.1["kind"] == .string("mailbox.link"))
    #expect(await signIn.server.deletes == 0)
    #expect(await signIn.ledger.retired.isEmpty)
    #expect(signIn.gmail.requests.map(\.path) == replace.gmail.requests.map(\.path))

    let done = await signIn.engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.ops == 1)
    _ = await replace.engine.runCycle(trigger: .launch)
    let grant = MailboxEngineConfig(grantID: account).grantID(provider: .gmail, address: other)
    let drafts = await signIn.enqueued()
    #expect(drafts.map(\.messageID) == ["d1", "b-old"])
    #expect(drafts.last?.payload["provenance"]?["grant_id"] == .string(grant))
    #expect(drafts == (await replace.enqueued()))
    #expect(await signIn.engine.status().address == other)
  }

  @Test func anotherAddressWithoutAMailboxChangesNothing() async throws {
    let rig = Rig()
    await linkedThenSignedOut(rig)
    let before = await rig.state()
    let puts = await rig.server.puts.count
    rig.gmail.email = other
    rig.gmail.noMailbox = true
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .failed(.noMailbox))
    #expect(await rig.state() == before)
    #expect(await rig.server.puts.count == puts)
    #expect(await rig.accounted("d1") == .op)
    #expect(try await !rig.store.bankHealth().isEmpty)
  }

  @Test func anotherAddressThatCannotBeKeptLeavesNothingToResume() async throws {
    let rig = Rig()
    await linkedThenSignedOut(rig)
    rig.gmail.remove("d1")
    rig.gmail.email = other
    rig.gmail.add(SyntheticMail.enbdAlert(id: "b-new", dateMs: Rig.t0 - 2 * day))
    rig.keychain.locked = true
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .failed(.keychain))
    rig.keychain.locked = false
    let s = await rig.state()
    #expect(s == MailboxState())
    #expect(await rig.accounted("d1") == nil)
    #expect(try rig.keychain.read() == nil)

    let reads = rig.gmail.requests.count
    for trigger in [MailboxTrigger.retry, .launch, .refresh] {
      let report = await rig.engine.runCycle(trigger: trigger)
      #expect(report.phase == .unlinked && report.ops == 0)
    }
    #expect(rig.gmail.requests.count == reads)
    #expect(await rig.state() == s)

    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .connected(address: other))
    let done = await rig.engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.ops == 1)
    let grant = MailboxEngineConfig(grantID: account).grantID(provider: .gmail, address: other)
    let drafts = await rig.enqueued()
    #expect(drafts.map(\.messageID) == ["d1", "b-new"])
    #expect(drafts.last?.payload["provenance"]?["grant_id"] == .string(grant))
  }
}
