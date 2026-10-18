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
