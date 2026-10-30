// Unit tests for CoreStore (owner: WS-11): the §4.2 schema, each §5
// transaction boundary, the §4.4 item formats and the §4.1 file hygiene.
import CorePrimitives
import CoreWire
import Foundation
import GRDB
import Testing

@testable import CoreStore

let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
let other = WriterID("ios-1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!

func created() throws -> LedgerStore {
  let s = try LedgerStore.inMemory()
  try s.create(StoreMeta(userID: user, writerID: writer, apiBase: "https://api.hasala.app", keyEpoch: 1, createdAt: 1),
    logGeneration: 3)
  return s
}

func h(_ b: UInt8) -> Hash32 { Hash32(Data(repeating: b, count: 32))! }

@Suite("CoreStore: ledger.sqlite")
struct LedgerStoreTests {
  @Test("migration v1 creates every §4.2 table")
  func schema() throws {
    let s = try LedgerStore.inMemory()
    let tables = try s.db.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'")
    }
    for t in [
      "store_meta", "wire_rows", "chain_heads", "sync_state", "pending_ops", "inflight_blobs", "fold_snapshot",
      "fold_events", "mailbox_state", "mailbox_accounted", "mailbox_set_aside", "mailbox_unreadable", "mailbox_staging",
      "bank_health", "search_recent", "notification_ledger", "security_cursor", "onboarding_draft",
    ] {
      #expect(tables.contains(t), "missing \(t)")
    }
    #expect(try s.db.read { db in try String.fetchOne(db, sql: "PRAGMA secure_delete") } == "1")
  }

  @Test("create: one meta row and a genesis sync state")
  func create() throws {
    let s = try created()
    #expect(try s.meta()?.writerID == writer)
    let st = try s.syncState()
    #expect(st.cursorHot == 0 && st.authoredHead == .genesis && st.epochHWM == 1 && st.logGeneration == 3)
    #expect(st.latch == nil)
    #expect(throws: StoreError.self) {
      try s.create(StoreMeta(userID: user, writerID: writer, apiBase: "x", keyEpoch: 1, createdAt: 1))
    }
  }

  @Test("the writer id CHECK refuses a non-ios writer")
  func writerCheck() throws {
    let s = try LedgerStore.inMemory()
    #expect(throws: (any Error).self) {
      try s.db.write { db in
        try db.execute(
          sql: "INSERT INTO store_meta VALUES (1, 1, 'u', 'pwa-x', 'b', 1, 0)")
      }
    }
  }

  @Test("persistPage stores rows, heads and the cursor together; ingest rows are refused")
  func page() throws {
    let s = try created()
    let rows = [
      WireRowRecord(
        seq: 1, writerID: other, counter: 1, sizeBucket: 1024, blobHash: h(1), prevHash: .zero, createdAt: "t",
        blob: Data(count: 1024), headSig: nil, disposition: .folded),
      WireRowRecord(
        seq: 2, writerID: other, counter: 2, sizeBucket: 1024, blobHash: h(2), prevHash: h(1), createdAt: "t",
        blob: Data(count: 1024), headSig: Data(count: 64), disposition: .alarm),
    ]
    try s.persistPage(rows: rows, heads: [other: Chain.Head(counter: 2, hash: h(2))], cursor: 2, at: 9)
    #expect(try s.syncState().cursorHot == 2)
    #expect(try s.syncState().lastPullAt == 9)
    #expect(try s.chainHeads()[other] == Chain.Head(counter: 2, hash: h(2)))
    #expect(try s.wireRows().map(\.disposition) == [.folded, .alarm])
    // A duplicate (writer, counter) rolls the whole page back.
    let dup = WireRowRecord(
      seq: 3, writerID: other, counter: 2, sizeBucket: 1024, blobHash: h(3), prevHash: h(2), createdAt: "t",
      blob: Data(count: 1024), headSig: nil, disposition: .folded)
    #expect(throws: StoreError.self) { try s.persistPage(rows: [dup], heads: [:], cursor: 3, at: 10) }
    #expect(try s.syncState().cursorHot == 2)
  }

  @Test("pending ops → one batch in flight → acknowledged: ops and blobs leave, the head moves")
  func outboxCycle() throws {
    let s = try created()
    try s.enqueue((1...3).map {
      PendingOp(opID: "op\($0)", opJSON: Data("{}".utf8), opType: "home_currency_set", entityKind: nil, entityID: nil,
        enqueuedAt: 0)
    })
    #expect(try s.pendingCount() == 3)
    #expect(try s.pendingOps().map(\.opID) == ["op1", "op2", "op3"])
    let batch = [
      InflightBlob(counter: 1, batchID: "B", prevHash: .zero, blobHash: h(1), sizeBucket: 1024, blob: Data(count: 1024),
        opIDs: ["op1", "op2"], headSig: nil, createdAt: 0),
      InflightBlob(counter: 2, batchID: "B", prevHash: h(1), blobHash: h(2), sizeBucket: 1024, blob: Data(count: 1024),
        opIDs: ["op3"], headSig: Data(repeating: 5, count: 64), createdAt: 0),
    ]
    try s.persistBatch(batch)
    #expect(try s.inflight() == batch)
    #expect(throws: StoreError.batchInFlight) { try s.persistBatch(batch) }
    // A partial acknowledgement (409 conflict) keeps the rest.
    try s.acknowledge(counters: [1], head: Chain.Head(counter: 1, hash: h(1)), at: 5)
    #expect(try s.inflight().map(\.counter) == [2])
    #expect(try s.pendingOps().map(\.opID) == ["op3"])
    #expect(try s.syncState().authoredHead == Chain.Head(counter: 1, hash: h(1)))
    try s.acknowledge(counters: [2], head: Chain.Head(counter: 2, hash: h(2)), at: 6)
    #expect(try s.inflight().isEmpty && s.pendingCount() == 0)
    #expect(try s.syncState().authoredHead == Chain.Head(counter: 2, hash: h(2)))
    #expect(try s.syncState().lastPushAt == 6)

    // A batch sealed from a stale read is refused inside the transaction:
    // it must continue the authored head and carry only pending ops.
    try s.enqueue([
      PendingOp(opID: "op4", opJSON: Data("{}".utf8), opType: "home_currency_set", entityKind: nil, entityID: nil,
        enqueuedAt: 0)
    ])
    func blob(_ c: Int64, prev: Hash32, ids: [String]) -> InflightBlob {
      InflightBlob(counter: c, batchID: "C", prevHash: prev, blobHash: h(UInt8(c)), sizeBucket: 1024,
        blob: Data(count: 1024), opIDs: ids, headSig: Data(repeating: 5, count: 64), createdAt: 0)
    }
    #expect(throws: StoreError.staleBatch) { try s.persistBatch([blob(2, prev: h(1), ids: ["op4"])]) }  // re-uses counter 2
    #expect(throws: StoreError.staleBatch) { try s.persistBatch([blob(3, prev: h(1), ids: ["op4"])]) }  // wrong prev
    #expect(throws: StoreError.staleBatch) { try s.persistBatch([blob(3, prev: h(2), ids: ["op3"])]) }  // op3 acked
    #expect(throws: StoreError.staleBatch) {
      try s.persistBatch([blob(3, prev: h(2), ids: ["op4"]), blob(5, prev: h(3), ids: [])])  // a gap
    }
    #expect(throws: StoreError.staleBatch) { try s.persistBatch([]) }
    #expect(try s.inflight().isEmpty)
    try s.persistBatch([blob(3, prev: h(2), ids: ["op4"])])
    #expect(try s.inflight().map(\.counter) == [3])
    // An older acknowledgement never moves the head back.
    try s.acknowledge(counters: [], head: Chain.Head(counter: 1, hash: h(1)), at: 7)
    #expect(try s.syncState().authoredHead.counter == 2)
  }

  @Test("latch, epoch high-water mark (never lowered), roster and fold-event ring")
  func state() throws {
    let s = try created()
    try s.setLatch(.accountFull)
    #expect(try s.syncState().latch == .accountFull)
    try s.setEpochHWM(3)
    try s.setEpochHWM(2)
    #expect(try s.syncState().epochHWM == 3)
    try s.setRoster(Data("{}".utf8))
    #expect(try s.syncState().rosterJSON == Data("{}".utf8))
    for i in 0..<70 { try s.recordFoldEvent(kind: "k", detail: "\(i)", at: Int64(i)) }
    let ev = try s.foldEvents()
    #expect(ev.count == 64 && ev.last?.detail == "69")
  }

  @Test("open(directory:) protects and excludes the directory and the database files")
  func files() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hasala-store-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = try LedgerStore.open(directory: dir)
    try s.create(StoreMeta(userID: user, writerID: writer, apiBase: "b", keyEpoch: 1, createdAt: 0))
    #expect(FileHygiene.isExcluded(dir))
    #expect(FileHygiene.isExcluded(dir.appendingPathComponent("ledger.sqlite")))
    let again = try LedgerStore.open(directory: dir)
    #expect(try again.meta()?.userID == user)
  }
}

@Suite("CoreStore: secrets")
struct SecretTests {
  @Test("§4.4's mapping: services, accounts, accessibility")
  func mapping() {
    #expect(SecretItem.session(apiHost: "api.hasala.app").service == "app.hasala.session")
    #expect(SecretItem.session(apiHost: "api.hasala.app").account == "api.hasala.app")
    #expect(SecretItem.epochKey(userID: user, epoch: 1).account == "\(user.string):1")
    #expect(SecretItem.writerKey(userID: user, writerID: writer).account == "\(user.string):\(writer.string)")
    #expect(SecretItem.approvalKey(userID: user, writerID: writer).accessibility == .whenPasscodeSetThisDeviceOnly)
    #expect(SecretItem.writerKey(userID: user, writerID: writer).accessibility == .afterFirstUnlockThisDeviceOnly)
    #expect(SecretItem.allServices.count == 10)
    #expect(SecretItem.readerWordKey.service == "app.hasala.reader-key")
    #expect(SecretItem.readerWordKey.accessibility == .afterFirstUnlockThisDeviceOnly)
    #expect(SecretItem.textKeySecret.service == "app.hasala.text-key")
    #expect(SecretItem.textKeySecret.accessibility == .afterFirstUnlockThisDeviceOnly)
    // The Gmail item keeps its pre-provider service, so existing links need no migration.
    #expect(SecretItem.gmailRefresh(userID: user) == .mailRefresh(provider: .gmail, userID: user))
    #expect(SecretItem.mailRefresh(provider: .gmail, userID: user).service == "app.hasala.gmail.refresh")
    #expect(SecretItem.mailRefresh(provider: .outlook, userID: user).service == "app.hasala.outlook.refresh")
    #expect(SecretItem.outlookClientState(userID: user).service == "app.hasala.outlook.clientstate")
    #expect(SecretItem.outlookClientState(userID: user).account == user.string)
    let items: [SecretItem] =
      MailSecretProvider.allCases.map { .mailRefresh(provider: $0, userID: user) } + [.outlookClientState(userID: user), .textKeySecret, .readerWordKey]
    for item in items { #expect(SecretItem.allServices.contains(item.service)) }
  }

  @Test("session and binding round-trip with §4.4's JSON keys")
  func records() throws {
    let m = MemorySecretStore()
    let s = Secrets(store: m, apiHost: "api.hasala.app")
    let rec = try SessionRecord.minted(token: "tok", userID: user.string, expiresAt: 42, random: SystemRandom())
    try s.writeSession(rec)
    #expect(try s.session() == rec)
    #expect(rec.tag.count == 16)
    let raw = try #require(try m.read(.session(apiHost: "api.hasala.app")))
    let keys = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any]).keys
    #expect(Set(keys) == ["token", "user_id", "pending_logout", "expires_at", "tag"])
    let b = AccountBinding(
      userID: user, writerID: writer, apiBase: "https://api.hasala.app", keyEpoch: 1, emailNorm: "m@example.com",
      serverSalt: Data(repeating: 1, count: 32), displayName: "Maya")
    try s.writeBinding(b)
    #expect(try s.binding() == b)
    #expect(b.serverSalt == Data(repeating: 1, count: 32))
  }

  @Test("the writer key is [0x01][seed32]; anything else is refused")
  func writerKey() throws {
    let m = MemorySecretStore()
    let s = Secrets(store: m, apiHost: "h")
    try s.writeWriterSeed(Data(repeating: 7, count: 32), userID: user, writerID: writer)
    #expect(try m.read(.writerKey(userID: user, writerID: writer)) == Data([1]) + Data(repeating: 7, count: 32))
    #expect(try s.writerSeed(userID: user, writerID: writer).map { $0.withUnsafeBytes { Data($0) } } == Data(repeating: 7, count: 32))
    try m.write(.writerKey(userID: user, writerID: writer), Data([2]) + Data(repeating: 7, count: 32))
    #expect(throws: SecretStoreError.self) { _ = try s.writerSeed(userID: user, writerID: writer) }
  }

  @Test("locked: reads throw 'not now', never nil; wipe removes every item")
  func locked() throws {
    let m = MemorySecretStore()
    let s = Secrets(store: m, apiHost: "h")
    try s.writeEpochKey(Data(count: 32), userID: user, epoch: 1)
    m.locked = true
    #expect(throws: SecretStoreError.self) { _ = try s.epochKey(userID: user, epoch: 1) }
    m.locked = false
    try s.writeWriterSeed(Data(count: 32), userID: user, writerID: writer)
    for p in MailSecretProvider.allCases { try m.write(.mailRefresh(provider: p, userID: user), Data("t".utf8)) }
    try m.write(.outlookClientState(userID: user), Data("c".utf8))
    try m.write(.textKeySecret, Data(repeating: 9, count: 32))
    try m.write(.readerWordKey, Data(repeating: 8, count: 32))
    try s.wipeAccount(userID: user, writerID: writer)
    #expect(m.count == 0)
  }

  struct RefusesApprovalKey: SecretStore {
    let inner: MemorySecretStore
    func read(_ item: SecretItem) throws(SecretStoreError) -> Data? { try inner.read(item) }
    func write(_ item: SecretItem, _ value: Data) throws(SecretStoreError) { try inner.write(item, value) }
    func delete(_ item: SecretItem) throws(SecretStoreError) {
      if case .approvalKey = item { throw .notNow(status: -25308) }
      try inner.delete(item)
    }
  }

  @Test("a refused delete does not stop the wipe: every other item goes, and the refusal is reported")
  func wipeContinuesPastARefusal() throws {
    let m = MemorySecretStore()
    let s = Secrets(store: RefusesApprovalKey(inner: m), apiHost: "h")
    try s.writeEpochKey(Data(count: 32), userID: user, epoch: 1)
    try s.writeWriterSeed(Data(count: 32), userID: user, writerID: writer)
    try m.write(.approvalKey(userID: user, writerID: writer), Data("k".utf8))
    for p in MailSecretProvider.allCases { try m.write(.mailRefresh(provider: p, userID: user), Data("t".utf8)) }
    try m.write(.outlookClientState(userID: user), Data("c".utf8))
    try m.write(.textKeySecret, Data(repeating: 9, count: 32))
    #expect(throws: SecretStoreError.notNow(status: -25308)) { try s.wipeAccount(userID: user, writerID: writer) }
    for p in MailSecretProvider.allCases { #expect(try m.read(.mailRefresh(provider: p, userID: user)) == nil) }
    #expect(try m.read(.outlookClientState(userID: user)) == nil)
    #expect(try m.read(.textKeySecret) == nil)
    #expect(try s.epochKey(userID: user, epoch: 1) == nil)
    #expect(m.count == 1)
  }
}
