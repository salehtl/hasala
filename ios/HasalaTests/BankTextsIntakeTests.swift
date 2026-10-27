import CoreMailbox
import CorePrimitives
import CoreStore
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

final class FakeTextAccount: BankTextAccount {
  let author: any BankTextsAuthoring
  var answer: Bool?
  var asks = 0

  init(author: any BankTextsAuthoring, answer: Bool? = nil) {
    self.author = author
    self.answer = answer
  }

  func askLink() async -> Bool? {
    asks += 1
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
        hasAccount: { signedIn },
        account: {
          counter.n += 1
          return account
        }, linkBudget: .milliseconds(200)))
  }

  func setCopy(_ r: Rig, linked: Bool?) {
    guard let linked else { return }
    BankTextsLinkCopy.note(linked: linked, facts: r.facts, nowMs: BankTextIntake.ms(Self.t0) - 60_000)
  }

  // MARK: One source and the link copy

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
    #expect(r.factsData.link?.linked == true)
  }

  @Test func noCopyAskedAndTheServerSaysNotLinked() async {
    let r = rig(answer: false)
    #expect(await intake(r).run(Self.payment, sender: nil, at: Self.t0) == .authored(filed: false))
    #expect(r.author.calls.map(\.link) == [.notLinked])
    #expect(r.factsData.link?.linked == false)
  }

  @Test func theCopyFollowsEveryServerAnswerAndThisDevicesDisconnect() {
    let r = rig()
    let now = BankTextIntake.ms(Self.t0)
    BankTextsLinkCopy.note(.holder(isThisDevice: false, watchExpiresAtMs: nil), facts: r.facts, nowMs: now)
    #expect(r.facts.read(nowMs: now).link == .init(linked: true, learnedAtMs: now))
    BankTextsLinkCopy.note(.noLink, facts: r.facts, nowMs: now + 1)
    #expect(r.facts.read(nowMs: now).link == .init(linked: false, learnedAtMs: now + 1))
    BankTextsLinkCopy.note(linked: true, facts: r.facts, nowMs: now + 2)
    BankTextsLinkCopy.disconnected(facts: r.facts, nowMs: now + 3)
    #expect(r.facts.read(nowMs: now).link?.linked == false)
    #expect(!r.facts.read(nowMs: now).chosen)
    _ = try? r.facts.update(nowMs: now) { $0.lastRunMs = now }
    BankTextsLinkCopy.disconnected(facts: r.facts, nowMs: now + 4)
    #expect(r.facts.read(nowMs: now).chosen)
    #expect(LiveMailboxConnecting.unlinked(.disconnected) && LiveMailboxConnecting.unlinked(.removed(2)))
    #expect(!LiveMailboxConnecting.unlinked(.otherDevice) && !LiveMailboxConnecting.unlinked(.failed))
    #expect(AccountRuntime.holdsLink(.active) && AccountRuntime.holdsLink(.otherDevice))
    #expect(AccountRuntime.holdsLink(.reconnectRequired) && !AccountRuntime.holdsLink(.unlinked))
  }

  // MARK: The intent's flow

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

  // MARK: D6

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

  // MARK: What the phone keeps

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
    let data = try r.facts.update(nowMs: now) { _ in }
    #expect(data.setAside.count == 2 && Set(data.setAside.map(\.kind)) == [.promotion, .declined])
    #expect(data.ignored.count == 1 && data.ignoredTotal(nowMs: now) == 1)
    let reloaded = BankTextsFacts(directory: r.dir.appendingPathComponent("facts")).read(nowMs: now)
    #expect(reloaded == data)
  }

  @Test func theTestWindowOpenTimeIsDeletedWhenItCloses() throws {
    let r = rig()
    let now = BankTextIntake.ms(Self.t0)
    try r.facts.update(nowMs: now) { $0.testOpenedMs = now }
    #expect(r.facts.read(nowMs: now + 9 * 60_000).testWindowOpen(nowMs: now + 9 * 60_000))
    #expect(r.facts.read(nowMs: now + 10 * 60_000).testOpenedMs == nil)
    let l = lane(r, now: Self.t0.addingTimeInterval(60))
    l.startTest()
    #expect(l.test == .waiting(since: Self.t0.addingTimeInterval(60)))
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

  // MARK: The key secret

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

  // MARK: Paste

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

  // MARK: The lane's status

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
