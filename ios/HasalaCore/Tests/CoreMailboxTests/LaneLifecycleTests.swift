import CoreJSON
import CoreTestSupport
import CoreTime
import Foundation
import Testing

@testable import CoreMailbox

@Suite struct LaneLifecycleTests {
  let day: Int64 = 86_400_000

  @Test func aStoppedEngineRunsNoCycleAndLeavesTheSharedStateAlone() async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.engine.stop()
    var other = MailboxState()
    other.phase = .scanning
    other.address = "someone@example.org"
    var c = MailboxCommit()
    c.clearAll = true
    c.state = other
    try? await rig.store.commit(c)
    rig.gmail.add(SyntheticMail.dibCard(id: "late", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r == CycleReport())
    #expect(await rig.engine.runFirstScan().allSatisfy { $0 == CycleReport() })
    #expect(rig.gmail.requests.isEmpty)
    let s = await rig.state()
    #expect(s.phase == .scanning && s.address == "someone@example.org")
    #expect(await rig.engine.backfill(senders: ["dib.ae"]) == CycleReport())
  }

  @Test func stopWaitsForTheCycleInFlightAndCutsItAtTheNextBoundary() async {
    let rig = Rig()
    rig.gmail.pageSize = 2
    for i in 0..<6 { rig.gmail.add(SyntheticMail.dibCard(id: "s\(i)", dateMs: Rig.t0 - Int64(i + 1) * day)) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    let stopper = Task { await rig.engine.stop() }
    let r = await rig.engine.runCycle(trigger: .refresh, deadlineMs: rig.clock.nowMs() + 600_000)
    await stopper.value
    #expect(await rig.engine.stopped)
    #expect(r.phase == .scanning || r == CycleReport())
    let after = await rig.engine.runCycle(trigger: .refresh)
    #expect(after == CycleReport())
  }

  @Test func connectingAgainResumesAStoppedEngine() async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.engine.stop()
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(await !rig.engine.stopped)
    rig.gmail.add(SyntheticMail.dibCard(id: "after", dateMs: rig.clock.nowMs() - 1000))
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.ops == 1 && r.completed)
  }

  @Test func aLinkMovedToTheOtherProviderStopsThisEngineWithoutWriting() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.state()
    await rig.server.setLinkProvider(.outlook)
    rig.gmail.add(SyntheticMail.dibCard(id: "late", dateMs: rig.clock.nowMs() - 1000))
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.haltedOn == nil && r.ops == 0)
    #expect(await rig.engine.stopped)
    #expect(await rig.state() == before)
  }

  @Test func theHTTPServerRefusesAStatusForAnotherProvidersLink() async throws {
    let http = StaticHTTP(body: #"{"holder":{"is_this_device":true},"provider":"outlook"}"#)
    let server = HTTPMailboxServer(http: http, base: "https://api.example.test")
    await #expect(throws: MailboxServerError.otherProvider) { try await server.linkStatus(provider: .gmail) }
    #expect(try await server.linkStatus(provider: .outlook) == .holder(isThisDevice: true, watchExpiresAtMs: nil))
    let legacy = HTTPMailboxServer(http: StaticHTTP(body: #"{"holder":{"is_this_device":true}}"#), base: "https://api.example.test")
    #expect(try await legacy.linkStatus(provider: .gmail) == .holder(isThisDevice: true, watchExpiresAtMs: nil))
  }

  @Test func aMessageRefusedWith400IsUnreadableAfterBoundedRetries() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "odd", dateMs: rig.clock.nowMs() - 2000))
    rig.gmail.add(SyntheticMail.dibCard(id: "fine", amount: "2.00", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/odd", with: [400, 400, 400])
    let r1 = await rig.engine.runCycle(trigger: .refresh)
    #expect(r1.haltedOn == .gmail && r1.phase == .halted)
    let r2 = await rig.engine.runCycle(trigger: .retry)
    #expect(r2.haltedOn == .gmail && r2.phase == .halted)
    let r3 = await rig.engine.runCycle(trigger: .retry)
    #expect(r1.ops + r2.ops + r3.ops == 1)
    #expect(r3.phase == .active && r3.completed && r3.unreadable == 1)
    #expect(await rig.accounted("odd") == .unreadable)
    #expect(await rig.unreadableReasons() == [.refused])
  }

  @Test func aMessageRefusedWith403IsUnreadableAfterBoundedRetries() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "nope", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/nope", with: [403, 403, 403], reason: "forbidden")
    #expect(await rig.engine.runCycle(trigger: .refresh).phase == .reconnectRequired)
    #expect(await rig.engine.runCycle(trigger: .retry).phase == .reconnectRequired)
    let r = await rig.engine.runCycle(trigger: .retry)
    #expect(r.phase == .active && r.completed && r.unreadable == 1)
    #expect(await rig.unreadableReasons() == [.refused])
  }

  @Test func aSuccessWithoutTheMessageIsRetriedNotGone() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.state().watermarkMs
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "empty", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/empty?format=raw", with: Array(repeating: 200, count: 9))
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .gmail && r.phase == .active && !r.completed)
    #expect(await rig.accounted("empty") == nil)
    #expect(await rig.state().watermarkMs == before)
    _ = await rig.engine.runCycle(trigger: .refresh)
    let r3 = await rig.engine.runCycle(trigger: .refresh)
    #expect(r3.completed && r3.unreadable == 1)
    #expect(await rig.unreadableReasons() == [.undecodable])
  }

  @Test func aSuccessWithoutTheMessageRecoversWhenTheNextAnswerHasIt() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "blip", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/blip?format=raw", with: [200, 200])
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.completed && r.unreadable == 0)
  }

  @Test func aRateLimitKeepsTheWidthNarrowForTheRestOfTheRun() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "w1", dateMs: rig.clock.nowMs() - 1000))
    let token = try await rig.tokens.accessToken(forceRefresh: false)
    let source = await rig.engine.source(token)
    var run = MailboxEngine.Run(trusted: ["dib.ae"], cards: [:], grant: "g")
    run.saw429 = true
    run.width = 1
    var report = CycleReport()
    _ = try await rig.engine.process(source, ids: ["w1"], mode: .author, run: &run, report: &report, deadlineMs: nil)
    #expect(run.width == 1)
    var fresh = MailboxEngine.Run(trusted: ["dib.ae"], cards: [:], grant: "g")
    fresh.width = 1
    _ = try await rig.engine.process(source, ids: ["w1"], mode: .author, run: &fresh, report: &report, deadlineMs: nil)
    #expect(fresh.width > 1)
  }

  @Test func aBankTrustedAfterSetupIsBackfilledOverTheConnectWindow() async {
    let rig = Rig()
    await rig.ledger.setTrust(["dib.ae": true])
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.enbdAlert(id: "old", dateMs: rig.clock.nowMs() - 20 * day))
    await rig.ledger.setTrust(["dib.ae": true, "emiratesnbd.com": true])
    let cycle = await rig.engine.runCycle(trigger: .refresh)
    #expect(cycle.ops == 0)
    let before = await rig.state().watermarkMs
    let r = await rig.engine.backfill(senders: ["emiratesnbd.com"])
    #expect(r.ops == 1 && r.completed)
    #expect(await rig.accounted("old") == .op)
    #expect(await rig.state().watermarkMs == before)
    #expect(await rig.engine.backfill(senders: ["emiratesnbd.com"]).ops == 0)
  }

  @Test func anotherAddressOnTheSameProviderEndsTheOldGrantFirst() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let oldToken = try rig.keychain.read()
    rig.gmail.clearRequests()
    rig.gmail.email = "other.user@example.com"
    let r = await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, confirm: SwitchAsks(.keep).confirm)
    #expect(r == .connected(address: "other.user@example.com", anotherAddress: true))
    let paths = rig.gmail.requests.map(\.path)
    let stop = paths.firstIndex { $0.hasSuffix("/stop") }
    let revoke = paths.firstIndex { $0.contains("revoke") }
    #expect(stop != nil && revoke != nil)
    let revoked = rig.gmail.requests.first { $0.path.contains("revoke") }
    #expect(revoked?.form.contains { $0.0 == "token" && $0.1 == oldToken } == true)
    #expect(stop! < revoke!)
  }

  @Test func theSameAddressAgainRevokesNothing() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.clearRequests()
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(!rig.gmail.requests.contains { $0.path.contains("revoke") || $0.path.hasSuffix("/stop") })
  }

  @Test(arguments: [Backend.sqlite, .memory]) func unreadableMailIsKeptPastFifty(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    var c = MailboxCommit()
    for i in 0..<120 {
      c.unreadable.append(UnreadableRecord(messageID: "u\(i)", reason: .gone, domain: nil, internalDateMs: nil, atMs: Rig.t0 + Int64(i)))
    }
    try await rig.store.commit(c)
    #expect(await rig.engine.status().unreadable == 120)
  }

  @Test func anUnknownSignedInIdentityIsRefusedNotTreatedAsASwitch() {
    #expect(!MailboxEngine.isAnotherMailbox(linked: "a@example.com", signedIn: nil))
    #expect(!MailboxEngine.isAnotherMailbox(linked: "a@example.com", signedIn: " "))
    #expect(MailboxEngine.identityUnknown(linked: "a@example.com", signedIn: nil))
    #expect(MailboxEngine.identityUnknown(linked: "a@example.com", signedIn: " "))
    #expect(!MailboxEngine.identityUnknown(linked: nil, signedIn: nil))
    #expect(!MailboxEngine.identityUnknown(linked: "a@example.com", signedIn: "a@example.com"))
    #expect(!MailboxEngine.isAnotherMailbox(linked: nil, signedIn: "a@example.com"))
    #expect(!MailboxEngine.isAnotherMailbox(linked: "A@example.com", signedIn: "a@example.com"))
    #expect(MailboxEngine.isAnotherMailbox(linked: "a@example.com", signedIn: "b@example.com"))
  }
}

struct StaticHTTP: HTTPExchange {
  let body: String
  func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    HTTPResponse(status: 200, body: Data(body.utf8))
  }
}
