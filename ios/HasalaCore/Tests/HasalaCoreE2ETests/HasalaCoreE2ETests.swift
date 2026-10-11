// T3/T4 protocol scenarios (spec 04 §19.1, §19.4) against the in-process
// FakeServer: creation, enrolment, sync, the resend rules and the tamper
// stops. Owner: WS-11.
import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Testing

@Suite("Accounts: signup, creation, sign-in, enrolment")
struct AccountTests {
  @Test("C1-P: one password/register, then the Keychain, the store and the E-04 comparison")
  func passwordCreation() async throws {
    let w = World()
    let a = w.phone("a")
    let (account, words, ctx) = try await w.passwordAccount(a)
    #expect(words.count == 12)
    let binding = try #require(a.binding)
    #expect(binding.writer_id == account.writerID.string)
    #expect(binding.email_norm == "maya@example.com")
    #expect(try a.env.secrets.session()?.token.isEmpty == false)
    #expect(try a.env.secrets.epochKey(userID: account.userID, epoch: 1)?.count == 32)
    #expect(try a.env.secrets.writerSeed(userID: account.userID, writerID: account.writerID)?.count == 32)
    #expect(try ctx.store.meta()?.writerID == account.writerID)
    let roster = try #require(PinnedRoster.decode(try ctx.store.syncState().rosterJSON))
    #expect(roster.writers.keys.contains(account.writerID.string))
    // The session is bound to the new writer (#45).
    let s = try await a.env.client.session(bearer: try #require(try a.env.secrets.session()).token)
    #expect(s.writer_id == account.writerID.string)
  }

  @Test("signup refuses an unknown invite with not_invited, and a malformed one locally")
  func invites() async throws {
    let w = World()
    let a = w.phone("a")
    do {
      _ = try await AccountCreation.beginSignup(
        a.env, inviteCode: "ZZZZZZZZZZZZZZZZZZZZZZZZ", email: "m@example.com", displayName: "Maya", inviteLinkKey: nil)
      Issue.record("expected not_invited")
    } catch {
      #expect(error.failureClass == .notInvited)
    }
    await #expect(throws: CeremonyError.self) {
      _ = try await AccountCreation.beginSignup(
        a.env, inviteCode: "SHORT", email: "m@example.com", displayName: "Maya", inviteLinkKey: nil)
    }
  }

  @Test("C1: C_reg is recomputed, the session is written at once, bootstrap carries the PRF wrap")
  func passkeyCreation() async throws {
    let w = World()
    let a = w.phone("a")
    let signup = try await AccountCreation.beginSignup(
      a.env, inviteCode: invite, email: "maya@example.com", displayName: "Maya", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(a.env, signup, code: try #require(w.server.lastCode))
    let keys = try NewAccountKeys.generate(random: a.env.random)
    let reg = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: keys)
    #expect(try a.env.secrets.session() != nil)  // R-04: before the phrase is even shown
    #expect(try a.env.secrets.binding() == nil)
    #expect(reg.prf != nil)
    let account = try await AccountCreation.bootstrapPasskey(a.env, registered: reg, keys: keys)
    let token = try #require(try a.env.secrets.session()).token
    let wraps = try await a.env.client.keyWraps(bearer: token)
    #expect(wraps.wraps.count == 1)
    #expect(try a.binding?.writer_id == account.writerID.string)
  }

  @Test("C2b: a bound iPhone signs in with its writer; C2: a new iPhone unlocks with the passkey's PRF")
  func passkeySignIn() async throws {
    let w = World()
    let shared = SoftPasskey()  // iCloud Keychain: both iPhones see the credential
    let a = w.phone("a", passkeys: shared)
    let signup = try await AccountCreation.beginSignup(
      a.env, inviteCode: invite, email: "maya@example.com", displayName: "Maya", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(a.env, signup, code: try #require(w.server.lastCode))
    let keys = try NewAccountKeys.generate(random: a.env.random)
    let reg = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: keys)
    let account = try await AccountCreation.bootstrapPasskey(a.env, registered: reg, keys: keys)

    // C2b on A.
    let again = try await AccountSignIn.withPasskey(a.env, bound: a.binding, wantPRF: false)
    #expect(again.boundWriter == account.writerID)

    // C2 on B: unbound sign-in with PRF, unlock, enrol.
    let b = w.phone("b", passkeys: shared)
    let r = try await AccountSignIn.withPasskey(b.env, bound: nil, wantPRF: true)
    #expect(r.boundWriter == nil && r.hasKeys)
    let assertion = try #require(r.assertion)
    let body = try await Enrolment.unlockWithPRF(
      b.env, userID: account.userID, credentialID: assertion.credentialID, prf: assertion.prfFirst)
    let enrolled = try await Enrolment.enrolWriter(b.env, userID: account.userID, body: body, emailNorm: nil, serverSalt: nil)
    #expect(enrolled.writerID != account.writerID)
    #expect(b.binding?.email_norm == "maya@example.com")
  }

  @Test("C2-P + C3: password sign-in on a new iPhone, the twelve words unlock, the writer enrols; C2b-P binds")
  func phraseEnrolment() async throws {
    let w = World()
    let a = w.phone("a")
    let (account, words, _) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "Maya@Example.com ", password: password, bound: nil)
    #expect(r.hasKeys && r.boundWriter == nil)
    await #expect(throws: CeremonyError.self) {
      _ = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: "abandon abandon abandon")
    }
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    let enrolled = try await Enrolment.enrolWriter(
      b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    // B's roster lists both writers.
    let ctx = Enrolment.context(b.env, account: enrolled)
    let roster = try #require(PinnedRoster.decode(try ctx.store.syncState().rosterJSON))
    #expect(Set(roster.writers.keys) == [account.writerID.string, enrolled.writerID.string])
    // C2b-P from A: bound to A's writer.
    let bound = try await AccountSignIn.withPassword(a.env, email: "maya@example.com", password: password, bound: a.binding)
    #expect(bound.boundWriter == account.writerID)
    // A wrong password is the uniform refusal.
    do {
      _ = try await AccountSignIn.withPassword(a.env, email: "maya@example.com", password: "nope nope nope", bound: nil)
      Issue.record("expected password_rejected")
    } catch {
      #expect(error.failureClass == .wrongCredentials)
    }
  }

  @Test("sign-out calls logout before deleting the session; offline keeps it as pending")
  func signOut() async throws {
    let w = World()
    let a = w.phone("a")
    _ = try await w.passwordAccount(a)
    w.server.refuseNext("POST /api/v1/auth/logout", status: 503, code: "unavailable")
    #expect(await AccountSignIn.signOut(a.env) == false)
    #expect(try a.env.secrets.session()?.pending_logout == true)
    #expect(await AccountSignIn.signOut(a.env) == true)
    #expect(try a.env.secrets.session() == nil)
  }
}

@Suite("Step-up helper")
struct StepUpTests {
  @Test("device proof: password + DAK over C; the server accepts it")
  func deviceProof() async throws {
    let w = World()
    let a = w.phone("a")
    _ = try await w.passwordAccount(a)
    let proof = try await StepUpHelper.prove(
      a.env, params: .sessionLogoutAll, factor: .device(password: password), binding: a.binding,
      reason: "Confirm it's you to sign out everywhere")
    #expect(a.dak.signatureCount == 1)
    let token = try #require(try a.env.secrets.session()).token
    struct Body: Encodable { let step_up: StepUpJSON }
    let r = try await a.env.client.api.send(
      APIRequest(method: .post, path: "/api/v1/auth/logout-all", body: try APIClient.encode(Body(step_up: proof.stepUp)), bearer: token))
    #expect(r.status == 204)
  }

  @Test("a challenge that is not this client's C is refused before any prompt")
  func challengeMismatch() async throws {
    let w = World()
    let a = w.phone("a")
    _ = try await w.passwordAccount(a)
    let bad = StepUpBeginResponse(
      nonce: Base64.encodeURL(Data(repeating: 1, count: 32)), challenge: Base64.encodeURL(Data(repeating: 2, count: 32)),
      expires_at: nil, rp_id: nil, allow_credentials: nil)
    let t = OverrideTransport(inner: w.server, route: "POST /api/v1/auth/step-up/begin", body: bad)
    let env = AccountEnvironment(
      client: AuthClient(transport: t), secrets: a.env.secrets, approvalKeys: a.dak, passkeys: a.passkeys,
      clock: w.clock, random: a.env.random, apiBase: a.env.apiBase, accountsDirectory: nil)
    do {
      _ = try await StepUpHelper.prove(
        env, params: .sessionLogoutAll, factor: .device(password: password), binding: a.binding, reason: "x")
      Issue.record("expected challengeMismatch")
    } catch {
      guard case .challengeMismatch = error else { Issue.record("got \(error)"); return }
    }
    #expect(a.dak.signatureCount == 0)
  }

  @Test("passkey proof for an action that allows only passkeys")
  func passkeyProof() async throws {
    let w = World()
    let a = w.phone("a")
    let signup = try await AccountCreation.beginSignup(
      a.env, inviteCode: invite, email: "maya@example.com", displayName: "Maya", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(a.env, signup, code: try #require(w.server.lastCode))
    let keys = try NewAccountKeys.generate(random: a.env.random)
    let reg = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: keys)
    _ = try await AccountCreation.bootstrapPasskey(a.env, registered: reg, keys: keys)
    let proof = try await StepUpHelper.prove(
      a.env, params: .sessionLogoutAll, factor: .passkey, binding: a.binding, reason: "x")
    let token = try #require(try a.env.secrets.session()).token
    struct Body: Encodable { let step_up: StepUpJSON }
    let r = try await a.env.client.api.send(
      APIRequest(method: .post, path: "/api/v1/auth/logout-all", body: try APIClient.encode(Body(step_up: proof.stepUp)), bearer: token))
    #expect(r.status == 204)
    await #expect(throws: CeremonyError.self) {
      _ = try await StepUpHelper.prove(
        a.env, params: .passwordSet(newVerifierHash: Data(count: 32)), factor: .device(password: password),
        binding: a.binding, reason: "x")
    }
  }
}

/// Answers one route with a fixed body, passing everything else through.
struct OverrideTransport<B: Encodable & Sendable>: Transport {
  let inner: any Transport
  let route: String
  let body: B

  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    let path = String(request.path.split(separator: "?").first ?? "")
    if "\(request.method.rawValue) \(path)" == route {
      return APIResponse(status: 200, body: (try? JSONEncoder().encode(body)) ?? Data())
    }
    return try await inner.send(request)
  }
}

@Suite("Boot and the launch probe")
struct BootLaunchTests {
  @Test("an enrolled iPhone with its store on disk opens; the probe sees a bound, unrestricted session")
  func opens() async throws {
    let w = World()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hasala-boot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = w.phone("a")
    let env = AccountEnvironment(
      client: p.env.client, secrets: p.env.secrets, approvalKeys: p.dak, passkeys: p.passkeys, clock: w.clock,
      random: p.env.random, apiBase: p.env.apiBase, accountsDirectory: dir)
    let signup = try await AccountCreation.beginSignup(
      env, inviteCode: invite, email: "maya@example.com", displayName: "Maya", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(env, signup, code: try #require(w.server.lastCode))
    let account = try await AccountCreation.createWithPassword(
      env, signup: signup, password: password, keys: try NewAccountKeys.generate(random: env.random))
    guard case .opening(let b) = Boot.decide(Boot.gather(env)) else { Issue.record("not opening"); return }
    let ctx = try Enrolment.context(env, binding: b)
    #expect(ctx.writerID == account.writerID)
    #expect(await LaunchProbe.run(ctx, build: 1) == .ok)
    w.server.freeze(user: account.userID)
    #expect(await LaunchProbe.run(ctx, build: 1) == .frozen)
    try env.secrets.deleteSession()
    #expect(Boot.decide(Boot.gather(env)) == .signedOutBound)
  }

  @Test("re-enrolling after `unenrolled` starts the new writer on a fresh store, never on the old chain")
  func reEnrol() async throws {
    let w = World()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hasala-reenrol-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = w.phone("a")
    let env = AccountEnvironment(
      client: p.env.client, secrets: p.env.secrets, approvalKeys: p.dak, passkeys: p.passkeys, clock: w.clock,
      random: p.env.random, apiBase: p.env.apiBase, accountsDirectory: dir)
    let signup = try await AccountCreation.beginSignup(
      env, inviteCode: invite, email: "maya@example.com", displayName: "Maya", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(env, signup, code: try #require(w.server.lastCode))
    let keys = try NewAccountKeys.generate(random: env.random)
    let words = try keys.words()
    let first = try await AccountCreation.createWithPassword(env, signup: signup, password: password, keys: keys)
    let ctx = Enrolment.context(env, account: first)
    try enqueue(ctx, [op(1)])
    #expect(await SyncEngine(context: ctx).run(.authored).stop == nil)
    #expect(try ctx.store.syncState().authoredHead.counter == 1)
    // The DWK is lost: boot says unenrolled; the phrase enrols a new writer.
    try p.keychain.delete(.writerKey(userID: first.userID, writerID: first.writerID))
    #expect(Boot.decide(Boot.gather(env)) == .unenrolled)
    _ = try await AccountSignIn.withPassword(env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(env, userID: first.userID, typed: words.joined(separator: " "))
    let second = try await Enrolment.enrolWriter(
      env, userID: first.userID, body: body, emailNorm: "maya@example.com", serverSalt: nil)
    #expect(try second.store.meta()?.writerID == second.writerID)
    #expect(try second.store.syncState().authoredHead == .genesis)
    let ctx2 = Enrolment.context(env, account: second)
    try enqueue(ctx2, [op(2)])
    #expect(await SyncEngine(context: ctx2).run(.authored).stop == nil)
    #expect(try storedOps(ctx2).map(\.opID) == [op(1).opID, op(2).opID])
  }
}

@Suite("Remove this iPhone and delete the account")
struct AccountManagementTests {
  @Test("remove: the own head is pinned, the roster shows it revoked, this iPhone is wiped")
  func remove() async throws {
    let w = World()
    let a = w.phone("a")
    let (account, words, ctxA) = try await w.passwordAccount(a)
    try enqueue(ctxA, [op(1)])
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    let enrolledB = try await Enrolment.enrolWriter(
      b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    try await AccountManagement.removeThisIPhone(
      a.env, engine: SyncEngine(context: ctxA), factor: .device(password: password), binding: try #require(a.binding))
    #expect(a.keychain.count == 0)  // §4.7 row 2: every item gone
    // B's verified roster: A revoked at counter 1 (the op A flushed first).
    let ctxB = Enrolment.context(b.env, account: enrolledB)
    _ = await SyncEngine(context: ctxB).run(.launch)
    let token = try #require(try b.env.secrets.session()).token
    let roster = try await RosterService.fetch(
      client: b.env.client, bearer: token, authorityPublicKey: try #require(PinnedRoster.decode(try ctxB.store.syncState().rosterJSON)?.authorityPublicKey))
    #expect(roster.writers[account.writerID.string]?.final_counter == 1)
    #expect(try storedOps(ctxB).map(\.opID) == [op(1).opID])
  }

  @Test("delete: step-up account.delete plus the DWK's DeletionMessage; afterwards 410 wipes other iPhones")
  func delete() async throws {
    let w = World()
    let a = w.phone("a")
    let (_, _, ctx) = try await w.passwordAccount(a)
    let token = try #require(try a.env.secrets.session()).token
    try await AccountManagement.deleteAccount(a.env, ctx: ctx, factor: .device(password: password), binding: try #require(a.binding))
    #expect(a.keychain.count == 0)
    do {
      _ = try await a.env.client.keys(bearer: token)
      Issue.record("expected 410")
    } catch {
      #expect(error.failure?.status == 410 && error.failure?.code == "account_deleted")
    }
  }
}
