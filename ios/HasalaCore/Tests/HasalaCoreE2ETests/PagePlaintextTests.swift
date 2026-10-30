import CoreAuth
import CoreCrypto
import CoreJSON
import CoreProjection
import CoreReplay
import CoreSoftAuth
import CoreTime
import CoreTestSupport
import CoreWire
import Foundation
import Testing

@testable import CoreSync

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

  @Test("within budget, one pull stores the page whole")
  func wholePage() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(a, (1...3).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    let out = try await Puller.pull(b, observer: nil)
    #expect(out.pages == 1 && out.rowsStored == 3)
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
    #expect(stored == 1 && summary.rowsStored == 1)

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
