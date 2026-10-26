import CoreAuth
import CoreJSON
import CoreMailbox
import CoreOutbox
import CorePrimitives
import CoreProjection
import CoreReplay
import CoreStore
import CoreSync
import CoreTestSupport
import CoreWire
import Foundation
import Synchronization
import Testing

struct OfflineTransport: Transport {
  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse { throw .offline(.notConnectedToInternet) }
}

final class TextRig: Sendable {
  static let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
  static let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
  static let secret = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
  static let t0: Int64 = 1_780_646_400_000

  let store: LedgerStore
  let observer: LedgerPageObserver
  let ledger: RuntimeMailboxLedger
  let author: BankTextAuthor
  let clock: FakeClock

  init(categorizer: any IngestCategorizer = NoCategorizer(), layouts: any BankTextLayoutStore = MemoryBankTextLayouts()) throws {
    let s = try LedgerStore.inMemory()
    try s.create(StoreMeta(userID: Self.user, writerID: Self.writer, apiBase: "b", keyEpoch: 1, createdAt: 1))
    store = s
    clock = FakeClock(ms: Self.t0)
    let context = SyncContext(
      userID: Self.user, writerID: Self.writer, store: s, secrets: Secrets(store: MemorySecretStore(), apiHost: "api.hasala.app"),
      client: AuthClient(transport: OfflineTransport()), clock: clock, random: SeededRandom())
    observer = LedgerPageObserver(context: context, projection: try ProjectionStore.inMemory(), dictionary: .empty)
    let engine = SyncEngine(context: context, observer: observer)
    let outbox = Outbox(store: s, clock: clock, debounce: .seconds(3600), onAuthored: {})
    ledger = RuntimeMailboxLedger(engine: engine, observer: observer, outbox: outbox, authoring: MailboxAuthoring(observer: observer))
    author = BankTextAuthor(ledger: ledger, layouts: layouts, categorizer: categorizer)
  }

  func add(_ c: TextCase, link: BankTextLink = .notLinked, at ms: Int64? = nil) async -> BankTextOutcome {
    var a = c.arrival
    if let ms { a.receivedAtMs = ms }
    return await author.add(a, secret: Self.secret, link: { link })
  }

  func linkCard(_ bank: String, _ last4: String, _ state: CardState) async throws {
    try await ledger.authorCards([CardDecision(card: CardKey(bank: bank, last4: last4), state: state)])
  }

  func pendingOps() throws -> [Op] {
    try store.pendingOps().map { p in
      var blob = Data(#"{"v":4,"kind":"ops","ops":["#.utf8)
      blob.append(p.opJSON)
      blob.append(contentsOf: Array("]}".utf8))
      let ops = try OpCodec.decodeBlobOps(blob)
      return ops[0]
    }
  }

  func ingests() throws -> [Op] { try pendingOps().filter { $0.type == .txnIngested } }

  func payload(_ txnID: String) throws -> JSONObject {
    let op = try #require(try ingests().first { $0.entity?.id == txnID })
    return try #require(op.payload.objectValue)
  }

  func fold() throws -> State {
    var s = State()
    for (i, op) in try pendingOps().enumerated() {
      try Replay.foldOps([op], seq: Int64(i + 1), writerID: Self.writer.string, into: &s)
    }
    return s
  }

  func row(_ id: String) throws -> TxnRow? { try observer.reader.txn(id) }
}

extension BankTextOutcome {
  var added: BankTextAdded? {
    if case .added(let a) = self { return a }
    return nil
  }
}

final class LinkCalls: Sendable {
  let n = Mutex(0)
  let answer: BankTextLink
  init(_ answer: BankTextLink) { self.answer = answer }
  var count: Int { n.withLock { $0 } }
  func call() -> BankTextLink {
    n.withLock { $0 += 1 }
    return answer
  }
}
