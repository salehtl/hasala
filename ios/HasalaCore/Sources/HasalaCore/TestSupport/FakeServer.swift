// An in-process hasalad for the core's tests (spec 04 §2.2 `FakeServer`):
// the routes of `02` §7 that the sync and auth clients call, with `02`'s
// paths, JSON names, error codes and check order, and the checks that make the
// server blind (§11.1: framing, LooksSealed, the AAD position, the chain, the
// signed head; nothing else about a blob is read).
//
// Faithful where the client can observe it; simplified where it cannot: the
// password verifier is compared as SHA256(S) (the real server runs PBKDF2 under
// a pepper), there are no limiters or emails (a code is readable through
// `lastCode`), and WebAuthn checks only what go-webauthn's outcome depends on
// for these tests (type, challenge, origin, RP ID hash, UP/UV, the ES256
// signature, the sign count).
//
// Tamper switches (§19.1 T3) change what the next answers carry.
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreWire
import CryptoKit
import Foundation
import Synchronization

public final class FakeServer: Transport, @unchecked Sendable {
  public static let rpID = "hasala.app"
  public static let origin = "https://hasala.app"

  // MARK: State

  struct Credential {
    let id: Data
    let userID: UserID
    let publicKey: P256.Signing.PublicKey
    let attestationHash: Data
    var signCount: UInt32
  }

  struct Writer {
    let id: WriterID
    let dwk: Data
    let dak: Data
    var revoked: (counter: Int64, head: Data)?
    let registeredAt: String
  }

  struct KeyHistoryRow {
    let id: Int64
    let writerID: String
    let pubkey: Data
    let dak: Data?
    let event: String
    let authorizedBy: String
    let authorizer: String?
    let finalCounter: Int64?
    let finalHead: Data?
    let nonce: Data
    let signature: Data
  }

  struct StoredRow {
    let seq: Int64
    let writerID: String
    let counter: Int64
    let sizeBucket: Int
    let blobHash: Data
    let prevHash: Data
    var blob: Data
    var headSig: Data?
  }

  struct User {
    let id: UserID
    var emailNorm: String
    var displayName: String
    var passwordHash: Data?  // SHA256(S)
    var authorityPending: Data?
    var keys: KeysResponse?
    var phraseBox: Data?
    var wraps: [String: KeyWrapsResponse.Wrap] = [:]
    var writers: [String: Writer] = [:]
    var history: [KeyHistoryRow] = []
    var log: [StoredRow] = []
    var frozen = false
    var deleted = false
    /// `users.review_account` (02 #40; 07's reviewer invite).
    var review = false
  }

  struct Session {
    let userID: UserID
    var writerID: WriterID?
    var revoked = false
  }

  struct SignupCeremony {
    let id: String
    let userID: UserID
    let emailNorm: String
    let displayName: String
    let proven: Bool
    var verified: Bool
    let code: String
    let nonce: Data
    var claimed = false
  }

  struct StepUpChallenge {
    let userID: UserID
    let token: String
    let action: String
    let paramsHash: Data
    let kind: String
    var used = false
  }

  struct State {
    var invites: [String: String?] = [:]  // code → addressed email_norm
    var signups: [String: SignupCeremony] = [:]
    var users: [UserID: User] = [:]
    var credentials: [Data: Credential] = [:]
    var sessions: [String: Session] = [:]
    var registerCeremonies: [String: (signup: String, aak: Data, challenge: Data)] = [:]
    var loginCeremonies: [String: Data] = [:]
    var passwordCeremonies: [String: (email: String, nonce: Data)] = [:]
    var writerNonces: [Data: UserID] = [:]
    var stepUps: [Data: StepUpChallenge] = [:]
    var seq: Int64 = 0
    var historyID: Int64 = 0
    var lastCode: String?
    // tamper switches
    var cannedRefusals: [String: [(Int, String, String)]] = [:]
    var loseNextUploadResponse = false
    var partialApplyNextUpload: Int?
    var dropHeadSigs = false
    var flipBlobByteAtSeq: Int64?
    var logGeneration: Int64 = 1
    var minIOSBuild = 0
    var uploads = 0
    var pullLimitOverride: Int?
    /// `GET /account` answers this address instead of the stored one.
    var misreportedEmail: [UserID: String?] = [:]
  }

  let state = Mutex(State())
  let secret: Data
  let random = SeededRandom(seed: "fake-server")

  public init(secret: String = "fake-server-secret") { self.secret = Data(secret.utf8) }

  // MARK: Test controls

  public func addInvite(_ code: String, addressedTo email: String? = nil) {
    state.withLock { $0.invites[code] = .some(email) }
  }

  /// The last email code the server "sent".
  public var lastCode: String? { state.withLock { $0.lastCode } }

  /// The next call to `route` (e.g. `"POST /api/v1/sync"`) answers this refusal.
  public func refuseNext(_ route: String, status: Int, code: String, detail: String = "") {
    state.withLock { $0.cannedRefusals[route, default: []].append((status, code, detail)) }
  }

  /// The next upload is applied, but its answer is lost (a transport error).
  public func loseNextUploadResponse() { state.withLock { $0.loseNextUploadResponse = true } }

  /// The next upload stores only its first `rows` rows; the client sees a
  /// transport error, and its resend then meets `409 conflict`.
  public func partiallyApplyNextUpload(rows: Int) { state.withLock { $0.partialApplyNextUpload = rows } }

  /// Pulls serve rows without `head_sig` (R2b must stop them).
  public func setDropHeadSigs(_ v: Bool) { state.withLock { $0.dropHeadSigs = v } }

  /// Pulls serve the row at `seq` with one blob byte flipped.
  public func flipBlobByte(atSeq seq: Int64?) { state.withLock { $0.flipBlobByteAtSeq = seq } }

  public func setLogGeneration(_ g: Int64) { state.withLock { $0.logGeneration = g } }

  public func setPullLimit(_ n: Int?) { state.withLock { $0.pullLimitOverride = n } }

  /// Revokes a writer server-side as if another device removed it.
  public func revoke(user: UserID, writer: WriterID) {
    state.withLock { s in
      let head = s.users[user]?.log.last(where: { $0.writerID == writer.string })
      s.users[user]?.writers[writer.string]?.revoked = (head?.counter ?? 0, head?.blobHash ?? Data(count: 32))
      for (t, sess) in s.sessions where sess.writerID == writer { s.sessions[t]?.revoked = true }
    }
  }

  /// `GET /account` answers `email` (nil: no address at all) for this user.
  public func misreportEmail(user: UserID, _ email: String?) {
    state.withLock { $0.misreportedEmail[user] = .some(email) }
  }

  /// A malicious server un-revokes a writer: the revocation entry leaves the
  /// key history (still a valid, signed history) and `GET /writers` shows the
  /// writer live again (spec 01 §10.13 says a device must refuse this).
  public func rollBackRevocation(user: UserID, writer: WriterID) {
    state.withLock { s in
      s.users[user]?.history.removeAll { $0.writerID == writer.string && $0.event == "revoked" }
      s.users[user]?.writers[writer.string]?.revoked = nil
    }
  }

  public func freeze(user: UserID) { state.withLock { $0.users[user]?.frozen = true } }

  /// Marks the account a review account (`account review <uuid> on`), or not.
  public func setReviewAccount(user: UserID, _ on: Bool) { state.withLock { $0.users[user]?.review = on } }

  public func storedRowCount(user: UserID) -> Int { state.withLock { $0.users[user]?.log.count ?? 0 } }

  public var uploadCount: Int { state.withLock { $0.uploads } }

  /// Writes a row directly into a user's log (a malicious server).
  public func injectRow(
    user: UserID, writerID: String, counter: Int64, prevHash: Data, blob: Data, headSig: Data?
  ) {
    state.withLock { s in
      s.seq += 1
      let h = Chain.hash(prev: Hash32(prevHash) ?? .zero, frame: blob).bytes
      s.users[user]?.log.append(
        StoredRow(
          seq: s.seq, writerID: writerID, counter: counter, sizeBucket: blob.count, blobHash: h, prevHash: prevHash,
          blob: blob, headSig: headSig))
    }
  }

  // MARK: Transport

  public func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    let path = String(request.path.split(separator: "?", maxSplits: 1).first ?? "")
    let route = "\(request.method.rawValue) \(path)"
    if let canned = state.withLock({ s -> (Int, String, String)? in
      guard var list = s.cannedRefusals[route], !list.isEmpty else { return nil }
      let first = list.removeFirst()
      s.cannedRefusals[route] = list
      return first
    }) {
      return Self.error(canned.0, canned.1, canned.2)
    }
    if route == "POST /api/v1/sync" {
      let (response, lose) = upload(request)
      if lose { throw .offline(.networkConnectionLost) }
      return response
    }
    return handle(request, route: route)
  }

  func handle(_ r: APIRequest, route: String) -> APIResponse {
    switch route {
    case "GET /api/v1/meta":
      let (g, m) = state.withLock { ($0.logGeneration, $0.minIOSBuild) }
      return Self.ok(
        MetaResponse(
          rp_id: Self.rpID, min_ios_build: m, gmail_watch_topic: nil, outlook_notification_url: nil,
          outlook_lifecycle_url: nil, log_generation: g, server_time: nil))
    case "POST /api/v1/auth/signup/begin": return signupBegin(r)
    case "POST /api/v1/auth/signup/verify": return signupVerify(r)
    case "POST /api/v1/auth/passkey/register/begin": return registerBegin(r)
    case "POST /api/v1/auth/passkey/register/finish": return registerFinish(r)
    case "POST /api/v1/auth/password/register": return passwordRegister(r)
    case "POST /api/v1/auth/passkey/login/begin": return loginBegin()
    case "POST /api/v1/auth/passkey/login/finish": return loginFinish(r)
    case "POST /api/v1/auth/password/login/begin": return passwordLoginBegin(r)
    case "POST /api/v1/auth/password/login/finish": return passwordLoginFinish(r)
    default: break
    }
    // Session routes.
    guard let token = r.bearer, let sess = state.withLock({ $0.sessions[token] }), !sess.revoked else {
      return Self.error(401, "unauthorized")
    }
    guard let user = state.withLock({ $0.users[sess.userID] }), !user.deleted else {
      return Self.error(410, "account_deleted")
    }
    if user.frozen, route != "GET /api/v1/account", route != "POST /api/v1/auth/logout" {
      return Self.error(403, "account_frozen")
    }
    switch route {
    case "GET /api/v1/auth/session":
      return Self.ok(
        SessionInfo(
          user_id: sess.userID.string, minted_by: nil, created_at: nil, expires_at: nil, idle_expires_at: nil,
          writer_id: sess.writerID?.string, credential_id: nil, restricted: user.frozen))
    case "POST /api/v1/auth/logout":
      state.withLock { $0.sessions[token]?.revoked = true }
      return APIResponse(status: 204)
    case "POST /api/v1/auth/logout-all": return logoutAll(r, token: token, sess: sess)
    case "POST /api/v1/auth/step-up/begin": return stepUpBegin(r, token: token, sess: sess)
    case "GET /api/v1/account":
      return Self.ok(
        AccountInfo(
          user_id: user.id.string, status: "active", has_keys: user.keys != nil,
          email: state.withLock { $0.misreportedEmail[user.id] } ?? user.emailNorm,
          display_name: user.displayName, has_password: user.passwordHash != nil,
          password_salt: Base64.encode(sSrv(user.emailNorm)),
          has_passkey: state.withLock { s in s.credentials.values.contains { $0.userID == user.id } }, frozen: user.frozen,
          restricted: user.frozen, review_account: user.review))
    case "GET /api/v1/keys":
      guard let k = user.keys else { return Self.error(404, "no_keys") }
      return Self.ok(k)
    case "GET /api/v1/keys/wraps":
      return Self.ok(KeyWrapsResponse(wraps: Array(user.wraps.values)))
    case "POST /api/v1/account/bootstrap": return bootstrap(r, token: token, sess: sess)
    case "POST /api/v1/writers/challenge":
      let n = nonce()
      state.withLock { $0.writerNonces[n] = sess.userID }
      return Self.ok(WriterChallengeResponse(nonce: Base64.encode(n), expires_at: nil))
    case "POST /api/v1/writers/register": return writerRegister(r, token: token, sess: sess)
    case "POST /api/v1/writers/revoke": return writerRevoke(r, token: token, sess: sess)
    case "DELETE /api/v1/account": return deleteAccount(r, token: token, sess: sess)
    case "GET /api/v1/writers":
      return Self.ok(
        WritersResponse(
          writers: user.writers.values.sorted { $0.id.string < $1.id.string }.map {
            .init(
              writer_id: $0.id.string, alg: "ed25519", pubkey: Base64.encode($0.dwk), dak_pubkey: Base64.encode($0.dak),
              revoked_at: $0.revoked == nil ? nil : "2026-10-11T00:00:00Z", current: $0.id == sess.writerID)
          }))
    case "GET /api/v1/key-history":
      return Self.ok(
        KeyHistoryResponse(
          entries: user.history.map {
            .init(
              id: FlexibleDecimal($0.id), writer_id: $0.writerID, alg: "ed25519", pubkey: Base64.encode($0.pubkey),
              dak_pubkey: $0.dak.map { Base64.encode($0) }, event: $0.event, authorized_by: $0.authorizedBy,
              authorizer_writer_id: $0.authorizer, final_counter: $0.finalCounter.map { FlexibleDecimal($0) },
              final_head: $0.finalHead.map { Base64.encode($0) }, nonce: Base64.encode($0.nonce),
              signature: Base64.encode($0.signature))
          }))
    case "GET /api/v1/sync": return pull(r, user: user)
    case "GET /api/v1/sync/hashes": return hashes(r, user: user)
    default:
      return Self.error(404, "not_found")
    }
  }

  // MARK: Helpers

  static func ok(_ v: some Encodable, status: Int = 200) -> APIResponse {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return APIResponse(
      status: status, headers: ["Content-Type": "application/json", "Hasala-Request-Id": "0123456789abcdef"],
      body: (try? e.encode(v)) ?? Data())
  }

  static func error(_ status: Int, _ code: String, _ detail: String = "") -> APIResponse {
    let body = #"{"error":"\#(code)","detail":"\#(detail)"}"#
    var headers = ["Hasala-Request-Id": "fedcba9876543210"]
    if status == 429 { headers["Retry-After"] = "7" }
    return APIResponse(status: status, headers: headers, body: Data(body.utf8))
  }

  static func decode<T: Decodable>(_ r: APIRequest, _ t: T.Type) -> T? {
    guard let b = r.body else { return nil }
    return try? JSONDecoder().decode(T.self, from: b)
  }

  func nonce() -> Data { (try? random.bytes(32)) ?? Data(count: 32) }

  func token() -> String { Base64.encodeURL(nonce()) }

  func sSrv(_ email: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(("s_srv|" + email).utf8), using: SymmetricKey(data: secret)))
  }

  func mintSession(_ user: UserID, writer: WriterID?) -> String {
    let t = token()
    state.withLock { $0.sessions[t] = Session(userID: user, writerID: writer) }
    return t
  }

  func grant(_ token: String, user: User, writer: WriterID?, status: Int = 200) -> APIResponse {
    Self.ok(
      SessionGrant(
        session_token: token, user_id: user.id.string, expires_at: "2027-01-09T00:00:00.123456789Z",
        writer_id: writer?.string, has_keys: user.keys != nil, restricted: user.frozen), status: status)
  }
}
