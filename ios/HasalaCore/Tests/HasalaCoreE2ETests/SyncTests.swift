// Sync scenarios (spec 04 §5; spec 01 §6.6, §7.1, §8.4) against FakeServer.
import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Testing

@Suite("Sync: push, pull, resend, tamper")
struct SyncTests {
  /// Two enrolled iPhones of one account.
  func twoPhones() async throws -> (World, SyncContext, SyncContext) {
    let w = World()
    let a = w.phone("a")
    let (account, words, ctxA) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    let enrolled = try await Enrolment.enrolWriter(
      b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    // A refreshes its roster on its next pull (R1 re-fetch).
    return (w, ctxA, Enrolment.context(b.env, account: enrolled))
  }

  @Test("ops authored on A reach B: seal, sign, upload, self-pull, pull, open")
  func roundTrip() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, (1...5).map { op($0) })
    let engineA = SyncEngine(context: a)
    let out = try #require(await Optional(engineA.run(.authored)))
    #expect(out.stop == nil)
    #expect(out.pushed.opsAcknowledged == 5)
    #expect(try a.store.pendingCount() == 0)
    #expect(try a.store.inflight().isEmpty)
    let state = try a.store.syncState()
    #expect(state.authoredHead.counter == 1)
    // A's self-pull stored its own row.
    #expect(try a.store.wireRowCount() == 1)
    #expect(w.server.storedRowCount(user: a.userID) == 1)

    let engineB = SyncEngine(context: b)
    let outB = await engineB.run(.launch)
    #expect(outB.stop == nil && outB.pulled.rowsStored == 1 && outB.pulled.opsOpened == 5)
    #expect(try storedOps(b).map(\.opID) == (1...5).map { op($0).opID })
    #expect(await engineB.status.phase == .idle)
  }

  @Test("B's ops reach A after A's roster refresh (R1 re-fetch for a new writer)")
  func rosterRefresh() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(b, [op(7)])
    #expect(await SyncEngine(context: b).run(.authored).stop == nil)
    let out = await SyncEngine(context: a).run(.foreground)
    #expect(out.stop == nil)
    #expect(try storedOps(a).map(\.opID) == [op(7).opID])
  }

  @Test("many ops pack into several blobs of one batch; the pull pages never split a batch")
  func packing() async throws {
    let (w, a, b) = try await twoPhones()
    // ~70 KiB of ops → at least two blobs.
    let big = (0..<40).map { i in
      Op(
        v: 4, type: .homeCurrencySet, opID: "01J1000000000000000000\(String(format: "%04d", i))",
        authoredAt: "2026-10-11T08:00:00.000Z",
        payload: .object(JSONObject([("currency", .string(String(repeating: "A", count: 1800)))])))
    }
    try enqueue(a, big)
    let out = await SyncEngine(context: a).run(.authored)
    #expect(out.stop == nil)
    #expect(out.pushed.blobs >= 2 && out.pushed.batches == 1)
    w.server.setPullLimit(1)
    let outB = await SyncEngine(context: b).run(.launch)
    #expect(outB.stop == nil)
    #expect(try storedOps(b).count == 40)
  }

  @Test("a lost upload answer: the next run resends the identical bytes and head_sig")
  func lostResponse() async throws {
    let (w, a, _) = try await twoPhones()
    try enqueue(a, [op(1), op(2)])
    w.server.loseNextUploadResponse()
    let first = await SyncEngine(context: a).run(.authored)
    #expect(first.stop == .offline)
    let inflight = try a.store.inflight()
    #expect(inflight.count == 1 && inflight[0].headSig != nil)
    #expect(try a.store.pendingCount() == 2)
    let second = await SyncEngine(context: a).run(.foreground)
    #expect(second.stop == nil)
    #expect(try a.store.inflight().isEmpty && a.store.pendingCount() == 0)
    #expect(w.server.storedRowCount(user: a.userID) == 1)  // replayed, not appended twice
    #expect(try a.store.syncState().authoredHead.hash == inflight[0].blobHash)
  }

  @Test("409 conflict: rows the server holds are checked and acknowledged, the rest resent byte-identical")
  func partialResend() async throws {
    let (w, a, b) = try await twoPhones()
    let big = (0..<40).map { i in
      Op(
        v: 4, type: .homeCurrencySet, opID: "01J2000000000000000000\(String(format: "%04d", i))",
        authoredAt: "2026-10-11T08:00:00.000Z",
        payload: .object(JSONObject([("currency", .string(String(repeating: "B", count: 1800)))])))
    }
    try enqueue(a, big)
    w.server.partiallyApplyNextUpload(rows: 1)
    let first = await SyncEngine(context: a).run(.authored)
    #expect(first.stop == .offline)
    let second = await SyncEngine(context: a).run(.foreground)
    #expect(second.stop == nil)
    #expect(try a.store.inflight().isEmpty && a.store.pendingCount() == 0)
    _ = await SyncEngine(context: b).run(.launch)
    #expect(try storedOps(b).count == 40)
  }

  @Test("every page writer's last row must carry a valid head_sig (R2b); nothing is persisted otherwise")
  func unsignedHeads() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, [op(1)])
    _ = await SyncEngine(context: a).run(.authored)
    w.server.setDropHeadSigs(true)
    let engine = SyncEngine(context: b)
    let out = await engine.run(.launch)
    #expect(out.stop == .halted(.tampered(.headUnsigned)))
    #expect(await engine.status.phase == .halted(.tampered(.headUnsigned)))
    #expect(try b.store.wireRowCount() == 0)
    #expect(try b.store.syncState().cursorHot == 0)
  }

  @Test("a flipped blob byte breaks the chain hash: tampered(chainBreak), nothing persisted")
  func flippedByte() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, [op(1)])
    _ = await SyncEngine(context: a).run(.authored)
    w.server.flipBlobByte(atSeq: 1)
    let out = await SyncEngine(context: b).run(.launch)
    #expect(out.stop == .halted(.tampered(.chainBreak)))
    #expect(try b.store.wireRowCount() == 0)
  }

  @Test("an AEAD failure on a chain-valid, signed row is set aside with the integrity alarm; the cursor advances")
  func aeadAlarm() async throws {
    let (w, a, b) = try await twoPhones()
    // A frame sealed under a key that is not K_1, at A's next position, signed
    // by A's DWK: chain-valid and head-valid, but it does not open.
    let wrong = try EpochKey(epoch: 1, key: Data(repeating: 9, count: 32))
    let frame = try Sealer(epoch: 1, key: wrong).seal(
      plaintextOps: Data(try OpCodec.encodeBlobOps([op(1)])),
      envelope: try Envelope(userID: a.userID, writerID: a.writerID, counter: 1), prevHash: .zero,
      random: SeededRandom(seed: "x"))
    let seed = try #require(try a.secrets.writerSeed(userID: a.userID, writerID: a.writerID))
    let sig = try DWK.sign(
      seed: seed, message: SigningMessage.head(userID: a.userID, counter: 1, blobHash: frame.blobHash, writerID: a.writerID))
    w.server.injectRow(user: a.userID, writerID: a.writerID.string, counter: 1, prevHash: Data(count: 32), blob: frame.bytes, headSig: sig)
    let engine = SyncEngine(context: b)
    let out = await engine.run(.launch)
    #expect(out.stop == nil)
    #expect(out.pulled.alarms == 1)
    #expect(await engine.status.integrityAlarms == 1)
    #expect(try b.store.wireRows().first?.disposition == .alarm)
    #expect(try b.store.syncState().cursorHot == 1)
  }

  @Test("a row from a writer outside the verified roster: one re-fetch, then tampered(unknownWriter)")
  func unknownWriter() async throws {
    let (w, a, b) = try await twoPhones()
    w.server.injectRow(
      user: a.userID, writerID: "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", counter: 1, prevHash: Data(count: 32),
      blob: Data(repeating: 7, count: 1024), headSig: Data(repeating: 1, count: 64))
    let out = await SyncEngine(context: b).run(.launch)
    #expect(out.stop == .halted(.tampered(.unknownWriter)))
  }

  @Test("a row of this device's own writer it did not author: ownChainConflict")
  func ownChainConflict() async throws {
    let (w, a, _) = try await twoPhones()
    w.server.injectRow(
      user: a.userID, writerID: a.writerID.string, counter: 1, prevHash: Data(count: 32),
      blob: Data(repeating: 7, count: 1024), headSig: Data(repeating: 1, count: 64))
    let out = await SyncEngine(context: a).run(.launch)
    #expect(out.stop == .halted(.tampered(.ownChainConflict)))
  }

  @Test("the same condition after a server restore (log_generation moved) is server_restored")
  func serverRestored() async throws {
    let (w, a, _) = try await twoPhones()
    w.server.injectRow(
      user: a.userID, writerID: a.writerID.string, counter: 1, prevHash: Data(count: 32),
      blob: Data(repeating: 7, count: 1024), headSig: Data(repeating: 1, count: 64))
    w.server.setLogGeneration(2)
    let engine = SyncEngine(context: a)
    _ = await engine.run(.launch)
    #expect(await engine.status.phase == .halted(.serverRestored))
  }

  @Test("a cursor past the end of the stream halts and keeps the rows; after a restore it is server_restored")
  func cursorAhead() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, [op(1), op(2)])
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    #expect(await SyncEngine(context: b).run(.launch).stop == nil)
    let cursor = try b.store.syncState().cursorHot
    #expect(cursor == 1)
    #expect(try b.store.wireRowCount() == 1)

    w.server.loseLogTail(user: a.userID, after: 0)
    let engine = SyncEngine(context: b)
    #expect(await engine.run(.launch).stop == .halted(.tampered(.chainBreak)))
    #expect(await engine.status.phase == .halted(.tampered(.chainBreak)))
    #expect(try b.store.syncState().cursorHot == cursor)
    #expect(try b.store.wireRowCount() == 1)

    w.server.setLogGeneration(2)
    _ = await engine.run(.launch)
    #expect(await engine.status.phase == .halted(.serverRestored))
    #expect(try b.store.wireRowCount() == 1)
  }

  @Test("§5.5's table: 401, 403 writer_revoked, 413 account_full, plaintext_refused, 426, chain_break")
  func responseTable() async throws {
    let (w, a, _) = try await twoPhones()
    let engine = SyncEngine(context: a)

    w.server.refuseNext("GET /api/v1/sync", status: 401, code: "unauthorized")
    #expect(await engine.run(.launch).stop == .needsSignIn)
    #expect(await engine.status.phase == .needsSignIn)

    w.server.refuseNext("GET /api/v1/sync", status: 426, code: "upgrade_required")
    #expect(await engine.run(.launch).stop == .halted(.updateRequired))

    w.server.refuseNext("GET /api/v1/sync", status: 403, code: "account_frozen")
    #expect(await engine.run(.launch).stop == .frozen)

    w.server.refuseNext("GET /api/v1/sync", status: 429, code: "rate_limited")
    _ = await engine.run(.launch)
    #expect(await engine.status.retryAfterSeconds == 7)

    // account_full latches; reads continue; the ops stay queued.
    try enqueue(a, [op(1)])
    w.server.refuseNext("POST /api/v1/sync", status: 413, code: "account_full")
    let full = await engine.run(.authored)
    #expect(full.stop == nil)
    #expect(await engine.status.latch == .accountFull)
    #expect(try a.store.pendingCount() == 1)
    #expect(try a.store.inflight().count == 1)  // kept
    try a.store.setLatch(nil)

    w.server.refuseNext("POST /api/v1/sync", status: 400, code: "plaintext_refused", detail: "blobs[0]: tail")
    _ = await engine.run(.authored)
    #expect(await engine.status.latch == .sealerFault)
    #expect(await engine.status.integrityAlarms == 1)
    try a.store.setLatch(nil)

    w.server.refuseNext("POST /api/v1/sync", status: 409, code: "chain_break")
    let broken = await engine.run(.authored)
    #expect(broken.stop == .halted(.tampered(.ownChainConflict)))
    #expect(try a.store.syncState().latch == .chainBreak)

    w.server.revoke(user: a.userID, writer: a.writerID)
    try a.store.setLatch(nil)
    #expect(await engine.run(.launch).stop == .needsSignIn)  // the session went with the writer
  }

  @Test("account_full is a pause: it probes again on foreground, or after the pause, and the queue uploads")
  func accountFullPause() async throws {
    let (w, a, _) = try await twoPhones()
    let engine = SyncEngine(context: a)
    try enqueue(a, [op(1)])
    w.server.refuseNext("POST /api/v1/sync", status: 413, code: "account_full")
    _ = await engine.run(.authored)
    #expect(await engine.status.latch == .accountFull)
    let before = w.server.uploadCount
    _ = await engine.run(.authored)
    #expect(w.server.uploadCount == before)
    #expect(await engine.status.latch == .accountFull)
    _ = await engine.run(.foreground)
    #expect(await engine.status.latch == nil)
    #expect(try a.store.pendingCount() == 0)

    try enqueue(a, [op(2)])
    w.server.refuseNext("POST /api/v1/sync", status: 413, code: "account_full")
    _ = await engine.run(.authored)
    #expect(await engine.status.latch == .accountFull)
    let clock = try #require(a.clock as? FakeClock)
    clock.advance(ms: SyncEngine.accountFullPauseMs)
    _ = await engine.run(.authored)
    #expect(await engine.status.latch == nil)
    #expect(try a.store.pendingCount() == 0)

    try enqueue(a, [op(3)])
    w.server.refuseNext("POST /api/v1/sync", status: 413, code: "account_full")
    _ = await engine.run(.authored)
    _ = await SyncEngine(context: a).run(.silentPush)
    #expect(try a.store.syncState().latch == nil)
    #expect(try a.store.pendingCount() == 0)
  }

  @Test("ops authored while a flush runs are shown to the observer before they are sealed")
  func observerSeesEachBatch() async throws {
    let (_, a, _) = try await twoPhones()
    let observer = AuthoringObserver(inner: try Runtime(a).observer, context: a)
    try enqueue(a, [op(1)])
    _ = await SyncEngine(context: a, observer: observer).run(.authored)
    #expect(try a.store.pendingCount() == 0)
    #expect(observer.seen.contains { $0.contains(op(2).opID) })
  }

  @Test("triggers coalesce: concurrent runs make one upload")
  func coalescing() async throws {
    let (w, a, _) = try await twoPhones()
    try enqueue(a, [op(1)])
    let engine = SyncEngine(context: a)
    async let x = engine.run(.authored)
    async let y = engine.run(.foreground)
    async let z = engine.run(.pathUp)
    _ = await (x, y, z)
    #expect(w.server.uploadCount == 1)
    #expect(try a.store.pendingCount() == 0)
  }

  @Test("before first unlock every read is 'not now': the run stops quietly and stores nothing")
  func locked() async throws {
    let w = World()
    let a = w.phone("a")
    let (_, _, ctx) = try await w.passwordAccount(a)
    a.keychain.locked = true
    let out = await SyncEngine(context: ctx).run(.silentPush)
    #expect(out.stop == .notNow)
    #expect(!out.newData)
  }

  @Test("AT-SYNC-2: the resumed POST body is byte-identical to the interrupted one")
  func resumedBodyIdentical() async throws {
    let (w, a, _) = try await twoPhones()
    let rec = Recorder(inner: w.server)
    let ctx = SyncContext(
      userID: a.userID, writerID: a.writerID, store: a.store, secrets: a.secrets, client: AuthClient(transport: rec),
      clock: a.clock, random: a.random)
    try enqueue(ctx, [op(1), op(2), op(3)])
    w.server.loseNextUploadResponse()
    _ = await SyncEngine(context: ctx).run(.authored)
    _ = await SyncEngine(context: ctx).run(.foreground)
    let bodies = rec.uploads
    #expect(bodies.count == 2)
    #expect(sha256(bodies[0]) == sha256(bodies[1]))
  }

  @Test("R2b: a head signed by another key is headInvalid; a row past a revoked writer's pinned head is afterRevocation")
  func headInvalidAndAfterRevocation() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, [op(1)])
    _ = await SyncEngine(context: a).run(.authored)
    _ = await SyncEngine(context: b).run(.launch)
    // A's next row, signed by B's key: headInvalid.
    let k1 = try EpochKey(epoch: 1, key: try #require(try a.secrets.epochKey(userID: a.userID, epoch: 1)))
    let head = try #require(try a.store.chainHeads()[a.writerID])
    let frame = try Sealer(epoch: 1, key: k1).seal(
      plaintextOps: Data(try OpCodec.encodeBlobOps([op(2)])),
      envelope: try Envelope(userID: a.userID, writerID: a.writerID, counter: 2), prevHash: head.hash,
      random: SeededRandom(seed: "y"))
    let seedB = try #require(try b.secrets.writerSeed(userID: b.userID, writerID: b.writerID))
    let msg = SigningMessage.head(userID: a.userID, counter: 2, blobHash: frame.blobHash, writerID: a.writerID)
    w.server.injectRow(
      user: a.userID, writerID: a.writerID.string, counter: 2, prevHash: head.hash.bytes, blob: frame.bytes,
      headSig: try DWK.sign(seed: seedB, message: msg))
    #expect(await SyncEngine(context: b).run(.foreground).stop == .halted(.tampered(.headInvalid)))
    #expect(try b.store.syncState().cursorHot == 1)
  }

  @Test("a peer row far above the schema is set aside and the cursor moves on; the next version still halts")
  func implausibleVersionSetAside() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, [op(1)])
    _ = await SyncEngine(context: a).run(.authored)
    _ = await SyncEngine(context: b).run(.launch)
    let k1 = try EpochKey(epoch: 1, key: try #require(try a.secrets.epochKey(userID: a.userID, epoch: 1)))
    let seedA = try #require(try a.secrets.writerSeed(userID: a.userID, writerID: a.writerID))
    var prev = try #require(try a.store.chainHeads()[a.writerID]).hash
    func inject(_ counter: Int64, _ plaintext: String) throws {
      let frame = try Sealer(epoch: 1, key: k1).seal(
        plaintextOps: Data(plaintext.utf8), envelope: try Envelope(userID: a.userID, writerID: a.writerID, counter: counter),
        prevHash: prev, random: SeededRandom(seed: "v\(counter)"))
      let msg = SigningMessage.head(userID: a.userID, counter: counter, blobHash: frame.blobHash, writerID: a.writerID)
      w.server.injectRow(
        user: a.userID, writerID: a.writerID.string, counter: counter, prevHash: prev.bytes, blob: frame.bytes,
        headSig: try DWK.sign(seed: seedA, message: msg))
      prev = frame.blobHash
    }
    try inject(2, #"{"v":9007199254740991,"kind":"ops","ops":[]}"#)
    #expect(await SyncEngine(context: b).run(.foreground).stop == nil)
    #expect(try b.store.syncState().cursorHot == 2)
    let kept = try #require(try b.store.wireRows().last)
    #expect(kept.seq == 2 && kept.disposition == .setAside)
    try inject(3, #"{"v":5,"kind":"ops","ops":[]}"#)
    #expect(await SyncEngine(context: b).run(.foreground).stop == .halted(.updateRequired))
    #expect(try b.store.syncState().cursorHot == 2)
  }

  @Test("R2b: after A removes itself at counter 1, a row of A above it is afterRevocation, even signed by A")
  func afterRevocation() async throws {
    let w = World()
    let a = w.phone("a")
    let (account, words, ctxA) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    let ctxB = Enrolment.context(
      b.env,
      account: try await Enrolment.enrolWriter(
        b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt))
    try enqueue(ctxA, [op(1)])
    _ = await SyncEngine(context: ctxA).run(.authored)
    _ = await SyncEngine(context: ctxB).run(.launch)
    let seedA = try #require(try ctxA.secrets.writerSeed(userID: ctxA.userID, writerID: ctxA.writerID))
    let k1 = try EpochKey(epoch: 1, key: try #require(try ctxA.secrets.epochKey(userID: ctxA.userID, epoch: 1)))
    let head = try #require(try ctxA.store.chainHeads()[ctxA.writerID])
    try await AccountManagement.removeThisIPhone(
      a.env, engine: SyncEngine(context: ctxA), factor: .device(password: password), binding: try #require(a.binding))
    // A malicious server serves A's counter 2 anyway, correctly signed by A's DWK.
    let frame = try Sealer(epoch: 1, key: k1).seal(
      plaintextOps: Data(try OpCodec.encodeBlobOps([op(2)])),
      envelope: try Envelope(userID: ctxA.userID, writerID: ctxA.writerID, counter: 2), prevHash: head.hash,
      random: SeededRandom(seed: "z"))
    let msg = SigningMessage.head(userID: ctxA.userID, counter: 2, blobHash: frame.blobHash, writerID: ctxA.writerID)
    w.server.injectRow(
      user: ctxA.userID, writerID: ctxA.writerID.string, counter: 2, prevHash: head.hash.bytes, blob: frame.bytes,
      headSig: try DWK.sign(seed: seedA, message: msg))
    #expect(await SyncEngine(context: ctxB).run(.silentPush).stop == .halted(.tampered(.afterRevocation)))
    #expect(try storedOps(ctxB).map(\.opID) == [op(1).opID])
  }
}

/// Records upload bodies on their way to the inner transport.
final class Recorder: Transport, @unchecked Sendable {
  let inner: any Transport
  private let lock = NSLock()
  private var bodies: [Data] = []
  init(inner: any Transport) { self.inner = inner }
  var uploads: [Data] { lock.withLock { bodies } }
  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    if request.method == .post, request.path == "/api/v1/sync", let b = request.body { lock.withLock { bodies.append(b) } }
    return try await inner.send(request)
  }
}

final class AuthoringObserver: PageObserver, @unchecked Sendable {
  let inner: LedgerPageObserver
  let context: SyncContext
  private let lock = NSLock()
  private var calls = 0
  private var seenIDs: [Set<String>] = []

  init(inner: LedgerPageObserver, context: SyncContext) {
    self.inner = inner
    self.context = context
  }

  var seen: [Set<String>] { lock.withLock { seenIDs } }

  func fold(_ rows: [PulledRow]) async throws(SyncStop) -> FoldSnapshotChange { try await inner.fold(rows) }
  func pageCommitted() async { await inner.pageCommitted() }
  func pageAbandoned() async { await inner.pageAbandoned() }
  func pullEnded() async { await inner.pullEnded() }

  func willPush() async {
    let pending = Set(((try? context.store.pendingOps()) ?? []).map(\.opID))
    let n = lock.withLock {
      calls += 1
      seenIDs.append(pending)
      return calls
    }
    if n == 2 { try? enqueue(context, [op(2)]) }
    await inner.willPush()
  }
}
