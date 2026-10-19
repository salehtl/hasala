import CoreJSON
import CoreMailbox
import CoreTestSupport
import CoreTime
import Foundation
import Testing

final class SwitchAsks: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [MailboxSwitchQuestion] = []
  private let answer: MailboxSwitchChoice
  private let look: (@Sendable () async -> Void)?

  init(_ answer: MailboxSwitchChoice, look: (@Sendable () async -> Void)? = nil) {
    self.answer = answer
    self.look = look
  }

  var questions: [MailboxSwitchQuestion] { lock.withLock { seen } }

  var confirm: MailboxSwitchConfirm {
    { [self] q in
      lock.withLock { seen.append(q) }
      await look?()
      return answer
    }
  }
}

final class Snapshot<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T?
  func set(_ v: T) { lock.withLock { value = v } }
  var get: T? { lock.withLock { value } }
}

@Suite struct GmailAddressSwitchTests {
  let day: Int64 = 86_400_000
  let account = "00000000-0000-4000-8000-000000000001"
  let old = "synthetic.user@example.com"
  let other = "other.user@example.com"

  var oldGrant: String { MailboxEngineConfig(grantID: account).grantID(provider: .gmail, address: old) }

  func signedOutWithImports(_ rig: Rig, total: Int = 3, edited: Int = 1) async {
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    await rig.connectAndActivate()
    await rig.ledger.setPlan(MailboxRetirePlan(grantID: oldGrant, provider: "gmail", legacy: true, total: total, edited: edited))
    await rig.tokens.invalidate()
    rig.gmail.invalidGrant = true
    _ = await rig.engine.runCycle(trigger: .launch)
    rig.gmail.invalidGrant = false
    rig.clock.advance(day)
    rig.gmail.remove("d1")
    rig.gmail.email = other
    rig.gmail.add(SyntheticMail.enbdAlert(id: "b1", dateMs: Rig.t0 - 2 * day))
  }

  func connect(_ rig: Rig, _ asks: SwitchAsks) async -> ConnectResult {
    await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, confirm: asks.confirm)
  }

  struct Seen: Sendable, Equatable {
    var state: MailboxState
    var puts: Int
    var stepUps: [String]
    var token: String?
    var retired: Int
    var revokes: Int
  }

  func seen(_ rig: Rig) async -> Seen {
    Seen(
      state: await rig.state(), puts: await rig.server.puts.count, stepUps: rig.stepUps.kinds,
      token: try? rig.keychain.read(), retired: await rig.ledger.retired.count,
      revokes: rig.gmail.requests.filter { $0.path.contains("revoke") }.count)
  }

  @Test func anotherAddressAsksBeforeAnyStepUpLinkKeychainOrCommit() async throws {
    let rig = Rig()
    await signedOutWithImports(rig)
    let before = await seen(rig)
    #expect(before.state.phase == .reconnectRequired && before.state.address == old)
    let during = Snapshot<Seen>()
    let asks = SwitchAsks(.cancel) { during.set(await seen(rig)) }
    #expect(await connect(rig, asks) == .declined)
    #expect(during.get == before)
    #expect(asks.questions == [
      MailboxSwitchQuestion(oldAddress: old, newAddress: other, transactions: 3, edited: 1, oldHasNoMailbox: false)
    ])
  }

  @Test func tryAgainChangesNothingAndTheLaneStaysOnTheOldMailbox() async throws {
    let rig = Rig()
    await signedOutWithImports(rig)
    let before = await seen(rig)
    #expect(await connect(rig, SwitchAsks(.cancel)) == .declined)
    #expect(await seen(rig) == before)
    #expect(await rig.accounted("d1") == .op)
    #expect(try await !rig.store.bankHealth().isEmpty)
    #expect(await rig.engine.status().address == old)
    #expect(await rig.ledger.retired.isEmpty)

    #expect(await connect(rig, SwitchAsks(.keep)) == .connected(address: other, anotherAddress: true))
    #expect(await rig.state().address == other)
  }

  @Test func keepSwitchesAndRetiresNothing() async throws {
    let rig = Rig()
    await signedOutWithImports(rig)
    let flushes = await rig.ledger.flushes
    #expect(await connect(rig, SwitchAsks(.keep)) == .connected(address: other, anotherAddress: true, retired: nil))
    let s = await rig.state()
    #expect(s.phase == .scanning && s.address == other && s.watermarkMs == nil)
    #expect(await rig.ledger.retired.isEmpty)
    #expect(await rig.ledger.flushes == flushes)
    #expect(await rig.server.puts.count == 2)
  }

  @Test func removeSwitchesThenRetiresTheOldMailboxAsDisconnectWould() async throws {
    let rig = Rig()
    await signedOutWithImports(rig, total: 7, edited: 2)
    let disconnectPlan = try #require(await rig.engine.retirePlan())
    #expect(disconnectPlan.grantID == oldGrant)
    let flushes = await rig.ledger.flushes
    #expect(await connect(rig, SwitchAsks(.remove)) == .connected(address: other, anotherAddress: true, retired: .removed(7)))
    #expect(await rig.ledger.retired == [disconnectPlan])
    #expect(await rig.ledger.flushes == flushes + 1)
    let s = await rig.state()
    #expect(s.phase == .scanning && s.address == other)
    let done = await rig.engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.ops == 1)
    let newGrant = MailboxEngineConfig(grantID: account).grantID(provider: .gmail, address: other)
    #expect(await rig.enqueued().last?.payload["provenance"]?["grant_id"] == .string(newGrant))
    #expect(await rig.ledger.retired.count == 1)
  }

  @Test func removeWithNothingImportedRetiresNothing() async throws {
    let rig = Rig()
    await signedOutWithImports(rig, total: 0, edited: 0)
    let asks = SwitchAsks(.remove)
    #expect(await connect(rig, asks) == .connected(address: other, anotherAddress: true, retired: nil))
    #expect(asks.questions.first?.transactions == 0)
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func aSwitchThatFailsRetiresNothing() async throws {
    let locked = Rig()
    await signedOutWithImports(locked)
    locked.keychain.locked = true
    #expect(await connect(locked, SwitchAsks(.remove)) == .failed(.keychain))
    locked.keychain.locked = false
    #expect(await locked.ledger.retired.isEmpty)

    let refused = Rig()
    await signedOutWithImports(refused)
    await refused.server.setLinkRefusal(.refused(409, "mailbox_in_use"))
    #expect(await connect(refused, SwitchAsks(.remove)) == .failed(.mailboxInUse))
    #expect(await refused.ledger.retired.isEmpty)
    #expect(await refused.state().address == old)
  }

  @Test func aStepUpThatFailsAfterTheAnswerRetiresNothing() async throws {
    let rig = Rig(stepUpFails: true)
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    var c = MailboxCommit()
    var s = MailboxState()
    s.phase = .reconnectRequired
    s.address = old
    s.watermarkMs = Rig.t0
    c.state = s
    try await rig.store.commit(c)
    await rig.ledger.setPlan(MailboxRetirePlan(grantID: oldGrant, provider: "gmail", legacy: true, total: 4, edited: 0))
    rig.gmail.email = other
    let asks = SwitchAsks(.remove)
    #expect(await connect(rig, asks) == .failed(.stepUpFailed))
    #expect(asks.questions.count == 1)
    #expect(await rig.ledger.retired.isEmpty)
    #expect(await rig.state() == s)
  }

  @Test func aRetireThatFailsLeavesTheNewMailboxConnectedAndSaysSo() async throws {
    let rig = Rig()
    await signedOutWithImports(rig)
    await rig.ledger.setRetireFails(true)
    #expect(await connect(rig, SwitchAsks(.remove)) == .connected(address: other, anotherAddress: true, retired: .failed))
    let s = await rig.state()
    #expect(s.phase == .scanning && s.address == other)
    #expect(try rig.keychain.read() != nil)
    #expect(await rig.ledger.retired.isEmpty)
    let done = await rig.engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.ops == 1)
  }

  @Test func theSameAddressAsksNothing() async throws {
    let rig = Rig()
    await signedOutWithImports(rig)
    rig.gmail.email = " Synthetic.User@Example.COM"
    let asks = SwitchAsks(.cancel)
    let r = await connect(rig, asks)
    #expect(r == .connected(address: " Synthetic.User@Example.COM"))
    #expect(asks.questions.isEmpty)
    let s = await rig.state()
    #expect(s.phase == .active && s.watermarkMs == Rig.t0)
  }

  @Test func withoutAnAnswerAnotherAddressNeverSwitches() async throws {
    let rig = Rig()
    await signedOutWithImports(rig)
    let before = await seen(rig)
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .declined)
    #expect(await seen(rig) == before)
  }

  func haltedOnNoMailbox(_ rig: Rig, total: Int) async throws {
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    await rig.connectAndActivate()
    var s = await rig.state()
    s.phase = .halted
    s.haltedOn = .noMailbox
    var c = MailboxCommit()
    c.state = s
    try await rig.store.commit(c)
    await rig.ledger.setPlan(MailboxRetirePlan(grantID: oldGrant, provider: "gmail", legacy: true, total: total, edited: 0))
    rig.gmail.email = other
  }

  @Test func aLaneWithNoMailboxAndNothingImportedSwitchesWithoutAsking() async throws {
    let rig = Rig()
    try await haltedOnNoMailbox(rig, total: 0)
    let asks = SwitchAsks(.cancel)
    #expect(await connect(rig, asks) == .connected(address: other, anotherAddress: true))
    #expect(asks.questions.isEmpty)
    #expect(await rig.state().address == other)
  }

  @Test func aLaneWithNoMailboxThatImportedAsksKeepOrRemove() async throws {
    let rig = Rig()
    try await haltedOnNoMailbox(rig, total: 5)
    let asks = SwitchAsks(.remove)
    #expect(await connect(rig, asks) == .connected(address: other, anotherAddress: true, retired: .removed(5)))
    #expect(asks.questions == [
      MailboxSwitchQuestion(oldAddress: old, newAddress: other, transactions: 5, edited: 0, oldHasNoMailbox: true)
    ])
    #expect(await rig.ledger.retired.map(\.grantID) == [oldGrant])
  }

  @Test func aProviderSwitchAsksNothingHere() async throws {
    let rig = Rig()
    await signedOutWithImports(rig)
    let asks = SwitchAsks(.cancel)
    _ = await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, replacing: true, confirm: asks.confirm)
    #expect(asks.questions.isEmpty)
    #expect(await rig.ledger.retired.isEmpty)
  }
}

@Suite struct OutlookAddressSwitchTests {
  let day: Int64 = 86_400_000
  let account = "00000000-0000-4000-8000-000000000001"
  let old = "synthetic.user@outlook.example"
  let other = "other.user@outlook.example"

  var oldGrant: String { MailboxEngineConfig(grantID: account).grantID(provider: .outlook, address: old) }

  func linkedThenHalted(_ rig: OutlookRig, total: Int) async {
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: OutlookRig.t0 - 5 * day))
    await rig.connectAndActivate()
    await rig.ledger.setPlan(MailboxRetirePlan(grantID: oldGrant, provider: "outlook", legacy: true, total: total, edited: 0))
    rig.graph.noMailbox = true
    _ = await rig.engine.runCycle(trigger: .refresh)
    rig.graph.noMailbox = false
    rig.clock.advance(day)
    rig.graph.remove("AAkALgAA-d1")
    rig.graph.email = other
    rig.graph.add(SyntheticOutlookMail.enbdAlert(id: "AAkALgAA-b1", dateMs: OutlookRig.t0 - 2 * day))
  }

  func signedOut(_ rig: OutlookRig, total: Int) async throws {
    await linkedThenHalted(rig, total: total)
    var s = await rig.state()
    s.phase = .reconnectRequired
    s.haltedOn = .reconnectRequired
    var c = MailboxCommit()
    c.state = s
    try await rig.store.commit(c)
  }

  struct Seen: Sendable, Equatable {
    var state: MailboxState
    var linked: [MailProviderID]
    var stepUps: [String]
    var token: String?
    var link: OutlookLinkState?
    var deletes: Int
    var retired: Int
  }

  func seen(_ rig: OutlookRig) async -> Seen {
    Seen(
      state: await rig.state(), linked: await rig.server.linkedProviders, stepUps: rig.stepUps.kinds,
      token: try? rig.keychain.read(), link: (try? rig.link.read()) ?? nil,
      deletes: rig.subscriptionRequests("DELETE").count, retired: await rig.ledger.retired.count)
  }

  @Test func anotherAddressAsksBeforeAnythingAndTryAgainChangesNothing() async throws {
    let rig = OutlookRig()
    try await signedOut(rig, total: 2)
    let before = await seen(rig)
    #expect(before.state.address == old && before.state.phase == .reconnectRequired)
    let during = Snapshot<Seen>()
    let asks = SwitchAsks(.cancel) { during.set(await seen(rig)) }
    #expect(await rig.connect(confirm: asks.confirm) == .declined)
    #expect(during.get == before)
    #expect(await seen(rig) == before)
    #expect(asks.questions == [
      MailboxSwitchQuestion(oldAddress: old, newAddress: other, transactions: 2, edited: 0, oldHasNoMailbox: false)
    ])
    #expect(rig.accounted("AAkALgAA-d1") == .op)
  }

  @Test func keepSwitchesEndsTheOldSubscriptionAndRetiresNothing() async throws {
    let rig = OutlookRig()
    try await signedOut(rig, total: 2)
    let sub = try #require(rig.graph.subscriptions.first?.id)
    #expect(await rig.connect(confirm: SwitchAsks(.keep).confirm) == .connected(address: other, anotherAddress: true))
    #expect(rig.subscriptionRequests("DELETE").map(\.path) == ["/v1.0/subscriptions/\(sub)"])
    #expect(await rig.state().address == other)
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func removeRetiresTheOldOutlookMailboxAfterTheSwitch() async throws {
    let rig = OutlookRig()
    try await signedOut(rig, total: 2)
    let disconnectPlan = try #require(await rig.engine.retirePlan())
    #expect(
      await rig.connect(confirm: SwitchAsks(.remove).confirm)
        == .connected(address: other, anotherAddress: true, retired: .removed(2)))
    #expect(await rig.ledger.retired == [disconnectPlan])
    #expect(disconnectPlan.grantID == oldGrant && disconnectPlan.provider == "outlook")
  }

  @Test func aRetireThatFailsKeepsTheNewOutlookMailbox() async throws {
    let rig = OutlookRig()
    try await signedOut(rig, total: 2)
    await rig.ledger.setRetireFails(true)
    #expect(
      await rig.connect(confirm: SwitchAsks(.remove).confirm)
        == .connected(address: other, anotherAddress: true, retired: .failed))
    #expect(await rig.state().address == other)
    #expect(try rig.link.read() == OutlookLinkState(clientState: OutlookServer.clientState))
  }

  @Test func aSwitchWhoseLinkCannotBeKeptRetiresNothing() async throws {
    let rig = OutlookRig()
    try await signedOut(rig, total: 2)
    rig.link.locked = true
    #expect(await rig.connect(confirm: SwitchAsks(.remove).confirm) == .failed(.keychain))
    rig.link.locked = false
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func noMailboxAndNothingImportedSwitchesWithoutAsking() async throws {
    let rig = OutlookRig()
    await linkedThenHalted(rig, total: 0)
    let asks = SwitchAsks(.cancel)
    #expect(await rig.connect(confirm: asks.confirm) == .connected(address: other, anotherAddress: true))
    #expect(asks.questions.isEmpty)
  }

  @Test func noMailboxWithImportsAsksKeepOrRemove() async throws {
    let rig = OutlookRig()
    await linkedThenHalted(rig, total: 3)
    let before = await seen(rig)
    let asks = SwitchAsks(.cancel)
    #expect(await rig.connect(confirm: asks.confirm) == .declined)
    #expect(asks.questions.first?.oldHasNoMailbox == true && asks.questions.first?.transactions == 3)
    #expect(await seen(rig) == before)
    #expect(await rig.connect(confirm: SwitchAsks(.keep).confirm) == .connected(address: other, anotherAddress: true))
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func theSameAddressAsksNothing() async throws {
    let rig = OutlookRig()
    try await signedOut(rig, total: 2)
    rig.graph.email = "Synthetic.User@Outlook.Example"
    let asks = SwitchAsks(.cancel)
    #expect(await rig.connect(confirm: asks.confirm) == .connected(address: "Synthetic.User@Outlook.Example"))
    #expect(asks.questions.isEmpty)
    #expect(await rig.state().watermarkMs == OutlookRig.t0)
  }
}
