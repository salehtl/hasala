// The ordering and rollback rules the first review of WS-11 asked for: the
// roster only ever extends (01 §10.13), one flush at a time, no lost trigger,
// the DWK in the Keychain before the writer is used, no half-enrolled iPhone,
// and E-04 before the binding (04 §6.2).
import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Testing

@Suite("Hardening: roster rollback, one flush, triggers, enrolment order")
struct HardeningTests {
  /// Phone A with an account, phone B enrolled on it.
  func twoPhones(_ w: World) async throws -> (Phone, SyncContext, Phone, SyncContext) {
    let a = w.phone("a")
    let (account, words, ctxA) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    let enrolled = try await Enrolment.enrolWriter(
      b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    return (a, ctxA, b, Enrolment.context(b.env, account: enrolled))
  }

  // MARK: Roster rollback (01 §10.13)

  @Test("a server that drops a pinned revocation is refused: rosterInvalid, the pinned final kept")
  func rosterRollback() async throws {
    let w = World()
    let (a, ctxA, _, ctxB) = try await twoPhones(w)
    try enqueue(ctxA, [op(1)])
    #expect(await SyncEngine(context: ctxA).run(.authored).stop == nil)
    try await AccountManagement.removeThisIPhone(
      a.env, engine: SyncEngine(context: ctxA), factor: .device(password: password), binding: try #require(a.binding))
    let engineB = SyncEngine(context: ctxB)
    #expect(await engineB.run(.launch).stop == nil)
    let pinned = try #require(PinnedRoster.decode(try ctxB.store.syncState().rosterJSON))
    #expect(pinned.writers[ctxA.writerID.string]?.final_counter == 1)

    w.server.rollBackRevocation(user: ctxA.userID, writer: ctxA.writerID)
    #expect(await engineB.run(.launch).stop == .halted(.rosterInvalid))
    let after = try #require(PinnedRoster.decode(try ctxB.store.syncState().rosterJSON))
    #expect(after == pinned)
  }

  @Test("PinnedRoster.extends: new writers and revocations pass; a lower entry id, a lost writer, a changed key or final fail")
  func extendsRules() throws {
    func roster(_ last: Int64?, _ writers: [String: (String, Int64?)]) throws -> PinnedRoster {
      var w: [String: Any] = [:]
      for (id, v) in writers {
        var e: [String: Any] = ["dwk": v.0, "dak": "DAK"]
        if let c = v.1 { e["final_counter"] = c; e["final_head"] = "HEAD" }
        w[id] = e
      }
      var o: [String: Any] = ["authority_pubkey": "AAK", "writers": w]
      if let last { o["last_entry_id"] = last }
      return try JSONDecoder().decode(PinnedRoster.self, from: JSONSerialization.data(withJSONObject: o))
    }
    let pinned = try roster(3, ["a": ("A", nil), "b": ("B", 4)])
    #expect(try roster(3, ["a": ("A", nil), "b": ("B", 4)]).extends(pinned))
    #expect(try roster(5, ["a": ("A", 2), "b": ("B", 4), "c": ("C", nil)]).extends(pinned))
    #expect(try !roster(2, ["a": ("A", nil), "b": ("B", 4)]).extends(pinned))  // older history
    #expect(try !roster(nil, ["a": ("A", nil), "b": ("B", 4)]).extends(pinned))
    #expect(try !roster(4, ["a": ("A", nil)]).extends(pinned))  // a writer vanished
    #expect(try !roster(4, ["a": ("A", nil), "b": ("B", nil)]).extends(pinned))  // revocation cleared
    #expect(try !roster(4, ["a": ("A", nil), "b": ("B", 5)]).extends(pinned))  // final moved
    #expect(try !roster(4, ["a": ("X", nil), "b": ("B", 4)]).extends(pinned))  // key swapped
    // The AAK-only roster a transient enrolment failure pins accepts any verified roster.
    #expect(try roster(1, ["a": ("A", nil)]).extends(try roster(nil, [:])))
  }

  // MARK: One flush at a time

  @Test("removal's catch-up runs through the engine: alongside an authored run, each op is uploaded once")
  func removalAndRunDoNotDoubleSeal() async throws {
    let w = World()
    let (a, ctxA, _, ctxB) = try await twoPhones(w)
    try enqueue(ctxA, [op(1), op(2)])
    let engine = SyncEngine(context: ctxA)
    async let run = engine.run(.authored)
    async let removal: Void = AccountManagement.removeThisIPhone(
      a.env, engine: engine, factor: .device(password: password), binding: try #require(a.binding))
    _ = await run
    try await removal
    #expect(w.server.storedRowCount(user: ctxA.userID) == 1)
    _ = await SyncEngine(context: ctxB).run(.launch)
    #expect(try storedOps(ctxB).map(\.opID) == [op(1).opID, op(2).opID])
  }

  // MARK: Triggers

  @Test("a trigger that arrives while a run waits on the network is not lost")
  func triggerDuringRun() async throws {
    let w = World()
    let a = w.phone("a")
    let (_, _, ctx) = try await w.passwordAccount(a)
    let gate = Gate(inner: w.server)
    let slow = SyncContext(
      userID: ctx.userID, writerID: ctx.writerID, store: ctx.store, secrets: ctx.secrets,
      client: AuthClient(transport: gate), clock: ctx.clock, random: ctx.random)
    let engine = SyncEngine(context: slow)
    async let first = engine.run(.foreground)
    while gate.held == 0 { await Task.yield() }
    try enqueue(ctx, [op(1)])
    async let second = engine.run(.authored)
    for _ in 0..<200 { await Task.yield() }
    gate.open()
    let (o1, o2) = await (first, second)
    #expect(o1.stop == nil && o2.stop == nil)
    #expect(try ctx.store.pendingCount() == 0)
    #expect(w.server.uploadCount == 1)
  }

  // MARK: Enrolment order (04 §6.2)

  @Test("the DWK is in the Keychain before writers/register: a lost register leaves the key here")
  func writerKeyBeforeRegister() async throws {
    let w = World()
    let a = w.phone("a")
    let (account, words, _) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    let before = b.keychain.count
    w.server.refuseNext("POST /api/v1/writers/register", status: 503, code: "unavailable")
    await #expect(throws: CeremonyError.self) {
      _ = try await Enrolment.enrolWriter(
        b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    }
    #expect(b.keychain.count == before + 1)  // the writer key, nothing else
    #expect(b.binding == nil)
  }

  @Test("a transient roster failure after the server accepted the writer still binds; the first run pins the roster")
  func transientRosterFailureStillBinds() async throws {
    let w = World()
    let a = w.phone("a")
    let (account, words, _) = try await w.passwordAccount(a)
    let p = w.phone("b")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hasala-roster-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let env = AccountEnvironment(
      client: p.env.client, secrets: p.env.secrets, approvalKeys: p.dak, passkeys: p.passkeys, clock: w.clock,
      random: p.env.random, apiBase: p.env.apiBase, accountsDirectory: dir)
    let r = try await AccountSignIn.withPassword(env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(env, userID: account.userID, typed: words.joined(separator: " "))
    w.server.refuseNext("GET /api/v1/key-history", status: 503, code: "unavailable")
    let enrolled = try await Enrolment.enrolWriter(
      env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    guard case .opening = Boot.decide(Boot.gather(env)) else {
      Issue.record("boot does not open the enrolled account")
      return
    }
    let ctxB = Enrolment.context(env, account: enrolled)
    #expect(PinnedRoster.decode(try ctxB.store.syncState().rosterJSON)?.writers.isEmpty == true)
    #expect(await SyncEngine(context: ctxB).run(.launch).stop == nil)
    let pinned = try #require(PinnedRoster.decode(try ctxB.store.syncState().rosterJSON))
    #expect(pinned.writers[enrolled.writerID.string] != nil && pinned.writers.count == 2)
  }

  @Test("E-04: a different address after bootstrap stops onboarding durably: no binding, boot is not opening")
  func addressMismatchStopsOnboarding() async throws {
    for reported in ["someone@example.com", nil] as [String?] {
      let w = World()
      let a = w.phone("a")
      let signup = try await AccountCreation.beginSignup(
        a.env, inviteCode: "abcd-efgh-ijkl-mnop-qrst-uvwx", email: "maya@example.com", displayName: "Maya",
        inviteLinkKey: nil)
      try await AccountCreation.verifySignup(a.env, signup, code: try #require(w.server.lastCode))
      w.server.misreportEmail(user: signup.userID, reported)
      let keys = try NewAccountKeys.generate(random: a.env.random)
      do {
        _ = try await AccountCreation.createWithPassword(a.env, signup: signup, password: password, keys: keys)
        Issue.record("created despite a different address")
      } catch {
        guard case .integrityAlarm(let what) = error else {
          Issue.record("not the integrity alarm: \(error)")
          continue
        }
        #expect(what == "address differs after bootstrap")
      }
      #expect(a.binding == nil)
      #expect(Boot.decide(Boot.gather(a.env)) == .onboardingKeys)
    }
  }
}

/// Holds every request until `open()` (a slow network), then forwards them.
final class Gate: Transport, @unchecked Sendable {
  let inner: any Transport
  private let lock = NSLock()
  private var closed = true
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var heldCount = 0

  init(inner: any Transport) { self.inner = inner }

  var held: Int { lock.withLock { heldCount } }

  func open() {
    let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      closed = false
      defer { waiting = [] }
      return waiting
    }
    for c in w { c.resume() }
  }

  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      let go = lock.withLock { () -> Bool in
        guard closed else { return true }
        waiting.append(c)
        heldCount += 1
        return false
      }
      if go { c.resume() }
    }
    return try await inner.send(request)
  }
}
