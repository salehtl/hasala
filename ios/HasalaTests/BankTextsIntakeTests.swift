import CoreMailbox
import CorePrimitives
import CoreStore
import CoreSync
import Foundation
import HasalaKeychain
import HasalaModels
import Security
import Synchronization
import Testing

@testable import Hasala

nonisolated final class FakeTextReader: BankTextsReading {
  private let table: [String: BankTextRead]
  private let windows = Mutex<[Bool]>([])

  init(_ table: [String: BankTextRead]) {
    self.table = table
  }

  var windowsSeen: [Bool] { windows.withLock { $0 } }

  func read(_ text: String, sender: String?, testWindowOpen: Bool) -> BankTextRead {
    windows.withLock { $0.append(testWindowOpen) }
    if testWindowOpen, BankTextsTestPhrase.matches(text) { return .setUpTest }
    return table[text] ?? .drop(.noPaymentShape, setAsideSender: nil, bank: nil)
  }
}

nonisolated final class FakeTextAuthor: BankTextsAuthoring {
  struct Call: Equatable, Sendable {
    var text: String
    var sender: String?
    var link: BankTextLinkState
    var origin: BankTextRoute
    var arrivedAt: Date
    var secretCount: Int
  }

  private let state = Mutex<(calls: [Call], rows: [PasteRow], ranges: [(Date, Date)])>(([], [], []))
  let outcome: BankTextAuthored?
  let failure: BankTextsCoreFailure?

  init(outcome: BankTextAuthored? = nil, failure: BankTextsCoreFailure? = nil, rows: [PasteRow] = []) {
    self.outcome = outcome
    self.failure = failure
    state.withLock { $0.rows = rows }
  }

  var calls: [Call] { state.withLock { $0.calls } }
  var rangesAsked: Int { state.withLock { $0.ranges.count } }

  func author(
    _ text: String, sender: String?, reading: KeptBankText, arrivedAt: Date, secret: Data, link: BankTextLinkState,
    origin: BankTextRoute
  ) async throws(BankTextsCoreFailure) -> BankTextAuthored {
    state.withLock {
      $0.calls.append(
        Call(text: text, sender: sender, link: link, origin: origin, arrivedAt: arrivedAt, secretCount: secret.count))
    }
    if let failure { throw failure }
    return outcome ?? .authored(rowID: "row-1", filed: false, bank: reading.fields.bank, keptAt: arrivedAt)
  }

  func liveRows(postedFrom: Date, through: Date) async -> [PasteRow] {
    state.withLock {
      $0.ranges.append((postedFrom, through))
      return $0.rows.filter { $0.postedAt >= postedFrom && $0.postedAt <= through }
    }
  }
}

nonisolated final class FakeTextAccount: BankTextAccount {
  let author: any BankTextsAuthoring
  let answer: Bool?
  private let count = Mutex(0)

  init(author: any BankTextsAuthoring, answer: Bool? = nil) {
    self.author = author
    self.answer = answer
  }

  var asks: Int { count.withLock { $0 } }

  func askLink() async -> Bool? {
    count.withLock { $0 += 1 }
    return answer
  }
}

@MainActor
@Suite("Bank texts: the intent, the facts and paste")
struct BankTextsIntakeTests {
  static let t0 = Date(timeIntervalSince1970: 1_792_000_000)
  static let payment = "SYNTHETIC purchase AED 12.00 at Sample Shop card 0000"
  static let personal = "SYNTHETIC I sent you AED 50"
  static let code = "SYNTHETIC code 000000"
  static let chat = "SYNTHETIC see you at 8"

  static let table: [String: BankTextRead] = [
    payment: .keep(
      KeptBankText(
        fields: BankTextFields(bank: "dib", amount: .aed(1_200), direction: .out, merchant: "Sample Shop", cardEnding: "0000"),
        mayBeBanks: true)),
    personal: .keep(KeptBankText(fields: BankTextFields(amount: .aed(5_000), direction: .out), mayBeBanks: false)),
    code: .drop(.oneTimeCode, setAsideSender: "DIB", bank: "dib"),
    chat: .drop(.noPaymentShape, setAsideSender: nil, bank: nil),
  ]

  struct Rig {
    let dir: URL
    let facts: BankTextsFacts
    let marker: LockedTextsMarkerFile
    let secrets: MemorySecretStore
    let reader: FakeTextReader
    let author: FakeTextAuthor
    let account: FakeTextAccount

    var factsData: BankTextsFactsData { facts.read(nowMs: BankTextIntake.ms(BankTextsIntakeTests.t0)) }
  }

  func rig(author: FakeTextAuthor = FakeTextAuthor(), answer: Bool? = nil) -> Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("texts-\(UUID().uuidString)")
    return Rig(
      dir: dir, facts: BankTextsFacts(directory: dir.appendingPathComponent("facts")),
      marker: LockedTextsMarkerFile(directory: dir.appendingPathComponent("marker")), secrets: MemorySecretStore(),
      reader: FakeTextReader(Self.table), author: author, account: FakeTextAccount(author: author, answer: answer))
  }

  final class Counter {
    var n = 0
  }

  func intake(_ r: Rig, counter: Counter = Counter(), signedIn: Bool = true) -> BankTextIntake {
    let account = r.account
    return BankTextIntake(
      BankTextIntakeDeps(
        reader: r.reader, facts: r.facts, marker: r.marker, secret: TextKeySecret(store: r.secrets),
        signIn: { signedIn ? .signedIn : .signedOut },
        account: {
          counter.n += 1
          return account
        }, linkBudget: .milliseconds(200)))
  }

  func setCopy(_ r: Rig, linked: Bool?) {
    guard let linked else { return }
    BankTextsLinkCopy.note(linked: linked, facts: r.facts, nowMs: BankTextIntake.ms(Self.t0) - 60_000)
  }

  @Test func linkedCopyAuthorsNothingAndCountsTextsThatMayBeABanks() async {
    let r = rig()
    setCopy(r, linked: true)
    let counter = Counter()
    let i = intake(r, counter: counter)
    #expect(await i.run(Self.payment, sender: "DIB", at: Self.t0) == .ignored(counted: true))
    #expect(await i.run(Self.payment, sender: nil, at: Self.t0) == .ignored(counted: true))
    #expect(await i.run(Self.personal, sender: "+971500000000", at: Self.t0) == .ignored(counted: false))
    #expect(await i.run(Self.chat, sender: "+971500000000", at: Self.t0) == .dropped(counted: false))
    #expect(r.author.calls.isEmpty && counter.n == 0 && r.account.asks == 0)
    #expect(r.factsData.ignoredTotal(nowMs: BankTextIntake.ms(Self.t0)) == 2)
  }

  @Test func notLinkedCopyAuthorsWithoutAskingTheServer() async {
    let r = rig(answer: true)
    setCopy(r, linked: false)
    #expect(await intake(r).run(Self.payment, sender: "DIB", at: Self.t0) == .authored(filed: false))
    #expect(r.account.asks == 0)
    #expect(r.author.calls.map(\.link) == [.notLinked])
    #expect(r.author.calls.first?.origin == .automation && r.author.calls.first?.secretCount == 32)
  }

  @Test func noCopyAndNoAnswerAuthorsForReviewOnly() async {
    let r = rig(answer: nil)
    #expect(await intake(r).run(Self.payment, sender: "DIB", at: Self.t0) == .authored(filed: false))
    #expect(r.account.asks == 1)
    #expect(r.author.calls.map(\.link) == [.unknownUnanswered])
    #expect(r.factsData.link == nil)
  }

  @Test func noCopyAndADroppedTextSendsNoRequest() async {
    let r = rig(answer: false)
    let counter = Counter()
    let i = intake(r, counter: counter)
    #expect(await i.run(Self.chat, sender: nil, at: Self.t0) == .dropped(counted: false))
    #expect(await i.run(Self.code, sender: "DIB", at: Self.t0) == .dropped(counted: true))
    #expect(counter.n == 0 && r.account.asks == 0 && r.author.calls.isEmpty)
  }

  @Test func noCopyAskedAndTheServerSaysLinked() async {
    let r = rig(answer: true)
    #expect(await intake(r).run(Self.payment, sender: nil, at: Self.t0) == .ignored(counted: true))
    #expect(r.author.calls.isEmpty && r.account.asks == 1)
    #expect(r.factsData.link == nil)
  }

  @Test func noCopyAskedAndTheServerSaysNotLinked() async {
    let r = rig(answer: false)
    #expect(await intake(r).run(Self.payment, sender: nil, at: Self.t0) == .authored(filed: false))
    #expect(r.author.calls.map(\.link) == [.notLinked])
    #expect(r.factsData.link == nil)
  }

  struct LinkFailure: Error {}

  final class Clock {
    var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
  }

  func keeper(_ r: Rig, _ clock: Clock) -> BankTextsLinkKeeper {
    BankTextsLinkKeeper(facts: r.facts, nowMs: { clock.ms })
  }

  @Test func theCopyFollowsEveryServerAnswer() async {
    let r = rig()
    let clock = Clock(BankTextIntake.ms(Self.t0))
    let k = keeper(r, clock)
    let other = await k.ask { (MailboxLinkStatus.holder(isThisDevice: false, watchExpiresAtMs: nil), "gmail" as String?) }
    #expect(other?.1 == "gmail")
    #expect(r.factsData.link == .init(linked: true, learnedAtMs: clock.ms))
    clock.ms += 1
    _ = await k.ask { (MailboxLinkStatus.noLink, nil as String?) }
    #expect(r.factsData.link == .init(linked: false, learnedAtMs: clock.ms))
    clock.ms += 1
    let failed: (MailboxLinkStatus, String?)? = await k.ask { throw LinkFailure() }
    #expect(failed == nil)
    #expect(r.factsData.link == .init(linked: false, learnedAtMs: clock.ms - 1))
  }

  @Test func thisDevicesConnectAndDisconnectWriteTheCopy() throws {
    let r = rig()
    let clock = Clock(BankTextIntake.ms(Self.t0))
    let k = keeper(r, clock)
    k.connected()
    #expect(r.factsData.link == .init(linked: true, learnedAtMs: clock.ms))
    clock.ms += 1
    k.disconnected(.otherDevice)
    k.disconnected(.failed)
    #expect(r.factsData.link?.linked == true)
    k.disconnected(.disconnected)
    #expect(r.factsData.link == .init(linked: false, learnedAtMs: clock.ms))
    #expect(!r.factsData.chosen)
    k.connected()
    try r.facts.update(nowMs: clock.ms) { $0.lastRunMs = clock.ms }
    k.disconnected(.removed(2))
    #expect(r.factsData.link?.linked == false && r.factsData.chosen)
    k.connected()
    k.disconnected(.disconnectedRemoveFailed)
    #expect(r.factsData.link?.linked == false)
  }

  @Test func theRuntimeWritesTheCopyOnEachServerAnswerConnectAndDisconnect() async throws {
    let provider = UserDefaults.standard.string(forKey: LocalAccountData.mailboxProviderKey)
    defer { UserDefaults.standard.set(provider, forKey: LocalAccountData.mailboxProviderKey) }
    let server = MiniHasalad(invite: LiveAccountServiceTests.invite)
    let env = LiveAccountServiceTests.phone(server)
    let (a, _) = try await LiveAccountServiceTests.signUp(server, env)
    let binding = try #require(try env.secrets.binding())
    let r = rig()
    let rt = try await AccountRuntime.open(
      env: env, binding: binding, enrolled: a.enrolled, build: .current,
      profile: BootController.profileInfo(nil, binding: binding), usesPasskey: { false }, stopped: { _ in },
      bankTextFacts: r.facts)
    let now = { rt.context.clock.nowMs() }
    #expect(rt.store.mailboxPhase == .unlinked)
    #expect(r.factsData.link == nil && server.mailboxLinkAsks == 0)

    await rt.refreshMailbox()
    #expect(server.mailboxLinkAsks == 1 && r.factsData.link?.linked == false)

    server.mailboxLink = (thisDevice: false, provider: "gmail")
    let status = await rt.askServerLink()
    #expect(status == .holder(isThisDevice: false, watchExpiresAtMs: nil))
    #expect(server.mailboxLinkAsks == 2 && r.factsData.link?.linked == true)

    server.mailboxLink = nil
    #expect(await rt.askServerLink() == .noLink)
    #expect(r.factsData.link?.linked == false)

    server.offline = true
    #expect(await rt.askServerLink() == nil)
    #expect(r.factsData.link?.linked == false)
    server.offline = false

    rt.linkedHere(.gmail)
    #expect(r.factsData.link?.linked == true && rt.activeProvider == .gmail)
    try r.facts.update(nowMs: now()) { $0.lastRunMs = now() }
    rt.unlinkedHere(.disconnected)
    #expect(r.factsData.link?.linked == false && r.factsData.chosen)
    rt.linkedHere(.gmail)
    rt.unlinkedHere(.otherDevice)
    #expect(r.factsData.link?.linked == true)
    rt.unlinkedHere(.disconnected)

    server.mailboxLink = (thisDevice: false, provider: "gmail")
    let mailbox = LiveMailboxConnecting(runtime: { rt })
    await #expect(throws: MailConnectFailure.takenByOtherIPhone) {
      try await mailbox.disconnect("gmail", removeTransactions: false)
    }
    #expect(rt.store.mailboxPhase == .otherDevice && r.factsData.link?.linked == true)
    await rt.close()
  }

  @Test func onlyAPhaseThatReadsTheMailboxWritesLinked() {
    for phase in MailboxPhase.allCases {
      let r = rig()
      let k = keeper(r, Clock(BankTextIntake.ms(Self.t0)))
      k.ownLink(phase)
      let reads: Set<MailboxPhase> = [.scanning, .awaitingCards, .authoringBackfill, .active, .halted]
      #expect((r.factsData.link?.linked == true) == reads.contains(phase), "\(phase)")
      #expect(BankTextsLinkKeeper.asksServer(phase) == [.unlinked, .otherDevice, .reconnectRequired].contains(phase))
    }
    #expect(!BankTextsLinkKeeper.asksServer(nil))
  }

  @Test func aLaneThatLostItsLinkStopsCountingTextsAsIgnored() async {
    let r = rig(answer: nil)
    let clock = Clock(BankTextIntake.ms(Self.t0) - 120_000)
    let k = keeper(r, clock)
    var asked = 0
    await k.afterRun(.active) { asked += 1 }
    #expect(asked == 0 && r.factsData.link?.linked == true)
    #expect(await intake(r).run(Self.payment, sender: "DIB", at: Self.t0) == .ignored(counted: true))
    clock.ms += 60_000
    await k.afterRun(.reconnectRequired) {
      asked += 1
      _ = await k.ask { (MailboxLinkStatus.noLink, nil as String?) }
    }
    #expect(asked == 1 && r.factsData.link == .init(linked: false, learnedAtMs: clock.ms))
    await k.afterRun(.reconnectRequired) {}
    #expect(r.factsData.link?.linked == false)
    #expect(await intake(r).run(Self.payment, sender: "DIB", at: Self.t0) == .authored(filed: false))
    #expect(r.author.calls.map(\.link) == [.notLinked])
  }

  @Test func aLaneThatMustSignInAgainKeepsALinkTheServerStillHolds() async {
    let r = rig()
    let clock = Clock(BankTextIntake.ms(Self.t0))
    let k = keeper(r, clock)
    k.ownLink(.active)
    await k.afterRun(.reconnectRequired) {
      _ = await k.ask { (MailboxLinkStatus.holder(isThisDevice: true, watchExpiresAtMs: nil), nil as String?) }
    }
    #expect(r.factsData.link?.linked == true)
    await k.afterRun(.reconnectRequired) {
      let none: (MailboxLinkStatus, String?)? = await k.ask { throw LinkFailure() }
      #expect(none == nil)
    }
    #expect(r.factsData.link?.linked == true)
  }

  @Test func theSetUpTestPassesInsideTheWindowOnly() async {
    let r = rig()
    let i = intake(r)
    #expect(await i.run("hasala test", sender: "+971500000000", at: Self.t0) == .dropped(counted: false))
    #expect(r.factsData.testPassedMs == nil)
    let opened = BankTextIntake.ms(Self.t0)
    _ = try? r.facts.update(nowMs: opened) { $0.testOpenedMs = opened }
    for sender in ["+971500000000", "Unknown", "DIB", nil] as [String?] {
      _ = try? r.facts.update(nowMs: opened) { $0.testOpenedMs = opened; $0.testPassedMs = nil }
      #expect(await i.run("Hasala Test", sender: sender, at: Self.t0.addingTimeInterval(60)) == .testPassed)
      #expect(r.factsData.testPassedMs != nil && r.factsData.testOpenedMs == nil)
    }
    let after = Self.t0.addingTimeInterval(11 * 60)
    _ = try? r.facts.update(nowMs: opened) { $0.testOpenedMs = opened; $0.testPassedMs = nil }
    #expect(await i.run("hasala test", sender: nil, at: after) == .dropped(counted: false))
    let data = r.facts.read(nowMs: BankTextIntake.ms(after))
    #expect(data.testPassedMs == nil && data.testOpenedMs == nil)
    #expect(r.author.calls.isEmpty && data.setAside.isEmpty && data.ignored.isEmpty && r.marker.read() == nil)
  }

  @Test func dropsCountOnlyForABankSender() async {
    let r = rig()
    let i = intake(r)
    #expect(await i.run(Self.code, sender: "DIB", at: Self.t0) == .dropped(counted: true))
    #expect(await i.run(Self.code, sender: "DIB", at: Self.t0) == .dropped(counted: true))
    #expect(await i.run(Self.chat, sender: "+971500000000", at: Self.t0) == .dropped(counted: false))
    let data = r.factsData
    #expect(data.setAside.count == 1 && data.setAside.first?.count == 2 && data.setAside.first?.kind == .oneTimeCode)
    #expect(data.lastRunMs == BankTextIntake.ms(Self.t0))
  }

  @Test func anAuthoredTextNotesItsBankAndTheRun() async {
    let r = rig(answer: false)
    #expect(await intake(r).run(Self.payment, sender: "DIB", at: Self.t0) == .authored(filed: false))
    #expect(r.factsData.lastKeptMs["dib"] == BankTextIntake.ms(Self.t0))
    #expect(r.factsData.lastRunMs == BankTextIntake.ms(Self.t0))
  }

  @Test func aCoreThatIsNotWiredFailsLoudly() async {
    let r = rig(author: FakeTextAuthor(failure: .unavailable), answer: false)
    #expect(await intake(r).run(Self.payment, sender: "DIB", at: Self.t0) == .failed(BankTextIntake.unavailableMessage))
  }

  @Test func signedOutStoresNothing() async {
    let r = rig()
    let i = intake(r, signedIn: false)
    #expect(await i.run(Self.payment, sender: "DIB", at: Self.t0) == .failed(BankTextIntake.signedOutMessage))
    #expect(await i.run(Self.code, sender: "DIB", at: Self.t0) == .dropped(counted: false))
    #expect(!r.facts.fileExists && r.author.calls.isEmpty)
  }

  @Test func beforeTheFirstUnlockOnlyTheMarkerIsWritten() async {
    let r = rig()
    r.secrets.locked = true
    let i = intake(r)
    #expect(await i.run(Self.payment, sender: "DIB", at: Self.t0) == .failed(BankTextIntake.lockedMessage, marked: true))
    #expect(
      await i.run(Self.payment, sender: nil, at: Self.t0.addingTimeInterval(90))
        == .failed(BankTextIntake.lockedMessage, marked: true))
    #expect(
      await i.run(Self.personal, sender: "+971500000000", at: Self.t0) == .failed(BankTextIntake.lockedMessage))
    #expect(await i.run(Self.code, sender: "DIB", at: Self.t0) == .dropped(counted: false))
    #expect(await i.run(Self.chat, sender: nil, at: Self.t0) == .dropped(counted: false))
    #expect(await i.run("hasala test", sender: nil, at: Self.t0) == .dropped(counted: false))
    #expect(r.marker.read() == LockedTextsMarker(count: 2, latestMinuteMs: LockedTextsMarkerFile.minute(BankTextIntake.ms(Self.t0) + 90_000)))
    #expect(!r.facts.fileExists && r.author.calls.isEmpty && r.reader.windowsSeen.allSatisfy { !$0 })
  }

  func lane(_ r: Rig, now: Date = BankTextsIntakeTests.t0) -> LiveBankTexts {
    let author = r.author
    let secrets = r.secrets
    return LiveBankTexts(
      facts: r.facts, marker: r.marker, reader: r.reader, author: { author },
      secret: { TextKeySecret(store: secrets) }, now: { now })
  }

  @Test func afterTheUnlockTheNoticeShowsWhenNotLinked() {
    for linked in [false, nil] as [Bool?] {
      let r = rig()
      setCopy(r, linked: linked)
      r.marker.add(arrivedAtMs: BankTextIntake.ms(Self.t0))
      r.marker.add(arrivedAtMs: BankTextIntake.ms(Self.t0))
      let l = lane(r)
      l.refresh()
      #expect(l.lockedNotice == 2)
      #expect(BankTexts.lockedNoticeLine(2).hasPrefix("2 texts that look like payments arrived while your iPhone was locked"))
      l.lockedNoticeShown()
      #expect(l.lockedNotice == nil && r.marker.read() == nil)
      #expect(r.factsData.ignoredTotal(nowMs: BankTextIntake.ms(Self.t0)) == 0)
    }
  }

  @Test func afterTheUnlockALinkedAccountCountsTheMarkerAsIgnored() {
    let r = rig()
    setCopy(r, linked: true)
    r.marker.add(arrivedAtMs: BankTextIntake.ms(Self.t0))
    r.marker.add(arrivedAtMs: BankTextIntake.ms(Self.t0))
    r.marker.add(arrivedAtMs: BankTextIntake.ms(Self.t0))
    let l = lane(r)
    l.refresh()
    #expect(l.lockedNotice == nil && r.marker.read() == nil)
    #expect(l.ignoredLast30Days == 3)
  }

  @Test func aLinkedAccountKeepsTheMarkerWhenTheCountCannotBeSaved() throws {
    let r = rig()
    setCopy(r, linked: true)
    r.marker.add(arrivedAtMs: BankTextIntake.ms(Self.t0))
    r.marker.add(arrivedAtMs: BankTextIntake.ms(Self.t0))
    let factsDir = r.dir.appendingPathComponent("facts")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: factsDir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: factsDir.path) }
    let l = lane(r)
    l.refresh()
    #expect(l.lockedNotice == nil && r.marker.read()?.count == 2)
    #expect(l.ignoredLast30Days == 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: factsDir.path)
    l.refresh()
    #expect(l.lockedNotice == nil && r.marker.read() == nil)
    #expect(l.ignoredLast30Days == 2)
  }

  @Test func countsOlderThanThirtyDaysAreDeleted() throws {
    let r = rig()
    let now = BankTextIntake.ms(Self.t0)
    let day: Int64 = 86_400_000
    try r.facts.update(nowMs: now - 31 * day) { d in
      d.addSetAside(sender: "DIB", bank: "dib", kind: .promotion, atMs: now - 31 * day)
      d.addIgnored(atMs: now - 31 * day)
    }
    try r.facts.update(nowMs: now - 29 * day) { d in
      d.addSetAside(sender: "DIB", bank: "dib", kind: .promotion, atMs: now - 29 * day)
      d.addSetAside(sender: "DIB", bank: "dib", kind: .declined, atMs: now - 29 * day)
      d.addIgnored(atMs: now - 29 * day)
    }
    #expect(r.facts.read(nowMs: now - 29 * day).setAside.count == 3)
    #expect(try onDisk(r).setAside.count == 3)
    let data = r.facts.read(nowMs: now)
    #expect(data.setAside.count == 2 && Set(data.setAside.map(\.kind)) == [.promotion, .declined])
    #expect(data.ignored.count == 1 && data.ignoredTotal(nowMs: now) == 1)
    #expect(try onDisk(r) == data)
    let reloaded = BankTextsFacts(directory: r.dir.appendingPathComponent("facts")).read(nowMs: now)
    #expect(reloaded == data)
  }

  func onDisk(_ r: Rig) throws -> BankTextsFactsData {
    let bytes = try Data(contentsOf: r.dir.appendingPathComponent("facts").appendingPathComponent("facts.json"))
    return try JSONDecoder().decode(BankTextsFactsData.self, from: bytes)
  }

  @Test func theTestWindowOpenTimeIsDeletedWhenItCloses() throws {
    let r = rig()
    let now = BankTextIntake.ms(Self.t0)
    try r.facts.update(nowMs: now) { $0.testOpenedMs = now }
    #expect(r.facts.read(nowMs: now + 9 * 60_000).testWindowOpen(nowMs: now + 9 * 60_000))
    #expect(try onDisk(r).testOpenedMs == now)
    #expect(r.facts.read(nowMs: now + 10 * 60_000).testOpenedMs == nil)
    #expect(try onDisk(r).testOpenedMs == nil)
    let l = lane(r, now: Self.t0.addingTimeInterval(60))
    l.startTest()
    #expect(l.test == .waiting(since: Self.t0.addingTimeInterval(60)))
    #expect(try onDisk(r).testOpenedMs == now + 60_000)
    let closed = lane(r, now: Self.t0.addingTimeInterval(11 * 60 + 1))
    closed.reload()
    #expect(try onDisk(r).testOpenedMs == nil)
  }

  @Test func aReadThatPrunesNothingWritesNothing() {
    let r = rig()
    #expect(r.facts.read(nowMs: BankTextIntake.ms(Self.t0)) == BankTextsFactsData())
    #expect(!r.facts.fileExists)
  }

  func seed(_ r: Rig, secrets: any SecretStore) throws {
    let now = BankTextIntake.ms(Self.t0)
    try r.facts.update(nowMs: now) { $0.lastRunMs = now; $0.chosen = true }
    r.marker.add(arrivedAtMs: now)
    _ = try TextKeySecret(store: secrets).current()
    #expect(r.facts.fileExists && r.marker.read() != nil)
  }

  @Test func signingOutOfTheServiceDeletesTheFactsTheMarkerAndTheSecret() async throws {
    let server = MiniHasalad(invite: LiveAccountServiceTests.invite)
    let env = LiveAccountServiceTests.phone(server)
    let (a, _) = try await LiveAccountServiceTests.signUp(server, env)
    let r = rig()
    a.bankTextFacts = r.facts
    a.bankTextMarker = r.marker
    try seed(r, secrets: env.secrets.store)
    var left = 0
    a.hooks = LiveAccountHooks(left: { left += 1 })
    await a.signOut()
    #expect(left == 1)
    #expect(!r.facts.fileExists && r.marker.read() == nil)
    #expect(try env.secrets.store.read(.textKeySecret) == nil)
  }

  @Test func deletingTheAccountDeletesTheFactsTheMarkerAndTheSecret() async throws {
    let server = MiniHasalad(invite: LiveAccountServiceTests.invite)
    let env = LiveAccountServiceTests.phone(server)
    let (a, _) = try await LiveAccountServiceTests.signUp(server, env)
    let r = rig()
    a.bankTextFacts = r.facts
    a.bankTextMarker = r.marker
    try seed(r, secrets: env.secrets.store)
    a.hooks = LiveAccountHooks(left: {})
    try await a.perform(.deleteAccount, password: LiveAccountServiceTests.password)
    #expect(server.deletedAccounts == 1)
    #expect(!r.facts.fileExists && r.marker.read() == nil)
    #expect(try env.secrets.store.read(.textKeySecret) == nil)
  }

  @Test func forgettingTheAccountsLocalDataDeletesTheFactsAndTheMarker() throws {
    let r = rig()
    try seed(r, secrets: r.secrets)
    LocalAccountData.forget(defaults: LiveGateTests.defaults(), facts: r.facts, marker: r.marker)
    #expect(!r.facts.fileExists && r.marker.read() == nil)
  }

  @Test func signOutDeletesTheFactsTheMarkerAndTheSecret() throws {
    let r = rig()
    let now = BankTextIntake.ms(Self.t0)
    try r.facts.update(nowMs: now) { $0.lastRunMs = now; $0.chosen = true }
    r.marker.add(arrivedAtMs: now)
    _ = try TextKeySecret(store: r.secrets).current()
    BankTextsDeviceData.forget(secrets: r.secrets, facts: r.facts, marker: r.marker)
    #expect(!r.facts.fileExists && r.marker.read() == nil && r.facts.read(nowMs: now) == BankTextsFactsData())
    #expect(try r.secrets.read(.textKeySecret) == nil)
  }

  @Test func aLockedKeychainWithNoSecretYetStillWritesTheMarker() async {
    let r = rig()
    let store = LockedNoSecretStore()
    let secrets = Secrets(store: store, apiHost: "api.hasala.app")
    #expect(!TextKeySecret(store: store).beforeFirstUnlock())
    #expect(BankTextIntake.signIn(secrets) == .locked)
    let i = BankTextIntake(
      BankTextIntakeDeps(
        reader: r.reader, facts: r.facts, marker: r.marker, secret: TextKeySecret(store: store),
        signIn: { BankTextIntake.signIn(secrets) }, account: { nil }, linkBudget: .milliseconds(200)))
    #expect(await i.run(Self.payment, sender: "DIB", at: Self.t0) == .failed(BankTextIntake.lockedMessage, marked: true))
    #expect(await i.run(Self.code, sender: "DIB", at: Self.t0) == .dropped(counted: false))
    #expect(r.marker.read()?.count == 1)
    #expect(!r.facts.fileExists && r.author.calls.isEmpty)
  }

  static func binding() -> AccountBinding {
    AccountBinding(
      userID: UserID("00000000-0000-4000-8000-000000000001")!,
      writerID: WriterID("ios-00000000-0000-4000-8000-000000000002")!, apiBase: "https://api.hasala.app", keyEpoch: 1,
      emailNorm: "maya@example.com", serverSalt: Data(repeating: 1, count: 32), displayName: nil)
  }

  static func session(pendingLogout: Bool = false) -> SessionRecord {
    SessionRecord(
      token: "synthetic-token", userID: "00000000-0000-4000-8000-000000000001", expiresAt: 4_000_000_000,
      tag: "0011223344556677", pendingLogout: pendingLogout)
  }

  @Test func theSignInIsReadFromTheBindingAndTheSession() throws {
    let store = MemorySecretStore()
    let secrets = Secrets(store: store, apiHost: "api.hasala.app")
    #expect(BankTextIntake.signIn(secrets) == .signedOut)
    try secrets.writeBinding(Self.binding())
    #expect(BankTextIntake.signIn(secrets) == .signedOut)
    try secrets.writeSession(Self.session())
    #expect(BankTextIntake.signIn(secrets) == .signedIn)
    try secrets.writeSession(Self.session(pendingLogout: true))
    #expect(BankTextIntake.signIn(secrets) == .signedOut)
    try secrets.writeSession(Self.session())
    #expect(BankTextIntake.signIn(secrets, installChecked: false) == .signedOut)
    store.locked = true
    #expect(BankTextIntake.signIn(secrets) == .locked)
    #expect(BankTextIntake.signIn(secrets, installChecked: false) == .locked)
  }

  @Test func aReinstallWhoseInstallCheckHasNotRunStoresNothing() async throws {
    let r = rig()
    let secrets = Secrets(store: r.secrets, apiHost: "api.hasala.app")
    try secrets.writeBinding(Self.binding())
    try secrets.writeSession(Self.session())
    let counter = Counter()
    let account = r.account
    let i = BankTextIntake(
      BankTextIntakeDeps(
        reader: r.reader, facts: r.facts, marker: r.marker, secret: TextKeySecret(store: r.secrets),
        signIn: { BankTextIntake.signIn(secrets, installChecked: false) },
        account: {
          counter.n += 1
          return account
        }, linkBudget: .milliseconds(200)))
    #expect(await i.run(Self.code, sender: "DIB", at: Self.t0) == .dropped(counted: false))
    #expect(await i.run(Self.payment, sender: "DIB", at: Self.t0) == .failed(BankTextIntake.signedOutMessage))
    #expect(!r.facts.fileExists && r.marker.read() == nil && counter.n == 0 && r.author.calls.isEmpty)
  }

  @Test func aSignedOutBoundIPhoneDropsTheMarkerItWroteBeforeTheFirstUnlock() async throws {
    let r = rig()
    let store = LockedNoSecretStore()
    let secrets = Secrets(store: store, apiHost: "api.hasala.app")
    let i = BankTextIntake(
      BankTextIntakeDeps(
        reader: r.reader, facts: r.facts, marker: r.marker, secret: TextKeySecret(store: store),
        signIn: { BankTextIntake.signIn(secrets) }, account: { nil }, linkBudget: .milliseconds(200)))
    #expect(await i.run(Self.payment, sender: "DIB", at: Self.t0) == .failed(BankTextIntake.lockedMessage, marked: true))
    #expect(r.marker.read()?.count == 1)
    for boot in [BootState.opening(Self.binding()), .onboardingKeys, .needsUnlock] {
      BootController.dropLockedTextsMarker(BootController.initialPhase(boot, finished: true).0, marker: r.marker)
      #expect(r.marker.read()?.count == 1)
    }
    BootController.dropLockedTextsMarker(BootController.initialPhase(.signedOutBound, finished: true).0, marker: r.marker)
    #expect(r.marker.read() == nil)
    let l = lane(r)
    l.refresh()
    #expect(l.lockedNotice == nil)
    r.marker.add(arrivedAtMs: BankTextIntake.ms(Self.t0))
    BootController.dropLockedTextsMarker(BootController.initialPhase(.signedOut, finished: false).0, marker: r.marker)
    #expect(r.marker.read() == nil)
  }

  @Test func theSecretIsMadeOnFirstNeedAndKept() throws {
    let store = MemorySecretStore()
    let secret = TextKeySecret(store: store)
    #expect(try !secret.held())
    let first = try secret.current()
    #expect(first.count == 32)
    #expect(try secret.current() == first)
    store.locked = true
    #expect(secret.beforeFirstUnlock())
    store.locked = false
    #expect(!secret.beforeFirstUnlock())
    secret.forget()
    #expect(try store.read(.textKeySecret) == nil)
    #expect(try secret.current() != first)
  }

  @Test func theSecretGoesWithTheAccountAndAnOrphanGoesAtInstall() throws {
    let api = InMemoryKeychainAPI()
    let keychain = KeychainSecretStore(accessGroup: "G", api: api)
    let secret = TextKeySecret(store: keychain)
    _ = try secret.current()
    #expect(api.attributes(service: "app.hasala.text-key", account: "device", group: "G")?["accessible"]
      == "\(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)")
    #expect(keychain.purgeAll(groups: ["G"]).complete)
    #expect(try !secret.held())
    _ = try secret.current()
    let user = UserID("00000000-0000-4000-8000-000000000001")!
    try Secrets(store: keychain, apiHost: "h").wipeAccount(userID: user, writerID: nil)
    #expect(try !secret.held())
  }

  static let mailRow = PasteRow(
    id: "mail-1", fromText: false, bank: "dib", cardEnding: nil, amount: .aed(1_200), direction: .out,
    merchant: "SAMPLE SHOP LLC", postedAt: t0.addingTimeInterval(-3600))

  @Test func thePreCheckFindsAMailRowWithAnotherMerchantOrNoCard() {
    let f = BankTextFields(
      bank: "dib", amount: .aed(1_200), direction: .out, merchant: "Sample Shop", postedAt: Self.t0, cardEnding: "0000")
    let m = PastePreCheck.match(f, pastedAt: Self.t0, rows: [Self.mailRow])
    #expect(m?.rowID == "mail-1" && m?.kind == .payment && m?.fromText == false)
    var other = Self.mailRow
    other.cardEnding = "1111"
    #expect(PastePreCheck.match(f, pastedAt: Self.t0, rows: [other]) == nil)
    other = Self.mailRow
    other.amount = .aed(1_300)
    #expect(PastePreCheck.match(f, pastedAt: Self.t0, rows: [other]) == nil)
    other = Self.mailRow
    other.direction = .in
    #expect(PastePreCheck.match(f, pastedAt: Self.t0, rows: [other]) == nil)
    other = Self.mailRow
    other.postedAt = Self.t0.addingTimeInterval(-25 * 3600)
    #expect(PastePreCheck.match(f, pastedAt: Self.t0, rows: [other]) == nil)
  }

  @Test func anUndatedPasteLooksBackSevenDays() {
    let f = BankTextFields(bank: "dib", amount: .aed(1_200), direction: .out)
    var row = Self.mailRow
    row.postedAt = Self.t0.addingTimeInterval(-6 * 86_400)
    #expect(PastePreCheck.match(f, pastedAt: Self.t0, rows: [row])?.rowID == "mail-1")
    row.postedAt = Self.t0.addingTimeInterval(-8 * 86_400)
    #expect(PastePreCheck.match(f, pastedAt: Self.t0, rows: [row]) == nil)
  }

  @Test func aPasteOffersToReplaceAnUnparsedTextRow() {
    let unread = PasteRow(
      id: "sms-1", fromText: true, unparsed: true, bank: "dib", cardEnding: "0000",
      postedAt: Self.t0.addingTimeInterval(-5 * 60))
    let dated = BankTextFields(bank: "dib", amount: .aed(1_200), direction: .out, postedAt: Self.t0, cardEnding: "0000")
    #expect(PastePreCheck.match(dated, pastedAt: Self.t0, rows: [unread])?.kind == .unreadText)
    var far = unread
    far.postedAt = Self.t0.addingTimeInterval(-11 * 60)
    #expect(PastePreCheck.match(dated, pastedAt: Self.t0, rows: [far]) == nil)
    var otherCard = unread
    otherCard.cardEnding = "1111"
    #expect(PastePreCheck.match(dated, pastedAt: Self.t0, rows: [otherCard]) == nil)
    let undated = BankTextFields(bank: "dib", amount: .aed(1_200), direction: .out)
    var week = unread
    week.postedAt = Self.t0.addingTimeInterval(-6 * 86_400)
    #expect(PastePreCheck.match(undated, pastedAt: Self.t0, rows: [week])?.kind == .unreadText)
    week.postedAt = Self.t0.addingTimeInterval(-8 * 86_400)
    #expect(PastePreCheck.match(undated, pastedAt: Self.t0, rows: [week]) == nil)
    var otherBank = unread
    otherBank.bank = "enbd"
    #expect(PastePreCheck.match(dated, pastedAt: Self.t0, rows: [otherBank]) == nil)
  }

  @Test func theLanePastesIntoReviewAndReplacesAnUnreadRow() async throws {
    let unread = PasteRow(
      id: "sms-1", fromText: true, unparsed: true, bank: "dib", cardEnding: "0000",
      postedAt: Self.t0.addingTimeInterval(-2 * 86_400))
    let r = rig(author: FakeTextAuthor(rows: [unread]))
    let l = lane(r)
    #expect(await l.read(Self.code) == .notAPayment)
    guard case .read(let preview) = await l.read(Self.payment) else {
      Issue.record("not read")
      return
    }
    #expect(preview.amount == .aed(1_200) && preview.bank == .dib && preview.cardEnding == "0000")
    let match = try #require(await l.match(Self.payment))
    #expect(match.kind == .unreadText && match.rowID == "sms-1")
    try await l.addToReview(Self.payment, replacing: match)
    try await l.addToReview(Self.payment, replacing: nil)
    #expect(r.author.calls.map(\.origin) == [.paste(replacing: "sms-1"), .paste(replacing: nil)])
    #expect(r.author.calls.allSatisfy { $0.sender == nil && $0.link == .unknownUnanswered })
    #expect(r.author.calls.first?.arrivedAt == Date(timeIntervalSince1970: 1_791_999_960))
    #expect(r.factsData.lastKeptMs.isEmpty && r.factsData.lastRunMs == nil)
  }

  @Test func pasteIsRefusedWhileTheCopySaysLinked() async {
    let r = rig()
    setCopy(r, linked: true)
    let l = lane(r)
    #expect(!l.offersPaste && l.readsEmail)
    await #expect(throws: BankTextsFailure.failed(BankTexts.pasteRefused)) {
      try await l.addToReview(Self.payment, replacing: nil)
    }
    #expect(r.author.calls.isEmpty)
    let model = PasteBankTextModel(lane: l)
    #expect(model.refused)
    setCopy(r, linked: false)
    l.reload()
    #expect(l.offersPaste && !PasteBankTextModel(lane: l).refused)
  }

  @Test func theLaneShowsOnlyWhatItObserved() throws {
    let r = rig()
    let l = lane(r)
    #expect(l.status == .notSetUp && l.link == .unknown && l.offersPaste)
    let now = BankTextIntake.ms(Self.t0)
    try r.facts.update(nowMs: now) { d in
      d.chosen = true
      d.link = .init(linked: false, learnedAtMs: now)
    }
    l.reload()
    #expect(l.status == .waitingForFirstText && l.usesTexts)
    try r.facts.update(nowMs: now) { d in
      d.lastRunMs = now - 4 * 60_000
      d.lastKeptMs["dib"] = now - 10 * 60_000
      d.addSetAside(sender: "DIB", bank: "dib", kind: .oneTimeCode, atMs: now)
      d.addSetAside(sender: "DIB", bank: "dib", kind: .promotion, atMs: now)
    }
    l.reload()
    #expect(l.status == .working(lastRan: Self.t0.addingTimeInterval(-240)))
    #expect(l.banks.first { $0.bank == .dib }?.lastText == Self.t0.addingTimeInterval(-600))
    #expect(l.setAside == [BankTextsSetAside(sender: "DIB", bank: .dib, counts: [.oneTimeCode: 1, .promotion: 1])])
    #expect(BankTexts.setAsideDetail(l.setAside[0]) == "2 texts set aside in the last 30 days\n1 one-time code, 1 promotion")
    #expect(BankTexts.setAsideDetail(BankTextsSetAside(sender: "DIB", bank: .dib, counts: [.promotion: 1_284]))
      == "1,284 texts set aside in the last 30 days\n1,284 promotions")
    let zero = BankTextsSetAside(sender: "DIB", bank: .dib, counts: [.promotion: 0])
    #expect(BankTexts.setAsideRows([zero, l.setAside[0]]) == [l.setAside[0]])
    #expect(BankTexts.ignoredLine(12_840)?.hasPrefix("12,840 texts") == true)
    #expect(l.sawAutomationRun)
  }

  @Test func theCopyForIgnoredTextsAndTheDisconnectAlert() {
    #expect(
      BankTexts.ignoredLine(3)
        == "3 texts that look like payments were ignored in the last 30 days because this account reads bank email.")
    let mock = MockBankTexts()
    #expect(!mock.sawAutomationRun)
    mock.ignoredLast30Days = 1
    #expect(mock.sawAutomationRun)
  }
}

nonisolated final class LockedNoSecretStore: SecretStore {
  func read(_ item: SecretItem) throws(SecretStoreError) -> Data? {
    if item == .textKeySecret { return nil }
    throw .notNow(status: -25308)
  }

  func write(_ item: SecretItem, _ value: Data) throws(SecretStoreError) { throw .notNow(status: -25308) }

  func delete(_ item: SecretItem) throws(SecretStoreError) { throw .notNow(status: -25308) }
}
