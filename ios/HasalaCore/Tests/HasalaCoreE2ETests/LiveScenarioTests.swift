// The Lane A scenarios against a real hasalad (spec 04 §19.1 T4), run by
// ios/scripts/e2e-hasalad.sh with a throwaway Postgres:
//
//   LiveSampleSeedTests     A loads the sample seed and uploads; B pulls and
//                           projects Maya's month, bills, review, trip and card
//   LiveGmailToReplayTests  FakeGmail alerts → the real MailboxEngine on A (stub
//                           link server and step-up) → the real Outbox and
//                           SyncEngine → hasalad → B pulls, folds and projects
//
// The account comes the way LiveHasaladTests' does: seeded in Postgres until
// this base mounts the signup and sign-in routes (#43-#47, server PR #22), then
// the REAL bootstrap (#23, #18) on A, and on B the REAL phrase unlock and
// writer registration (#17, #23, #24) behind a seeded session.
import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreTestSupport
import Foundation
import Testing

@testable import CoreSync

extension Live {
  /// Two enrolled iPhones of one fresh account, both on `clock`.
  static func twoRuntimes(clock: FakeClock) async throws -> (Runtime, Runtime) {
    let random = SystemRandom()
    let user = try #require(UserID(try random.uuidV4()))
    let email = "e2e-\(Hex.encode(try random.bytes(4)))@example.com"
    func phone(_ name: String) -> Phone {
      Phone(transport: URLSessionTransport(baseURL: url!, clientHeader: "ios/0.0.0/1"), clock: clock, seed: "\(name)-\(user.string)")
    }

    let a = phone("live-a")
    let keys = try NewAccountKeys.generate(random: random)
    let words = try keys.words()
    let attestation = try random.bytes(64)
    try seedUser(user, email: email, aak: try keys.authorityPublicKey(), attestationHash: sha256(attestation), random: random)
    try signIn(a, user: user)
    let bearer = try #require(try a.env.secrets.session()).token
    let device = try await NewDevice.mint(a.env, userID: user)
    let challenge = try await a.env.client.writerChallenge(bearer: bearer)
    let (body, _) = try AccountCreation.buildBootstrap(
      a.env, userID: user, emailNorm: email, keys: keys, device: device, authKind: .passkey, authHash: sha256(attestation),
      prfWrap: nil, nonce: try Base64.decode(challenge.nonce))
    _ = try await a.env.client.bootstrap(body, bearer: bearer)
    let accountA = try await Enrolment.persist(
      a.env, userID: user, device: device, epochKey: try keys.body.epochKey1(userID: user), emailNorm: email,
      serverSalt: Data(count: 32), displayName: "E2E", authorityPublicKey: try keys.authorityPublicKey())

    let b = phone("live-b")
    try signIn(b, user: user)
    let bodyB = try await Enrolment.unlockWithPhrase(b.env, userID: user, typed: words.joined(separator: " "))
    let accountB = try await Enrolment.enrolWriter(
      b.env, userID: user, body: bodyB, emailNorm: email, serverSalt: Data(count: 32), displayName: "E2E")

    let ra = try Runtime(Enrolment.context(a.env, account: accountA))
    let rb = try Runtime(Enrolment.context(b.env, account: accountB))
    try await ra.observer.open()
    try await rb.observer.open()
    return (ra, rb)
  }
}

@Suite("LiveSampleSeedTests", .enabled(if: Live.enabled), .serialized)
struct LiveSampleSeedTests {
  @Test("sample data loaded on A reaches B through hasalad")
  func sample() async throws {
    let (a, b) = try await Live.twoRuntimes(clock: FakeClock(ms: Scenarios.anchor))
    try await Scenarios.sampleOnSecondDevice(a, b) {
      let bearer = try #require(try a.context.secrets.session()).token
      let live = try await a.context.client.account(bearer: bearer)
      guard live.review_account != nil else {
        // This base's hasalad predates the review flag (server #22, `users.review_account`):
        // its #40 omits the field, which the gate refuses (checked above). Stand in for
        // `account review <uuid> on` with the live answer plus the flag.
        return AccountInfo(
          user_id: live.user_id, status: live.status, has_keys: live.has_keys, email: live.email,
          display_name: live.display_name, has_password: live.has_password, password_salt: live.password_salt,
          has_passkey: live.has_passkey, frozen: live.frozen, restricted: live.restricted, review_account: true)
      }
      _ = try Live.sql("UPDATE users SET review_account = true WHERE id = '\(a.context.userID.string)'")
      return try await a.context.client.account(bearer: bearer)
    }
  }
}

@Suite("LiveGmailToReplayTests", .enabled(if: Live.enabled), .serialized)
struct LiveGmailToReplayTests {
  @Test("Gmail alerts read on A reach B through hasalad")
  func gmail() async throws {
    let clock = FakeClock(ms: Scenarios.anchor)
    let (a, b) = try await Live.twoRuntimes(clock: clock)
    try await Scenarios.gmailToReplay(a, b, clock: clock)
  }
}
