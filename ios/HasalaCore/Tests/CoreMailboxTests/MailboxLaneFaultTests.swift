import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

actor UnreadableStateStore: MailboxPersistence {
  let base: any MailboxPersistence
  var failing = false

  init(_ base: any MailboxPersistence) { self.base = base }

  func setFailing(_ v: Bool) { failing = v }

  func loadState() async throws(MailboxPersistenceError) -> MailboxState {
    if failing { throw MailboxPersistenceError("read") }
    return try await base.loadState()
  }
  func accounted(among ids: [String]) async throws(MailboxPersistenceError) -> Set<String> {
    try await base.accounted(among: ids)
  }
  func staged(limit: Int) async throws(MailboxPersistenceError) -> [ParsedMail] { try await base.staged(limit: limit) }
  func stagedCount() async throws(MailboxPersistenceError) -> Int { try await base.stagedCount() }
  func commit(_ c: MailboxCommit) async throws(MailboxPersistenceError) { try await base.commit(c) }
  func setAsideRecords() async throws(MailboxPersistenceError) -> [SetAsideRecord] { try await base.setAsideRecords() }
  func unreadableRecords() async throws(MailboxPersistenceError) -> [UnreadableRecord] { try await base.unreadableRecords() }
  func bankHealth() async throws(MailboxPersistenceError) -> [BankHealthRow] { try await base.bankHealth() }
  func senderAddresses() async throws(MailboxPersistenceError) -> [String] { try await base.senderAddresses() }
  func addSenderAddress(_ address: String) async throws(MailboxPersistenceError) { try await base.addSenderAddress(address) }
  func isParsing(_ messageID: String) async throws(MailboxPersistenceError) -> Bool { try await base.isParsing(messageID) }
  func markParsing(_ messageID: String) async throws(MailboxPersistenceError) { try await base.markParsing(messageID) }
  func clearParsing(_ messageID: String) async throws(MailboxPersistenceError) { try await base.clearParsing(messageID) }
  func strikes(messageID: String) async throws(MailboxPersistenceError) -> Int { try await base.strikes(messageID: messageID) }
  func pendingImports() async throws(MailboxPersistenceError) -> [PendingImport] { try await base.pendingImports() }
  func unparsedSenders() async throws(MailboxPersistenceError) -> [String: String] { try await base.unparsedSenders() }
  func loadReader() async throws(MailboxPersistenceError) -> MailReaderState? { try await base.loadReader() }
}

@Suite struct MailboxStateReadFaultTests {
  func rig() throws -> (Rig, UnreadableStateStore) {
    var wrapped: UnreadableStateStore?
    let rig = Rig(wrapStore: { base in
      let store = UnreadableStateStore(base)
      wrapped = store
      return store
    })
    return (rig, try #require(wrapped))
  }

  @Test(arguments: [nil, "other.user@example.com"])
  func aConnectThatCannotReadTheLinkChangesNothing(_ signedIn: String?) async throws {
    let (rig, store) = try rig()
    await rig.connectAndActivate()
    let before = await rig.state()
    let links = await rig.server.puts.count
    let proofs = rig.stepUps.kinds.count
    if let signedIn { rig.gmail.email = signedIn }
    let asks = SwitchAsks(.keep)
    await store.setFailing(true)
    let result = await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, confirm: asks.confirm)
    await store.setFailing(false)
    #expect(result == .failed(.keychain))
    #expect(await rig.server.puts.count == links)
    #expect(rig.stepUps.kinds.count == proofs)
    #expect(asks.questions.isEmpty)
    #expect(await rig.state() == before)
  }

  @Test func aStatusThatCannotReadTheStateKeepsTheLastAnswer() async throws {
    let (rig, store) = try rig()
    await rig.connectAndActivate()
    let known = await rig.engine.status()
    #expect(known.phase == .active)
    await store.setFailing(true)
    #expect(await rig.engine.status() == known)
    await store.setFailing(false)
    #expect(await rig.engine.status() == known)
  }

  @Test func aStatusThatHasNeverReadTheStateDoesNotSayNotConnected() async throws {
    let (rig, store) = try rig()
    await store.setFailing(true)
    let s = await rig.engine.status()
    #expect(s.hero == .needsYou && s.phase == .halted && s.haltedOn == .offline)
    #expect(s.stateUnread)
    await store.setFailing(false)
    let real = await rig.engine.status()
    #expect(real.hero == .notConnected && real.phase == .unlinked && real.haltedOn == nil)
    #expect(!real.stateUnread)
  }

  @Test func aStatusThatKeepsTheLastAnswerIsNotMarkedUnread() async throws {
    let (rig, store) = try rig()
    await rig.connectAndActivate()
    #expect(await rig.engine.status().stateUnread == false)
    await store.setFailing(true)
    #expect(await rig.engine.status().stateUnread == false)
  }

  @Test func viewingAnEmailThatCannotReadTheStateIsOfflineNotAnotherIPhone() async throws {
    let (rig, store) = try rig()
    await rig.connectAndActivate()
    await store.setFailing(true)
    #expect(await rig.engine.viewEmail(messageID: "m1") == .offline)
  }

  @Test func probingSendersThatCannotReadTheStateIsOfflineNotNotReading() async throws {
    let (rig, store) = try rig()
    await rig.connectAndActivate()
    await store.setFailing(true)
    #expect(await rig.engine.probeSenders(["dib.ae"]) == .offline)
  }
}
