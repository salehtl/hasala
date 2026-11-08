import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Testing

final class AfterAnswer: Transport, @unchecked Sendable {
  let inner: any Transport
  let suffix: String
  let lose: Bool
  let then: @Sendable () -> Void
  private let lock = NSLock()
  private var armed = true

  init(inner: any Transport, suffix: String, lose: Bool, then: @escaping @Sendable () -> Void = {}) {
    self.inner = inner
    self.suffix = suffix
    self.lose = lose
    self.then = then
  }

  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    let hit =
      request.path.hasSuffix(suffix)
      && lock.withLock { () -> Bool in
        defer { armed = false }
        return armed
      }
    if hit, lose { throw .offline(.networkConnectionLost) }
    let response = try await inner.send(request)
    if hit { then() }
    return response
  }
}

@Suite("Access recovery with the twelve words")
struct AccountRecoveryTests {
  func account(_ w: World) async throws -> (UserID, [String]) {
    let (made, words, _) = try await w.passwordAccount(w.phone("a"))
    return (made.userID, words)
  }

  func verified(_ w: World, _ b: Phone, _ words: [String]) async throws -> Recovery {
    let r = try await AccountRecovery.begin(b.env, typed: words.joined(separator: " "))
    try await AccountRecovery.verifyForPasskey(b.env, r, code: try #require(w.server.lastCode))
    return r
  }

  func phone(_ w: World, losingAccountFetch: Bool = true) -> Phone {
    Phone(
      transport: losingAccountFetch ? AfterAnswer(inner: w.server, suffix: "/api/v1/account", lose: true) : w.server,
      clock: w.clock, seed: "b")
  }

  func boundWriter(_ phone: Phone) async throws -> String {
    let token = try #require(try phone.env.secrets.session()).token
    return try #require(try await phone.env.client.session(bearer: token).writer_id)
  }

  @Test("the words and a code finish on a new iPhone with one passkey and one new writer")
  func finishes() async throws {
    let w = World()
    let (user, words) = try await account(w)
    let b = phone(w, losingAccountFetch: false)
    let r = try await verified(w, b, words)
    let enrolled = try await AccountRecovery.finishWithPasskey(b.env, r)
    #expect(enrolled.userID == user)
    #expect(b.binding?.writer_id == enrolled.writerID.string)
    #expect(b.binding?.email_norm == "maya@example.com")
    #expect(b.binding?.display_name == "Maya")
    #expect(try await boundWriter(b) == enrolled.writerID.string)
    #expect(b.passkeys.credentials.count == 1)
    let ctx = Enrolment.context(b.env, account: enrolled)
    try enqueue(ctx, [op(1)])
    #expect(await SyncEngine(context: ctx).run(.authored).stop == nil)
    #expect(try ctx.store.pendingCount() == 0)
  }

  @Test("a failure after the server took the recovery: the same ceremony finishes with its writer and no second passkey")
  func finishesAfterALostAccountFetch() async throws {
    let w = World()
    let (_, words) = try await account(w)
    let b = phone(w)
    let r = try await verified(w, b, words)
    await #expect(throws: CeremonyError.self) { _ = try await AccountRecovery.finishWithPasskey(b.env, r) }
    #expect(b.binding == nil)
    let writer = try await boundWriter(b)
    let enrolled = try await AccountRecovery.finishWithPasskey(b.env, r)
    #expect(enrolled.writerID.string == writer)
    #expect(b.binding?.writer_id == writer)
    #expect(b.passkeys.credentials.count == 1)
    let token = try #require(try b.env.secrets.session()).token
    #expect(try await b.env.client.writers(bearer: token).writers.count == 2)
    #expect(try await b.env.client.account(bearer: token).has_passkey == true)
  }

  @Test("a closed sheet keeps the ceremony; a refusal before the server took it, or an alarm after, ends it")
  func whatEndsACeremony() async throws {
    let w = World()
    let (_, words) = try await account(w)
    let b = phone(w)
    let r = try await verified(w, b, words)
    #expect(r.canFinish(after: .passkey(.cancelled)))
    #expect(!r.canFinish(after: .api(.refused(APIFailure(status: 403, code: "recovery_refused")))))
    do throws(CeremonyError) {
      _ = try await AccountRecovery.finishWithPasskey(b.env, r)
      Issue.record("finished past a lost answer")
    } catch {
      #expect(error.failureClass == .offline)
      #expect(r.canFinish(after: error))
    }
    #expect(!r.canFinish(after: .integrityAlarm("own writer not in key history")))
  }

  @Test("a session the Keychain refused after the server took the recovery is written when the same ceremony finishes")
  func finishesAfterARefusedSessionWrite() async throws {
    let w = World()
    let (_, words) = try await account(w)
    let holder = Holder()
    let b = Phone(
      transport: AfterAnswer(inner: w.server, suffix: "/api/v1/auth/recover/finish", lose: false) { holder.keychain?.locked = true },
      clock: w.clock, seed: "b")
    holder.keychain = b.keychain
    let r = try await verified(w, b, words)
    await #expect(throws: CeremonyError.self) { _ = try await AccountRecovery.finishWithPasskey(b.env, r) }
    b.keychain.locked = false
    #expect(try b.env.secrets.session() == nil)
    let enrolled = try await AccountRecovery.finishWithPasskey(b.env, r)
    #expect(b.binding?.writer_id == enrolled.writerID.string)
    #expect(try await boundWriter(b) == enrolled.writerID.string)
    #expect(b.passkeys.credentials.count == 1)
  }

  @Test("after a relaunch the words finish with the writer the server took")
  func relaunchWithTheWordsKeepsTheWriter() async throws {
    let w = World()
    let (user, words) = try await account(w)
    let b = phone(w)
    let r = try await verified(w, b, words)
    await #expect(throws: CeremonyError.self) { _ = try await AccountRecovery.finishWithPasskey(b.env, r) }
    #expect(Boot.decide(Boot.gather(b.env)) == .onboardingKeys)
    let writer = try await boundWriter(b)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: user, typed: words.joined(separator: " "))
    defer { body.wipe() }
    let enrolled = try await Enrolment.enrolWriter(b.env, userID: user, body: body, emailNorm: nil, serverSalt: nil)
    #expect(enrolled.writerID.string == writer)
    let token = try #require(try b.env.secrets.session()).token
    #expect(try await b.env.client.writers(bearer: token).writers.count == 2)
  }

  @Test("after a relaunch Face ID replaces the session and finishes with the writer the server took")
  func relaunchWithThePasskeyKeepsTheWriter() async throws {
    let w = World()
    let (user, words) = try await account(w)
    let b = phone(w)
    let r = try await verified(w, b, words)
    await #expect(throws: CeremonyError.self) { _ = try await AccountRecovery.finishWithPasskey(b.env, r) }
    let writer = try await boundWriter(b)
    let again = try await AccountSignIn.replacingHeldSession(b.env, wantPRF: true)
    #expect(again.boundWriter?.string == writer)
    let assertion = try #require(again.assertion)
    let body = try await Enrolment.unlockWithPRF(
      b.env, userID: user, credentialID: assertion.credentialID, prf: assertion.prfFirst)
    defer { body.wipe() }
    let enrolled = try await Enrolment.enrolWriter(b.env, userID: user, body: body, emailNorm: nil, serverSalt: nil)
    #expect(enrolled.writerID.string == writer)
    let token = try #require(try b.env.secrets.session()).token
    #expect(try await b.env.client.writers(bearer: token).writers.count == 2)
  }
}

final class Holder: @unchecked Sendable {
  var keychain: MemorySecretStore?
}
