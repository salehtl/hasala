// LedgerPageObserver alone (spec 04 §5.2 steps 4-5, §5.3): pages folded on a
// copy and committed with their snapshot, projection once per pull, warm
// starts from the snapshot, abandoned and refused pages, the outbox overlay and
// the author context. The full pull path (real sealed rows, the cold re-fold,
// two iPhones) runs in HasalaCoreE2ETests against FakeServer.
import CoreDomain
import CoreJSON
import CoreProjection
import CoreReplay
import CoreTestSupport
import Foundation
import Testing

@testable import CoreSync

@Suite("CoreSync: LedgerPageObserver")
struct LedgerPageObserverTests {
  static let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
  static let me = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
  static let peer = WriterID("ios-1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
  static let now: Int64 = 1_791_625_200_000

  /// No server: these tests never reach the network.
  struct Unreachable: Transport {
    func send(_ request: APIRequest) async throws(TransportError) -> APIResponse { throw .offline(.notConnectedToInternet) }
  }

  struct Rig {
    let store: LedgerStore
    let context: SyncContext
    let projection: ProjectionStore
    let observer: LedgerPageObserver

    init(store: LedgerStore? = nil, projection: ProjectionStore? = nil) throws {
      let s: LedgerStore
      if let store {
        s = store
      } else {
        s = try LedgerStore.inMemory()
        try s.create(StoreMeta(userID: LedgerPageObserverTests.user, writerID: LedgerPageObserverTests.me, apiBase: "b", keyEpoch: 1, createdAt: 1))
      }
      self.store = s
      context = SyncContext(
        userID: LedgerPageObserverTests.user, writerID: LedgerPageObserverTests.me, store: s,
        secrets: Secrets(store: MemorySecretStore(), apiHost: "api.hasala.app"), client: AuthClient(transport: Unreachable()),
        clock: FakeClock(ms: LedgerPageObserverTests.now), random: SeededRandom())
      self.projection = try projection ?? ProjectionStore.inMemory()
      observer = LedgerPageObserver(context: context, projection: self.projection, dictionary: .empty)
    }

    /// What the Puller does with one decided page: fold, persist with the snapshot, commit, end the pull.
    func page(_ blobs: [(seq: Int64, ops: [Op])], counterBase: Int64) async throws {
      var rows: [PulledRow] = []
      var records: [WireRowRecord] = []
      for (i, b) in blobs.enumerated() {
        let c = counterBase + Int64(i)
        rows.append(PulledRow(seq: b.seq, writerID: peer, counter: c, outcome: .opened(plaintext: Data(), ops: b.ops)))
        records.append(
          WireRowRecord(
            seq: b.seq, writerID: peer, counter: c, sizeBucket: 1024, blobHash: Hash32.of(Data([UInt8(b.seq)])), prevHash: .zero,
            createdAt: "t", blob: Data(count: 1024), headSig: nil, disposition: .folded))
      }
      let change = try await observer.fold(rows)
      try store.persistPage(rows: records, heads: [:], cursor: blobs.last!.seq, at: 1, snapshot: change)
      await observer.pageCommitted()
      await observer.pullEnded()
    }
  }

  static func ingest(_ merchant: String, _ amount: Int64, at ms: Int64 = now, writer: WriterID = peer) throws -> [Op] {
    var a = OpAuthor(AuthorContext(writerID: writer.string, nowMs: ms, ownLastMs: nil, maxAuthored: [:], random: SeededRandom(seed: merchant)))
    try a.ingest(
      payload: JSONObject([
        ("amount_minor", .string(String(amount))), ("currency", .string("AED")), ("direction", .string("debit")),
        ("posted_at", .string(Instant.iso(ms)!)), ("merchant_raw", .string(merchant)), ("last4", .string("4412")),
        ("needs_review", .bool(true)), ("entry_method", .string("manual")),
      ]), ingestID: Hex.encode(sha256(Data(merchant.utf8))))
    return try a.build().ops
  }

  static func setup() throws -> [Op] {
    var a = OpAuthor(AuthorContext(writerID: peer.string, nowMs: now - 1000, ownLastMs: nil, maxAuthored: [:], random: SeededRandom()))
    a.setHomeCurrency("AED")
    return try a.build().ops
  }

  static func canonical(_ op: Op) throws -> Data {
    let doc = try JSONParser.parse(try OpCodec.encodeBlobOps([op]))
    return Data(JSONWriter().bytes(doc["ops"]!.arrayValue![0]))
  }

  @Test("open on a fresh store: an empty, complete projection at cursor 0")
  func openFresh() async throws {
    let r = try Rig()
    try await r.observer.open()
    #expect(try r.projection.reader.isUsable())
    #expect(try r.projection.reader.meta()?.cursorHot == 0)
    #expect(try r.projection.reader.activity().isEmpty)
    #expect(try await r.observer.currentState() == State())
  }

  @Test("pages fold onto the state, commit with their snapshot, and project once the pull ends")
  func foldAndProject() async throws {
    let r = try Rig()
    try await r.observer.open()
    try await r.page([(1, try Self.setup()), (2, try Self.ingest("CARREFOUR", 34_215))], counterBase: 1)
    try await r.page([(3, try Self.ingest("TALABAT", 6_450, at: Self.now + 5))], counterBase: 3)
    let s = try await r.observer.currentState()
    #expect(s.cursors.hot == 3 && s.txns.count == 2 && s.homeCurrency == "AED")
    let snap = try #require(try r.store.foldSnapshot())
    #expect(snap.cursorHot == 3 && snap.foldPrint == FoldCanary.foldPrint)
    #expect(try SnapshotCodec.decode(snap.payload).state == s)
    #expect(try r.projection.reader.meta()?.cursorHot == 3)
    #expect(try r.projection.reader.activity().map(\.merchantRaw) == ["TALABAT", "CARREFOUR"])
    #expect(try r.projection.reader.activity().allSatisfy { $0.amountHomeMinor != nil && !$0.pending })
  }

  @Test("a second observer on the same store starts warm from the snapshot")
  func warmStart() async throws {
    let r = try Rig()
    try await r.page([(1, try Self.setup()), (2, try Self.ingest("CARREFOUR", 34_215))], counterBase: 1)
    let before = try await r.observer.currentState()
    let again = try Rig(store: r.store, projection: try ProjectionStore.inMemory())
    try await again.observer.open()
    #expect(try await again.observer.currentState() == before)
    #expect(try !r.store.foldEvents().contains { $0.kind == "cold_fold" || $0.kind == "snapshot_rejected" })
    #expect(try again.projection.reader.activity().count == 1)
  }

  @Test("an abandoned page leaves the state; a page that does not follow the state halts inconsistent")
  func abandonedAndRefused() async throws {
    let r = try Rig()
    try await r.page([(1, try Self.setup())], counterBase: 1)
    let before = try await r.observer.currentState()
    let row = PulledRow(seq: 2, writerID: Self.peer, counter: 2, outcome: .opened(plaintext: Data(), ops: try Self.ingest("NOON", 18_900)))
    _ = try await r.observer.fold([row])
    await r.observer.pageAbandoned()
    await r.observer.pullEnded()
    #expect(try await r.observer.currentState() == before)
    let stale = PulledRow(seq: 1, writerID: Self.peer, counter: 2, outcome: .opened(plaintext: Data(), ops: try Self.ingest("NOON", 18_900)))
    await #expect(throws: SyncStop.halted(.inconsistent("order"))) { try await r.observer.fold([stale]) }
    #expect(try await r.observer.currentState() == before)
  }

  @Test("a rejected snapshot cold-folds the stored rows; rows that no longer open halt, never guess")
  func coldFoldRefusesUnopenableRows() async throws {
    let r = try Rig()
    try await r.page([(1, try Self.setup())], counterBase: 1)
    try await r.store.db.write { db in try db.execute(sql: "UPDATE fold_snapshot SET fold_print = 'older semantics'") }
    let again = try Rig(store: r.store)
    await #expect(throws: SyncStop.halted(.inconsistent("cold_fold_open"))) { try await again.observer.open() }
    #expect(try r.store.foldEvents().map(\.detail).contains("fold_print"))
  }

  @Test("reproject overlays the outbox: a pending op shows as pending at once")
  func overlay() async throws {
    let r = try Rig()
    try await r.page([(1, try Self.setup())], counterBase: 1)
    let mine = try Self.ingest("STARBUCKS DIFC", 2_700, writer: Self.me)
    try r.store.enqueue(
      try mine.map { PendingOp(opID: $0.opID, opJSON: try Self.canonical($0), opType: $0.type.rawValue, entityKind: "txn", entityID: $0.entity?.id, enqueuedAt: 1) })
    try await r.observer.reproject()
    let rows = try r.projection.reader.activity()
    #expect(rows.count == 1 && rows[0].pending && rows[0].merchantRaw == "STARBUCKS DIFC")
  }

  @Test("the author context: own last stamp from the fold, the pending ops and noted blobs")
  func authorContext() async throws {
    let r = try Rig()
    try await r.page([(1, try Self.setup())], counterBase: 1)
    var ctx = try await r.observer.authorContext()
    #expect(ctx.ownLastMs == nil && ctx.maxAuthored[Self.peer.string] != nil && ctx.writerID == Self.me.string)
    let mine = try Self.ingest("VOX CINEMAS", 9_500, at: Self.now + 60_000, writer: Self.me)
    try r.store.enqueue(
      try mine.map { PendingOp(opID: $0.opID, opJSON: try Self.canonical($0), opType: $0.type.rawValue, entityKind: nil, entityID: nil, enqueuedAt: 1) })
    ctx = try await r.observer.authorContext()
    #expect(ctx.ownLastMs == (try parseInstantMs(mine[0].authoredAt)))
    var a = OpAuthor(ctx)
    a.setHomeCurrency("AED")
    let blob = try a.build()
    await r.observer.noteAuthored(blob)
    ctx = try await r.observer.authorContext()
    #expect(ctx.ownLastMs == blob.lastAuthoredMs && ctx.baseMs > blob.lastAuthoredMs)
  }
}
