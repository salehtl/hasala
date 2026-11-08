import CoreAuth
import CoreCrypto
import CoreJSON
import CorePrimitives
import CoreProjection
import CoreReplay
import CoreSoftAuth
import CoreTime
import CoreTestSupport
import CoreWire
import Foundation
import Testing
import os

@testable import CoreSync

final class RouteCounter: Transport, Sendable {
  let inner: any Transport
  private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

  init(_ inner: any Transport) { self.inner = inner }

  func count(_ route: String) -> Int { counts.withLock { $0[route] ?? 0 } }

  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    let route = "\(request.method.rawValue) \(request.path.split(separator: "?").first ?? "")"
    counts.withLock { $0[route, default: 0] += 1 }
    return try await inner.send(request)
  }
}

func counted(_ c: SyncContext, through server: any Transport) -> (SyncContext, RouteCounter) {
  let routes = RouteCounter(server)
  return (
    SyncContext(
      userID: c.userID, writerID: c.writerID, store: c.store, secrets: c.secrets, client: AuthClient(transport: routes), clock: c.clock,
      random: c.random),
    routes
  )
}

@Suite("Pull: the plaintext one page may hold")
struct PagePlaintextTests {
  func twoPhones() async throws -> (World, SyncContext, SyncContext) {
    let w = World()
    let a = w.phone("a")
    let (account, words, ctxA) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    let enrolled = try await Enrolment.enrolWriter(
      b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    return (w, ctxA, Enrolment.context(b.env, account: enrolled))
  }

  func alone(_ i: Int) -> Op {
    Op(
      v: 4, type: .merchantCategoryRejected, opID: "01J0000000000000000000A0\(String(format: "%02d", i))",
      authoredAt: "2026-10-11T08:00:00.000Z", payload: .object(JSONObject([("merchant", .string("SYNTHETIC")), ("category", .string("food"))])))
  }

  @Test("over budget, a pull stores what it read, then the rest; one batch may span two pulled pages")
  func shorterPages() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, (1...3).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    #expect(w.server.storedRowCount(user: a.userID) == 3)

    let out = try await Puller.pull(b, observer: nil, plaintextBudget: 1)
    #expect(out.pages == 3 && out.rowsStored == 3 && out.opsOpened == 3)
    #expect(try b.store.wireRowCount() == 3)
    #expect(try b.store.chainHeads()[a.writerID]?.counter == 3)
    #expect(try await Puller.pull(b, observer: nil, plaintextBudget: 1).rowsStored == 0)
  }

  @Test("a short page asks again for the rest; a page whose last row meets the budget does not")
  func roundTrips() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, (1...3).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    let (pull, routes) = counted(b, through: w.server)
    let out = try await Puller.pull(pull, observer: nil, plaintextBudget: 1)
    #expect(out.rowsStored == 3 && routes.count("GET /api/v1/sync") == 3)
  }

  @Test("within budget, one pull stores the page whole")
  func wholePage() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(a, (1...3).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    let out = try await Puller.pull(b, observer: nil)
    #expect(out.pages == 1 && out.rowsStored == 3)
  }

  @Test("a stored pin that is half there stops the pull at the roster check, with the page kept out")
  func halfPinnedWriterIsNotLive() async throws {
    let (w, a, b) = try await twoPhones()
    #expect(await SyncEngine(context: b).run(.launch).stop == nil)
    try enqueue(a, [alone(1)])
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    #expect(w.server.storedRowCount(user: a.userID) == 1)

    let stored = try #require(try b.store.syncState().rosterJSON)
    var o = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
    var writers = try #require(o["writers"] as? [String: [String: Any]])
    writers[a.writerID.string]?["final_counter"] = 1
    o["writers"] = writers
    try b.store.setRoster(try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
    let cursor = try b.store.syncState().cursorHot

    await #expect(throws: SyncStop.halted(.rosterInvalid)) { _ = try await Puller.pull(b, observer: nil) }
    #expect(try b.store.syncState().cursorHot == cursor)
  }

  @Test("the cold fold reaches the same state when it folds in smaller slices")
  func coldFoldSlices() async throws {
    let (_, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    #expect(await b.run(.launch).stop == nil)
    let cursor = try b.context.store.syncState().cursorHot
    let whole = try await b.observer.coldFold(cursor: cursor)
    let sliced = try await b.observer.coldFold(cursor: cursor, plaintextBudget: 1)
    #expect(whole.serialized() == sliced.serialized() && cursor > 0)
  }
}

@Suite("Pull: each network step of a page runs once")
struct PageRefreshOnceTests {
  func twoPhones() async throws -> (World, SyncContext, SyncContext) { try await PagePlaintextTests().twoPhones() }

  func injectAboveHWM(_ w: World, _ a: SyncContext) throws {
    let key = try EpochKey(epoch: 2, key: Data(repeating: 3, count: 32))
    let envelope = try Envelope(userID: a.userID, writerID: a.writerID, counter: 1)
    let frame = try Sealer(epoch: 2, key: key).seal(
      plaintextOps: Data(#"{"v":4,"kind":"ops","ops":[]}"#.utf8), envelope: envelope, prevHash: .zero, random: a.random)
    let seed = try #require(try a.secrets.writerSeed(userID: a.userID, writerID: a.writerID))
    let sig = try Ed25519.sign(
      seed: seed, message: SigningMessage.head(userID: a.userID, counter: 1, blobHash: frame.blobHash, writerID: a.writerID))
    w.server.injectRow(
      user: a.userID, writerID: a.writerID.string, counter: 1, prevHash: Data(count: 32), blob: frame.bytes, headSig: sig)
  }

  @Test("an unknown writer: one key-history fetch, then tampered")
  func rosterOnce() async throws {
    let (w, a, b) = try await twoPhones()
    w.server.injectRow(
      user: a.userID, writerID: "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", counter: 1, prevHash: Data(count: 32),
      blob: Data(repeating: 7, count: 1024), headSig: Data(repeating: 1, count: 64))
    let (pull, routes) = counted(b, through: w.server)
    await #expect(throws: SyncStop.halted(.tampered(.unknownWriter))) { _ = try await Puller.pull(pull, observer: nil) }
    #expect(routes.count("GET /api/v1/key-history") == 1)
  }

  @Test("a frame above the published epoch: one keys read, then tampered")
  func epochOnceRefused() async throws {
    let (w, a, b) = try await twoPhones()
    try injectAboveHWM(w, a)
    let (pull, routes) = counted(b, through: w.server)
    await #expect(throws: SyncStop.halted(.tampered(.epochInvalid))) { _ = try await Puller.pull(pull, observer: nil) }
    #expect(routes.count("GET /api/v1/keys") == 1)
  }

  @Test("a frame at the published epoch this iPhone has no key for: one keys read, then the unlock")
  func epochOnceAccepted() async throws {
    let (w, a, b) = try await twoPhones()
    try injectAboveHWM(w, a)
    w.server.publishEpoch(user: a.userID, 2)
    let (pull, routes) = counted(b, through: w.server)
    await #expect(throws: SyncStop.needsUnlock(epoch: 2)) { _ = try await Puller.pull(pull, observer: nil) }
    #expect(routes.count("GET /api/v1/keys") == 1)
  }
}

@Suite("Pull: a short page with the real observer")
struct ShortPageObserverTests {
  @Test("a commit inside a page leaves a snapshot at its cursor, a warm start equal to a cold fold, and the pull goes on")
  func commitInsideAPage() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    let wall = w.clock.nowMs() + LocalClock.offsetMs
    for (i, m) in ["SYNTHETIC ONE", "SYNTHETIC TWO"].enumerated() {
      try await a.author { x in _ = try ObserverSyncTests.manual(&x, m, 1_000 + Int64(i), at: wall) }
      #expect(await a.run(.authored).stop == nil)
    }

    let before = try b.context.store.syncState()
    let bearer = try b.context.bearer()
    let page = try await b.context.client.pull(after: before.cursorHot, limit: Puller.pageLimit, bearer: bearer)
    #expect(page.rows.count == 3)
    var summary = PullSummary()
    let stored = try await Puller.readAndPersist(
      page, state: before, bearer: bearer, ctx: b.context, observer: b.observer, plaintextBudget: 1, summary: &summary)
    #expect(stored == Puller.StoredPage(rows: 1, whole: false) && summary.rowsStored == 1)

    let cursor = try b.context.store.syncState().cursorHot
    #expect(cursor == Int64(page.rows[0].seq))
    #expect(try b.context.store.foldSnapshot()?.cursorHot == cursor)
    #expect(try await b.state().cursors.hot == cursor)

    let warm = try Runtime(b.context)
    try await warm.observer.open()
    let events = try b.context.store.foldEvents().map(\.kind)
    #expect(!events.contains("cold_fold") && !events.contains("snapshot_rejected"))
    let warmState = try await warm.state()
    let coldState = try await warm.observer.coldFold(cursor: cursor)
    #expect(warmState.serialized() == coldState.serialized())

    #expect(await b.run(.launch).stop == nil)
    #expect(try await a.state().serialized() == b.state().serialized())
  }

  @Test("rows near the plaintext limit: the default budget commits a shorter page, then the rest")
  func defaultBudget() async throws {
    let (_, a, b) = try await twoRuntimes()
    let pad = String(repeating: "x", count: 2_000_000)
    let ops = (1...6).map { i in
      Op(
        v: 4, type: .merchantCategoryRejected, opID: "01J0000000000000000000B0\(String(format: "%02d", i))",
        authoredAt: "2026-10-11T08:00:00.000Z",
        payload: .object(JSONObject([("merchant", .string("SYNTHETIC")), ("category", .string("food")), ("pad", .string(pad))])))
    }
    try enqueue(a.context, ops)
    #expect(await a.run(.authored).stop == nil)
    let out = await b.run(.launch)
    #expect(out.stop == nil && out.pulled.rowsStored == 6 && out.pulled.pages == 2)
    #expect(try await a.state().serialized() == b.state().serialized())
  }
}

@Suite("A revocation answer proved against the pinned key history")
struct SettledRevocationTests {
  let unproved = SyncStop.halted(.unprovedRevocation)

  func phone() async throws -> (World, Phone, SyncContext) {
    let w = World()
    let a = w.phone("a")
    let (_, _, ctx) = try await w.passwordAccount(a)
    return (w, a, ctx)
  }

  @Test("other stops pass through untouched")
  func otherStops() async throws {
    let (_, _, ctx) = try await phone()
    #expect(await ctx.settled(.offline) == .offline)
    #expect(await ctx.settled(.wipe) == .wipe)
    #expect(await ctx.settled(.halted(.rosterInvalid)) == .halted(.rosterInvalid))
  }

  @Test("a live writer stays halted, with the stop it came in with")
  func live() async throws {
    let (_, _, ctx) = try await phone()
    #expect(await ctx.settled(unproved) == unproved)
  }

  @Test("a locked Keychain is not now, with everything kept")
  func locked() async throws {
    let (_, a, ctx) = try await phone()
    a.keychain.locked = true
    #expect(await ctx.settled(unproved) == .notNow)
    a.keychain.locked = false
    #expect(try ctx.secrets.session() != nil)
  }

  @Test("the key history's own answers decide: 401, 5xx, a second claim, and a deleted account")
  func keyHistoryAnswers() async throws {
    let (w, _, ctx) = try await phone()
    for (status, code, want) in [
      (401, "unauthorized", SyncStop.needsSignIn), (503, "unavailable", .offline), (403, "writer_revoked", unproved),
      (410, "account_deleted", .wipe), (410, "link_expired", .halted(.unexpectedGone)),
    ] {
      w.server.refuseNext("GET /api/v1/key-history", status: status, code: code)
      #expect(await ctx.settled(unproved) == want, "\(status) \(code)")
    }
  }

  @Test("no way to reach the server is offline")
  func transportFailure() async throws {
    struct Unreachable: Transport {
      func send(_ request: APIRequest) async throws(TransportError) -> APIResponse { throw .offline(.notConnectedToInternet) }
    }
    let (_, _, ctx) = try await phone()
    let offline = SyncContext(
      userID: ctx.userID, writerID: ctx.writerID, store: ctx.store, secrets: ctx.secrets, client: AuthClient(transport: Unreachable()),
      clock: ctx.clock, random: ctx.random)
    #expect(await offline.settled(unproved) == .offline)
  }

  @Test("a stored roster that does not read halts as a roster failure")
  func noPin() async throws {
    let (_, _, ctx) = try await phone()
    try ctx.store.setRoster(Data("not a roster".utf8))
    #expect(await ctx.settled(unproved) == .halted(.rosterInvalid))
  }
}
