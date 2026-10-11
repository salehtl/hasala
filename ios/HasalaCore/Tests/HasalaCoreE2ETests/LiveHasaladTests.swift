// T4 against a real hasalad (spec 04 §19.1): runs only when HASALA_E2E_URL
// names a local server (ios/scripts/e2e-hasalad.sh starts one on 127.0.0.1
// with a throwaway Postgres).
//
// Until the server's signup and sign-in routes land (server/accounts-auth),
// the account and its sessions are seeded straight into Postgres
// (HASALA_E2E_PSQL + HASALA_E2E_DSN): a user whose `authority_pubkey_pending`
// is this test's AAK and whose oldest credential carries a known
// `attestation_sha256`, so the REAL bootstrap path (#23, #18 with auth_kind 1)
// runs unchanged. TODO(WS-11): replace the seeding with C1-P over #43–#45
// once those routes exist, and add the passkey ceremonies with SoftPasskey.
import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreTestSupport
import Foundation
import Testing

@testable import CoreSync

enum Live {
  static let env = ProcessInfo.processInfo.environment
  static var url: URL? { env["HASALA_E2E_URL"].flatMap(URL.init(string:)) }
  static var enabled: Bool { url != nil && env["HASALA_E2E_PSQL"] != nil && env["HASALA_E2E_DSN"] != nil }

  static func sql(_ statement: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: env["HASALA_E2E_PSQL"]!)
    p.arguments = [env["HASALA_E2E_DSN"]!, "-v", "ON_ERROR_STOP=1", "-At", "-c", statement]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard p.terminationStatus == 0 else { throw LiveError.sql(text) }
    return text
  }

  enum LiveError: Error { case sql(String) }

  static func hex(_ d: Data) -> String { "'\\x" + Hex.encode(d) + "'" }

  /// A user awaiting bootstrap with `aak`, and its credential's attestation hash.
  static func seedUser(_ user: UserID, email: String, aak: Data, attestationHash: Data, random: some RandomSource) throws {
    _ = try sql(
      """
      BEGIN;
      INSERT INTO users (id, idp, idp_sub_hash, email_norm, authority_pubkey_pending)
        VALUES ('\(user.string)', 'passkey', \(hex(try random.bytes(32))), '\(email)', \(hex(aak)));
      INSERT INTO webauthn_credentials (credential_id, user_id, user_handle, public_key, backup_eligible, backup_state,
                                        created_at, attestation_sha256)
        VALUES (\(hex(try random.bytes(16))), '\(user.string)', \(hex(try random.bytes(32))), '\\x00', false, false,
                now(), \(hex(attestationHash)));
      INSERT INTO oplog_seq (user_id) VALUES ('\(user.string)');
      INSERT INTO account_usage (user_id, resource, amount) VALUES ('\(user.string)', 'oplog_hot_bytes', 0);
      COMMIT;
      """)
  }

  /// A fresh, unbound session for `user`; returns its token.
  static func seedSession(_ user: UserID, random: some RandomSource) throws -> String {
    let token = Base64.encodeURL(try random.bytes(32))
    _ = try sql(
      """
      INSERT INTO sessions (token_hash, user_id, expires_at)
        VALUES (\(hex(sha256(Data(token.utf8)))), '\(user.string)', now() + interval '1 day');
      """)
    return token
  }

  static func phone(_ seed: String) -> Phone {
    Phone(transport: URLSessionTransport(baseURL: url!, clientHeader: "ios/0.0.0/1"), clock: FakeClock(), seed: seed)
  }

  static func signIn(_ phone: Phone, user: UserID) throws {
    let token = try seedSession(user, random: SystemRandom())
    try phone.env.secrets.writeSession(SessionRecord(token: token, userID: user.string, expiresAt: 4_000_000_000, tag: "0000000000000000"))
  }
}

/// Drops the answer of the first upload after forwarding it (a lost response).
final class LosingTransport: Transport, @unchecked Sendable {
  let inner: any Transport
  private let lock = NSLock()
  private var armed = true
  init(inner: any Transport) { self.inner = inner }
  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    let r = try await inner.send(request)
    if request.method == .post, request.path == "/api/v1/sync", lock.withLock({ defer { armed = false }; return armed }) {
      throw .offline(.networkConnectionLost)
    }
    return r
  }
}

@Suite("Live hasalad", .enabled(if: Live.enabled), .serialized)
struct LiveHasaladTests {
  @Test("bootstrap, a second writer, upload with signed heads, pull, replay of a lost answer, refusals")
  func everything() async throws {
    let random = SystemRandom()
    let user = try #require(UserID(try random.uuidV4()))
    let email = "e2e-\(Hex.encode(try random.bytes(4)))@example.com"

    // Phone A: the real bootstrap (#23, #18) on a seeded account.
    let a = Live.phone("live-a-\(user.string)")
    let keys = try NewAccountKeys.generate(random: random)
    let words = try keys.words()
    let attestation = try random.bytes(64)
    try Live.seedUser(user, email: email, aak: try keys.authorityPublicKey(), attestationHash: sha256(attestation), random: random)
    try Live.signIn(a, user: user)
    let bearer = try #require(try a.env.secrets.session()).token
    let device = try await NewDevice.mint(a.env, userID: user)
    let challenge = try await a.env.client.writerChallenge(bearer: bearer)
    let (body, _) = try AccountCreation.buildBootstrap(
      a.env, userID: user, emailNorm: email, keys: keys, device: device, authKind: .passkey,
      authHash: sha256(attestation), prfWrap: nil, nonce: try Base64.decode(challenge.nonce))
    let boot = try await a.env.client.bootstrap(body, bearer: bearer)
    #expect(boot.writer_id == device.writerID.string && boot.current_epoch == 1)
    let k1 = try keys.body.epochKey1(userID: user)
    let accountA = try await Enrolment.persist(
      a.env, userID: user, device: device, epochKey: k1, emailNorm: email, serverSalt: Data(count: 32),
      displayName: "E2E", authorityPublicKey: try keys.authorityPublicKey())
    let k = try await a.env.client.keys(bearer: bearer)
    #expect(k.authority_pubkey == body.authority_pubkey && k.recovery_wrap == body.recovery_wrap)
    let ctxA = Enrolment.context(a.env, account: accountA)

    // Phone B: unlock with the twelve words and register a second writer (#24).
    let b = Live.phone("live-b-\(user.string)")
    try Live.signIn(b, user: user)
    let bodyB = try await Enrolment.unlockWithPhrase(b.env, userID: user, typed: words.joined(separator: " "))
    let accountB = try await Enrolment.enrolWriter(
      b.env, userID: user, body: bodyB, emailNorm: email, serverSalt: Data(count: 32), displayName: "E2E")
    let ctxB = Enrolment.context(b.env, account: accountB)

    // A uploads (sealed, head-signed); B pulls and opens.
    try enqueue(ctxA, (1...3).map { op($0) })
    let outA = await SyncEngine(context: ctxA).run(.authored)
    #expect(outA.stop == nil && outA.pushed.opsAcknowledged == 3)
    let outB = await SyncEngine(context: ctxB).run(.launch)
    #expect(outB.stop == nil)
    #expect(try storedOps(ctxB).map(\.opID) == (1...3).map { op($0).opID })

    // A lost answer: the resend is a byte-identical replay with the same head_sig.
    let losing = SyncContext(
      userID: ctxA.userID, writerID: ctxA.writerID, store: ctxA.store, secrets: ctxA.secrets,
      client: AuthClient(transport: LosingTransport(inner: URLSessionTransport(baseURL: Live.url!, clientHeader: "ios/0.0.0/1"))),
      clock: ctxA.clock, random: ctxA.random)
    try enqueue(ctxA, [op(10), op(11)])
    #expect(await SyncEngine(context: losing).run(.authored).stop == .offline)
    #expect(try ctxA.store.inflight().count == 1)
    #expect(await SyncEngine(context: losing).run(.foreground).stop == nil)
    #expect(try ctxA.store.inflight().isEmpty && ctxA.store.pendingCount() == 0)

    // B sees exactly five ops, once each.
    #expect(await SyncEngine(context: ctxB).run(.foreground).stop == nil)
    #expect(try storedOps(ctxB).count == 5)

    // A head_sig that is not the writer's: 400 bad_signature → hard_stop + alarm.
    try enqueue(ctxA, [op(20)])
    let batch = try Pusher.buildBatch(try ctxA.store.pendingOps(), ctx: ctxA)
    var forged = batch
    let last = forged.removeLast()
    forged.append(
      InflightBlob(
        counter: last.counter, batchID: last.batchID, prevHash: last.prevHash, blobHash: last.blobHash,
        sizeBucket: last.sizeBucket, blob: last.blob, opIDs: last.opIDs, headSig: Data(repeating: 1, count: 64),
        createdAt: last.createdAt))
    try ctxA.store.persistBatch(forged)
    let engine = SyncEngine(context: ctxA)
    _ = await engine.run(.authored)
    #expect(await engine.status.latch == .hardStop)
    #expect(await engine.status.integrityAlarms == 1)
  }
}
