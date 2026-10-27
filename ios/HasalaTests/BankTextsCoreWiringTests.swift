import CoreAuth
import CoreMailbox
import CoreOutbox
import CorePrimitives
import CoreProjection
import CoreReplay
import CoreStore
import CoreSync
import CoreTime
import CoreWire
import Foundation
import HasalaModels
import Synchronization
import Testing

@testable import Hasala

nonisolated final class CountingOffline: Transport {
  private let n = Mutex(0)

  var requests: Int { n.withLock { $0 } }

  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    n.withLock { $0 += 1 }
    throw .offline(.notConnectedToInternet)
  }
}

nonisolated final class CoreTextAccount: BankTextAccount {
  let author: any BankTextsAuthoring
  let answer: Bool?
  private let count = Mutex(0)

  init(author: any BankTextsAuthoring, answer: Bool?) {
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
@Suite("Bank texts: the intent and the lane on the real reader and author")
struct BankTextsCoreWiringTests {
  nonisolated struct FixedClock: CoreTime.Clock {
    let ms: Int64
    func nowMs() -> Int64 { ms }
  }

  nonisolated static let t0 = Date(timeIntervalSince1970: 1_780_646_400)
  static let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
  static let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
  static let purchase =
    "مشتريات بمبلغ 123.45 من بطاقة XX1234 في 05-06-2026 10:11 من SAMPLE SHOP. الحد الائتماني المتاح 1,234.56"
  static let code =
    "482913 هو OTP للمشتريات من example.com SYNTHETIC SHOP بمبلغ 20.00 AED على بطاقتك 1234 لا تشارك مع أي شخص. اتصل على 80000000+ في حال لم تقم بالمعاملة ."
  static let chat = "SYNTHETIC see you at 8 tonight"
  static let undated = "SYNTHETIC purchase of AED 50.00 at SAMPLE SHOP"

  final class Rig {
    let store: CoreStore.LedgerStore
    let observer: LedgerPageObserver
    let ledger: RuntimeMailboxLedger
    let authoring: CoreBankTextAuthoring
    let transport: CountingOffline
    let facts: BankTextsFacts
    let marker: LockedTextsMarkerFile
    let secrets: MemorySecretStore
    let account: CoreTextAccount
    var opened = 0

    init(answer: Bool?) throws {
      let s = try CoreStore.LedgerStore.inMemory()
      try s.create(
        StoreMeta(
          userID: BankTextsCoreWiringTests.user, writerID: BankTextsCoreWiringTests.writer, apiBase: "https://api.hasala.app",
          keyEpoch: 1, createdAt: 1))
      store = s
      let clock = FixedClock(ms: BankTextIntake.ms(BankTextsCoreWiringTests.t0))
      transport = CountingOffline()
      let context = SyncContext(
        userID: BankTextsCoreWiringTests.user, writerID: BankTextsCoreWiringTests.writer, store: s,
        secrets: Secrets(store: MemorySecretStore(), apiHost: "api.hasala.app"), client: AuthClient(transport: transport),
        clock: clock, random: SystemRandom())
      let projection = try ProjectionStore.inMemory()
      observer = LedgerPageObserver(context: context, projection: projection, dictionary: AccountRuntime.dictionary)
      let outbox = Outbox(store: s, clock: clock, debounce: .seconds(3600), onAuthored: {})
      ledger = RuntimeMailboxLedger(
        engine: SyncEngine(context: context, observer: observer), observer: observer, outbox: outbox,
        authoring: MailboxAuthoring(observer: observer))
      authoring = CoreBankTextAuthoring(
        ledger: ledger, reader: projection.reader,
        categorizer: PipelineCategorizer(projection: projection, dictionary: AccountRuntime.dictionary))
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("texts-core-\(UUID().uuidString)")
      facts = BankTextsFacts(directory: dir.appendingPathComponent("facts"))
      marker = LockedTextsMarkerFile(directory: dir.appendingPathComponent("marker"))
      secrets = MemorySecretStore()
      account = CoreTextAccount(author: authoring, answer: answer)
    }

    var reader: CoreBankTextReader { CoreBankTextReader(now: { BankTextsCoreWiringTests.t0 }) }

    func intake() -> BankTextIntake {
      BankTextIntake(
        BankTextIntakeDeps(
          reader: reader, facts: facts, marker: marker, secret: TextKeySecret(store: secrets), signIn: { .signedIn },
          account: { [unowned self] in
            opened += 1
            return account
          }, linkBudget: .milliseconds(200)))
    }

    func lane() -> LiveBankTexts {
      let authoring = authoring
      let secrets = secrets
      return LiveBankTexts(
        facts: facts, marker: marker, reader: reader, author: { authoring },
        secret: { TextKeySecret(store: secrets) }, now: { BankTextsCoreWiringTests.t0 })
    }

    func note(linked: Bool) {
      BankTextsLinkCopy.note(linked: linked, facts: facts, nowMs: BankTextIntake.ms(BankTextsCoreWiringTests.t0) - 60_000)
    }

    func ingests() throws -> [Op] {
      try store.pendingOps().compactMap { p in
        var blob = Data(#"{"v":4,"kind":"ops","ops":["#.utf8)
        blob.append(p.opJSON)
        blob.append(contentsOf: Array("]}".utf8))
        return try OpCodec.decodeBlobOps(blob).first
      }.filter { $0.type == .txnIngested }
    }

    func pendingJSON() throws -> [String] {
      try store.pendingOps().map { String(decoding: $0.opJSON, as: UTF8.self) }
    }
  }

  @Test func aDIBTextRunsThroughTheIntentIntoTheOutbox() async throws {
    let r = try Rig(answer: nil)
    r.note(linked: false)
    #expect(await r.intake().run(Self.purchase, sender: "DIB-SMS", at: Self.t0) == .authored(filed: false))
    #expect(r.opened == 1 && r.account.asks == 0)
    let ops = try r.ingests()
    try #require(ops.count == 1)
    let p = try #require(ops[0].payload.objectValue)
    #expect(p["channel"]?.stringValue == "sms" && p["bank"]?.stringValue == "dib")
    #expect(p["amount_minor"]?.stringValue == "12345" && p["currency"]?.stringValue == "AED")
    #expect(p["merchant_raw"]?.stringValue == "SAMPLE SHOP" && p["last4"]?.stringValue == "1234")
    #expect(p["needs_review"]?.boolValue == true)
    #expect(p["gates"]?.objectValue?["card"]?.stringValue == "unknown")
    #expect(ops[0].ingestID?.utf8.count == 64)
    for json in try r.pendingJSON() {
      #expect(!json.contains("الحد الائتماني") && !json.contains("DIB-SMS"))
    }
    let data = r.facts.read(nowMs: BankTextIntake.ms(Self.t0))
    #expect(data.lastKeptMs["dib"] == BankTextIntake.ms(Self.t0) && data.lastRunMs == BankTextIntake.ms(Self.t0))
    #expect(r.transport.requests == 0)
  }

  @Test func aDIBTextOnAKnownCardFiles() async throws {
    let r = try Rig(answer: nil)
    r.note(linked: false)
    try await r.ledger.authorCards([CardDecision(card: CardKey(bank: "dib", last4: "1234"), state: .mine)])
    #expect(await r.intake().run(Self.purchase, sender: "DIB-SMS", at: Self.t0) == .authored(filed: true))
    let p = try #require(try r.ingests().first?.payload.objectValue)
    #expect(p["needs_review"]?.boolValue == false && p["gates"]?.objectValue?["card"]?.stringValue == "known")
  }

  @Test func withNoCopyAndNoAnswerAKnownCardTextWaitsInReview() async throws {
    let r = try Rig(answer: nil)
    try await r.ledger.authorCards([CardDecision(card: CardKey(bank: "dib", last4: "1234"), state: .mine)])
    #expect(await r.intake().run(Self.purchase, sender: "DIB-SMS", at: Self.t0) == .authored(filed: false))
    #expect(r.account.asks == 1)
    let p = try #require(try r.ingests().first?.payload.objectValue)
    #expect(p["needs_review"]?.boolValue == true)
  }

  @Test func aDroppedTextLeavesNoOpAndNoRequest() async throws {
    let r = try Rig(answer: false)
    let intake = r.intake()
    let before = try r.store.pendingOps().count
    #expect(await intake.run(Self.code, sender: "DIB-SMS", at: Self.t0) == .dropped(counted: true))
    #expect(await intake.run(Self.chat, sender: "+971500000000", at: Self.t0) == .dropped(counted: false))
    #expect(await intake.run(Self.chat, sender: nil, at: Self.t0) == .dropped(counted: false))
    let after = try r.store.pendingOps().count
    let ingests = try r.ingests()
    #expect(after == before && ingests.isEmpty)
    #expect(r.opened == 0 && r.account.asks == 0 && r.transport.requests == 0)
    let data = r.facts.read(nowMs: BankTextIntake.ms(Self.t0))
    #expect(data.setAsideRecent(nowMs: BankTextIntake.ms(Self.t0)).map(\.count) == [1])
    #expect(data.setAsideRecent(nowMs: BankTextIntake.ms(Self.t0)).first?.kind == .oneTimeCode)
    #expect(data.link == nil && data.lastKeptMs.isEmpty)
    #expect(try r.secrets.read(.textKeySecret) == nil)
  }

  @Test func aLinkedCopyAuthorsNothing() async throws {
    let r = try Rig(answer: nil)
    r.note(linked: true)
    #expect(await r.intake().run(Self.purchase, sender: "DIB-SMS", at: Self.t0) == .ignored(counted: true))
    let ingests = try r.ingests()
    #expect(ingests.isEmpty && r.opened == 0)
  }

  @Test func theRealReaderSortsSendersAndDates() {
    let reader = CoreBankTextReader(now: { Self.t0 })
    guard case .keep(let kept) = reader.readPaste(Self.purchase, pastedAt: Self.t0) else {
      Issue.record("the purchase was not kept")
      return
    }
    #expect(kept.mayBeBanks && kept.fields.bank == "dib" && kept.fields.amount == .aed(12_345))
    #expect(kept.fields.direction == .out && kept.fields.cardEnding == "1234" && kept.fields.merchant == "SAMPLE SHOP")
    #expect(kept.fields.postedAt == Date(timeIntervalSince1970: 1_780_639_860))
    guard case .keep(let loose) = reader.readPaste(Self.undated, pastedAt: Self.t0) else {
      Issue.record("the undated payment was not kept")
      return
    }
    #expect(loose.fields.postedAt == nil && loose.fields.amount == .aed(5_000))
    #expect(reader.read(Self.code, sender: "DIB-SMS", testWindowOpen: false)
      == .drop(.oneTimeCode, setAsideSender: "DIB-SMS", bank: "dib"))
    #expect(reader.read(Self.code, sender: nil, testWindowOpen: false) == .drop(.oneTimeCode, setAsideSender: nil, bank: nil))
    #expect(reader.read("hasala test", sender: nil, testWindowOpen: true) == .setUpTest)
    guard case .keep(let personal) = reader.read("SYNTHETIC I sent you AED 50", sender: "+971500000000", testWindowOpen: false)
    else {
      Issue.record("the person's payment text was not kept")
      return
    }
    #expect(!personal.mayBeBanks)
  }

  @Test func pasteFindsTheTextRowAndAddsForReview() async throws {
    let r = try Rig(answer: nil)
    r.note(linked: false)
    #expect(await r.intake().run(Self.purchase, sender: "DIB-SMS", at: Self.t0) == .authored(filed: false))
    let first = try #require(try r.ingests().first?.entity?.id)
    let lane = r.lane()
    let match = try #require(await lane.match(Self.purchase))
    #expect(match.rowID == first && match.kind == .payment && match.fromText)
    try await lane.addToReview(Self.purchase, replacing: match)
    let ops = try r.ingests()
    #expect(ops.count == 2)
    let p = try #require(ops.last?.payload.objectValue)
    #expect(p["needs_review"]?.boolValue == true && p["channel"]?.stringValue == "sms")
    #expect(ops[0].ingestID != ops[1].ingestID)
  }

  @Test func theUnwiredFakeStillFailsLoudly() async {
    let core = UnwiredBankTextsCore()
    await #expect(throws: BankTextsCoreFailure.unavailable) {
      try await core.author(
        Self.purchase, sender: nil, reading: KeptBankText(fields: BankTextFields(), mayBeBanks: true), arrivedAt: Self.t0,
        secret: Data(count: 32), link: .notLinked, origin: .automation)
    }
  }
}
