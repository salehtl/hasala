import CoreAuth
import CoreCrypto
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
