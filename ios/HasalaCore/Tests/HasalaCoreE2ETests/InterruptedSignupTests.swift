import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Testing

@Suite("A signup stopped after its bootstrap")
struct InterruptedSignupTests {
  func signedUp(_ w: World, _ a: Phone) async throws -> Signup {
    let signup = try await AccountCreation.beginSignup(
      a.env, inviteCode: invite, email: "maya@example.com", displayName: "Maya", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(a.env, signup, code: try #require(w.server.lastCode))
    return signup
  }

  func expectFinishesWithTheServersWriter(_ a: Phone, _ user: UserID, _ words: [String]) async throws {
    #expect(a.binding == nil)
    #expect(Boot.decide(Boot.gather(a.env)) == .onboardingKeys)
    let token = try #require(try a.env.secrets.session()).token
    #expect(try await a.env.client.account(bearer: token).has_keys == true)
    let writer = try #require(try await a.env.client.session(bearer: token).writer_id)
    let body = try await Enrolment.unlockWithPhrase(a.env, userID: user, typed: words.joined(separator: " "))
    defer { body.wipe() }
    let enrolled = try await Enrolment.enrolWriter(a.env, userID: user, body: body, emailNorm: nil, serverSalt: nil)
    #expect(enrolled.writerID.string == writer)
    #expect(a.binding?.writer_id == writer)
    #expect(try await a.env.client.writers(bearer: token).writers.count == 1)
  }

  @Test("a lost bootstrap answer: the unlock after a relaunch finishes with the writer the server took")
  func lostBootstrapAnswerKeepsItsWriter() async throws {
    let w = World()
    let a = Phone(transport: LoseBootstrapAnswer(inner: w.server), clock: w.clock, seed: "a")
    let signup = try await signedUp(w, a)
    let keys = try NewAccountKeys.generate(random: a.env.random)
    let words = try keys.words()
    let registered = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: keys)
    await #expect(throws: CeremonyError.self) {
      _ = try await AccountCreation.bootstrapPasskey(a.env, registered: registered, keys: keys)
    }
    try await expectFinishesWithTheServersWriter(a, signup.userID, words)
  }

  @Test("a lost answer to the replacement phrase's bootstrap: the unlock finishes with the writer the server took")
  func lostReplacementBootstrapAnswerKeepsItsWriter() async throws {
    let w = World()
    let a = Phone(transport: LoseBootstrapAnswer(inner: w.server), clock: w.clock, seed: "a")
    let signup = try await signedUp(w, a)
    let first = try NewAccountKeys.generate(random: a.env.random)
    _ = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: first)
    first.wipe()
    let fresh = try NewAccountKeys.generate(random: a.env.random)
    let words = try fresh.words()
    await #expect(throws: CeremonyError.self) {
      _ = try await AccountCreation.bootstrapInterrupted(a.env, keys: fresh)
    }
    try await expectFinishesWithTheServersWriter(a, signup.userID, words)
  }

  func expectAddressStop(_ error: CeremonyError) {
    guard case .integrityAlarm(let what) = error, what == "address differs after bootstrap" else {
      Issue.record("not the address alarm: \(error)")
      return
    }
  }

  func expectUnlockStopped(_ a: Phone, _ user: UserID, _ words: [String]) async throws {
    let body = try await Enrolment.unlockWithPhrase(a.env, userID: user, typed: words.joined(separator: " "))
    defer { body.wipe() }
    do {
      _ = try await Enrolment.enrolWriter(a.env, userID: user, body: body, emailNorm: nil, serverSalt: nil)
      Issue.record("enrolled despite a different address")
    } catch {
      expectAddressStop(error)
    }
    #expect(a.binding == nil)
    #expect(Boot.decide(Boot.gather(a.env)) == .onboardingKeys)
  }

  func stoppedPasswordSignup(_ w: World, _ a: Phone, reported: String?) async throws -> (Signup, [String]) {
    let signup = try await signedUp(w, a)
    w.server.misreportEmail(user: signup.userID, reported)
    let keys = try NewAccountKeys.generate(random: a.env.random)
    let words = try keys.words()
    do {
      _ = try await AccountCreation.createWithPassword(a.env, signup: signup, password: password, keys: keys)
      Issue.record("created despite a different address")
    } catch {
      expectAddressStop(error)
    }
    return (signup, words)
  }

  @Test("a different address stays a stop after a relaunch: the phrase opens nothing here", arguments: ["someone@example.com", nil] as [String?])
  func passwordSignupStaysStopped(reported: String?) async throws {
    let w = World()
    let a = w.phone("a")
    let (signup, words) = try await stoppedPasswordSignup(w, a, reported: reported)
    try await expectUnlockStopped(a, signup.userID, words)
  }

  @Test("a passkey signup with a different address stays stopped after a relaunch")
  func passkeySignupStaysStopped() async throws {
    let w = World()
    let a = w.phone("a")
    let signup = try await signedUp(w, a)
    w.server.misreportEmail(user: signup.userID, "someone@example.com")
    let keys = try NewAccountKeys.generate(random: a.env.random)
    let words = try keys.words()
    let registered = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: keys)
    do {
      _ = try await AccountCreation.bootstrapPasskey(a.env, registered: registered, keys: keys)
      Issue.record("created despite a different address")
    } catch {
      expectAddressStop(error)
    }
    try await expectUnlockStopped(a, signup.userID, words)
  }

  @Test("the stop ends when the server reports the address the person signed up with, with the same writer")
  func stopEndsWhenTheAddressIsRight() async throws {
    let w = World()
    let a = w.phone("a")
    let (signup, words) = try await stoppedPasswordSignup(w, a, reported: "someone@example.com")
    try await expectUnlockStopped(a, signup.userID, words)
    w.server.misreportEmail(user: signup.userID, "Maya@Example.com")
    try await expectFinishesWithTheServersWriter(a, signup.userID, words)
    #expect(a.binding?.email_norm == "maya@example.com")
  }

  @Test("a signup that finished keeps only the session's usual keys")
  func aFinishedSignupForgetsItsAddress() async throws {
    let w = World()
    let a = w.phone("a")
    _ = try await w.passwordAccount(a)
    let raw = try #require(try a.keychain.read(.session(apiHost: "api.hasala.app")))
    let keys = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any]).keys
    #expect(Set(keys) == ["token", "user_id", "pending_logout", "expires_at", "tag"])
  }

  @Test("a stopped signup keeps its address until the comparison passes")
  func aStoppedSignupKeepsItsAddress() async throws {
    let w = World()
    let a = w.phone("a")
    let (signup, words) = try await stoppedPasswordSignup(w, a, reported: "someone@example.com")
    #expect(try a.env.secrets.session()?.signup_email_norm == "maya@example.com")
    w.server.misreportEmail(user: signup.userID, "maya@example.com")
    try await expectFinishesWithTheServersWriter(a, signup.userID, words)
    #expect(try a.env.secrets.session()?.signup_email_norm == nil)
  }

  @Test("the replacement phrase stops before it is published when the address is not the one typed at signup")
  func replacementPhraseComparesTheTypedAddress() async throws {
    let w = World()
    let a = w.phone("a")
    let signup = try await signedUp(w, a)
    let first = try NewAccountKeys.generate(random: a.env.random)
    _ = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: first)
    first.wipe()
    w.server.misreportEmail(user: signup.userID, "someone@example.com")
    let fresh = try NewAccountKeys.generate(random: a.env.random)
    do {
      _ = try await AccountCreation.bootstrapInterrupted(a.env, keys: fresh)
      Issue.record("published despite a different address")
    } catch {
      guard case .integrityAlarm("address differs from signup") = error else {
        Issue.record("not the address alarm: \(error)")
        return
      }
    }
    let token = try #require(try a.env.secrets.session()).token
    #expect(try await a.env.client.account(bearer: token).has_keys == false)
    #expect(a.binding == nil)
    w.server.misreportEmail(user: signup.userID, "maya@example.com")
    let account = try await AccountCreation.bootstrapInterrupted(a.env, keys: fresh)
    #expect(a.binding?.writer_id == account.writerID.string)
    #expect(try a.env.secrets.session()?.signup_email_norm == nil)
  }

  @Test("a new sign-in replaces the session, and with it the address of the stopped signup")
  func aNewSignInEndsTheComparison() async throws {
    let w = World()
    let a = w.phone("a")
    let (signup, words) = try await stoppedPasswordSignup(w, a, reported: "someone@example.com")
    let r = try await AccountSignIn.withPassword(a.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(a.env, userID: signup.userID, typed: words.joined(separator: " "))
    defer { body.wipe() }
    _ = try await Enrolment.enrolWriter(
      a.env, userID: signup.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    #expect(a.binding?.email_norm == "maya@example.com")
  }

  func stoppedPasskeySignup(_ w: World, _ a: Phone) async throws -> Signup {
    let signup = try await signedUp(w, a)
    w.server.misreportEmail(user: signup.userID, "someone@example.com")
    let keys = try NewAccountKeys.generate(random: a.env.random)
    let registered = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: keys)
    do {
      _ = try await AccountCreation.bootstrapPasskey(a.env, registered: registered, keys: keys)
      Issue.record("created despite a different address")
    } catch {
      expectAddressStop(error)
    }
    return signup
  }

  func prfBody(_ a: Phone, _ user: UserID, _ r: SignInResult) async throws -> KeyBody {
    let assertion = try #require(r.assertion)
    return try await Enrolment.unlockWithPRF(
      a.env, userID: user, credentialID: assertion.credentialID, prf: assertion.prfFirst)
  }

  @Test("the passkey unlock after a relaunch stays stopped while the server reports another address", arguments: [true, false])
  func passkeyUnlockStaysStopped(replacingHeld: Bool) async throws {
    let w = World()
    let a = w.phone("a")
    let signup = try await stoppedPasskeySignup(w, a)
    let r =
      replacingHeld
      ? try await AccountSignIn.replacingHeldSession(a.env, wantPRF: true)
      : try await AccountSignIn.withPasskey(a.env, bound: nil, wantPRF: true)
    #expect(try a.env.secrets.session()?.signup_email_norm == "maya@example.com")
    let body = try await prfBody(a, signup.userID, r)
    defer { body.wipe() }
    do {
      _ = try await Enrolment.enrolWriter(a.env, userID: signup.userID, body: body, emailNorm: nil, serverSalt: nil)
      Issue.record("enrolled despite a different address")
    } catch {
      expectAddressStop(error)
    }
    #expect(a.binding == nil)
    #expect(Boot.decide(Boot.gather(a.env)) == .onboardingKeys)
    #expect(try a.env.secrets.session()?.signup_email_norm == "maya@example.com")
  }

  @Test("the passkey unlock finishes with the same writer once the server reports the address the person signed up with")
  func passkeyUnlockEndsTheStop() async throws {
    let w = World()
    let a = w.phone("a")
    let signup = try await stoppedPasskeySignup(w, a)
    let token = try #require(try a.env.secrets.session()).token
    let writer = try #require(try await a.env.client.session(bearer: token).writer_id)
    w.server.misreportEmail(user: signup.userID, "maya@example.com")
    let r = try await AccountSignIn.replacingHeldSession(a.env, wantPRF: true)
    let body = try await prfBody(a, signup.userID, r)
    defer { body.wipe() }
    let enrolled = try await Enrolment.enrolWriter(
      a.env, userID: signup.userID, body: body, emailNorm: nil, serverSalt: nil)
    #expect(enrolled.writerID.string == writer)
    #expect(a.binding?.email_norm == "maya@example.com")
    #expect(try a.env.secrets.session()?.signup_email_norm == nil)
  }

  @Test("the replacement phrase after a passkey sign-in still stops on a different address")
  func replacementPhraseComparesAfterAPasskeySignIn() async throws {
    let w = World()
    let a = w.phone("a")
    let signup = try await signedUp(w, a)
    let first = try NewAccountKeys.generate(random: a.env.random)
    _ = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: first)
    first.wipe()
    w.server.misreportEmail(user: signup.userID, "someone@example.com")
    _ = try await AccountSignIn.replacingHeldSession(a.env, wantPRF: true)
    let fresh = try NewAccountKeys.generate(random: a.env.random)
    do {
      _ = try await AccountCreation.bootstrapInterrupted(a.env, keys: fresh)
      Issue.record("published despite a different address")
    } catch {
      guard case .integrityAlarm("address differs from signup") = error else {
        Issue.record("not the address alarm: \(error)")
        return
      }
    }
    #expect(a.binding == nil)
  }

  @Test("a passkey sign-in to another account does not take the stopped signup's address")
  func anotherAccountsSignInDropsTheAddress() async throws {
    let w = World()
    let shared = SoftPasskey()
    let a = w.phone("a", passkeys: shared)
    _ = try await stoppedPasskeySignup(w, a)
    w.server.addInvite(invite)
    let c = w.phone("c", passkeys: shared)
    let other = try await AccountCreation.beginSignup(
      c.env, inviteCode: invite, email: "noor@example.com", displayName: "Noor", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(c.env, other, code: try #require(w.server.lastCode))
    let keys = try NewAccountKeys.generate(random: c.env.random)
    let registered = try await AccountCreation.registerPasskey(c.env, signup: other, keys: keys)
    _ = try await AccountCreation.bootstrapPasskey(c.env, registered: registered, keys: keys)
    let r = try await AccountSignIn.replacingHeldSession(a.env, wantPRF: true)
    #expect(r.userID == other.userID)
    #expect(try a.env.secrets.session()?.signup_email_norm == nil)
  }

  @Test("a passkey sign-in after a sign-out that could not reach the server does not take the address")
  func aSignedOutSessionDropsTheAddress() async throws {
    let w = World()
    let a = w.phone("a")
    _ = try await stoppedPasskeySignup(w, a)
    var held = try #require(try a.env.secrets.session())
    held.pending_logout = true
    try a.env.secrets.writeSession(held)
    _ = try await AccountSignIn.withPasskey(a.env, bound: nil, wantPRF: true)
    #expect(try a.env.secrets.session()?.signup_email_norm == nil)
  }

  @Test("a session saved by an earlier build still decodes, and a record with the address round-trips")
  func sessionRecordFormat() throws {
    let old = #"{"expires_at":42,"pending_logout":false,"tag":"00","token":"t","user_id":"u"}"#
    let decoded = try JSONDecoder().decode(SessionRecord.self, from: Data(old.utf8))
    #expect(decoded.signup_email_norm == nil)
    let m = MemorySecretStore()
    let s = Secrets(store: m, apiHost: "api.hasala.app")
    var held = decoded
    held.signup_email_norm = "maya@example.com"
    try s.writeSession(held)
    #expect(try s.session() == held)
  }
}

final class LoseBootstrapAnswer: Transport, @unchecked Sendable {
  let inner: any Transport
  private let lock = NSLock()
  private var armed = true

  init(inner: any Transport) { self.inner = inner }

  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    let response = try await inner.send(request)
    let lose = request.path.hasSuffix("/account/bootstrap") && lock.withLock { () -> Bool in
      defer { armed = false }
      return armed
    }
    if lose { throw .offline(.networkConnectionLost) }
    return response
  }
}
