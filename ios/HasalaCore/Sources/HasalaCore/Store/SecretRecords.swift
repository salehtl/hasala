// The value formats of spec 04 §4.4's Keychain items, and typed access to them.
//
//   .session        {"token","user_id","pending_logout","expires_at":<epoch s>,"tag":"<16 hex>"}
//   .accountBinding {"user_id","writer_id","api_base","key_epoch","email_norm","s_srv","display_name"}
//   .epochKey       32 bytes K_e
//   .writerKey      [alg u8][key bytes]; alg 0x01 = Ed25519, 32-byte seed
//
// No secret beyond these bytes is ever stored (01 §11.1 "Never at rest").
import CorePrimitives
import CoreWire
import Foundation

/// `.session(apiHost)` (§4.4).
public struct SessionRecord: Codable, Sendable, Hashable {
  public var token: String
  public var user_id: String
  /// Set when sign-out could not reach the server (§4.7 row 1).
  public var pending_logout: Bool
  /// The 90-day cap, epoch seconds.
  public var expires_at: Int64
  /// 8 random bytes in hex, minted per new session; local only (§6.4 notice).
  public var tag: String

  public init(token: String, userID: String, expiresAt: Int64, tag: String, pendingLogout: Bool = false) {
    self.token = token
    user_id = userID
    self.expires_at = expiresAt
    self.tag = tag
    pending_logout = pendingLogout
  }

  /// A record for a session a sign-in just minted, with a fresh tag.
  public static func minted(
    token: String, userID: String, expiresAt: Int64, random: some RandomSource
  ) throws(PrimitivesError) -> SessionRecord {
    SessionRecord(token: token, userID: userID, expiresAt: expiresAt, tag: Hex.encode(try random.bytes(8)))
  }
}

/// `.accountBinding` (§4.4): ids and the account's salt; no secrets.
public struct AccountBinding: Codable, Sendable, Hashable {
  public var user_id: String
  public var writer_id: String
  public var api_base: String
  public var key_epoch: UInt32
  public var email_norm: String
  /// `s_srv`, b64 32.
  public var s_srv: String
  public var display_name: String?

  public init(
    userID: UserID, writerID: WriterID, apiBase: String, keyEpoch: UInt32, emailNorm: String, serverSalt: Data,
    displayName: String?
  ) {
    user_id = userID.string
    writer_id = writerID.string
    api_base = apiBase
    key_epoch = keyEpoch
    email_norm = emailNorm
    s_srv = Base64.encode(serverSalt)
    display_name = displayName
  }

  public var userID: UserID? { UserID(user_id) }
  public var writerID: WriterID? { WriterID(writer_id) }
  public var serverSalt: Data? { try? Base64.decode(s_srv) }
}

/// Typed reads and writes over a `SecretStore` for one API host.
public struct Secrets: Sendable {
  public let store: any SecretStore
  public let apiHost: String

  public init(store: any SecretStore, apiHost: String) {
    self.store = store
    self.apiHost = apiHost
  }

  static func decode<T: Decodable>(_ d: Data) throws(SecretStoreError) -> T {
    do { return try JSONDecoder().decode(T.self, from: d) } catch { throw .failed(status: -1) }
  }

  static func encode(_ v: some Encodable) throws(SecretStoreError) -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    do { return try e.encode(v) } catch { throw .failed(status: -1) }
  }

  // MARK: Session

  public func session() throws(SecretStoreError) -> SessionRecord? {
    guard let d = try store.read(.session(apiHost: apiHost)) else { return nil }
    return try Self.decode(d)
  }

  public func writeSession(_ s: SessionRecord) throws(SecretStoreError) {
    try store.write(.session(apiHost: apiHost), try Self.encode(s))
  }

  public func deleteSession() throws(SecretStoreError) { try store.delete(.session(apiHost: apiHost)) }

  // MARK: Binding

  public func binding() throws(SecretStoreError) -> AccountBinding? {
    guard let d = try store.read(.accountBinding) else { return nil }
    return try Self.decode(d)
  }

  public func writeBinding(_ b: AccountBinding) throws(SecretStoreError) {
    try store.write(.accountBinding, try Self.encode(b))
  }

  // MARK: Keys

  /// `K_e` for `epoch`, or `nil` when this device has not unlocked it.
  public func epochKey(userID: UserID, epoch: UInt32) throws(SecretStoreError) -> Data? {
    try store.read(.epochKey(userID: userID, epoch: epoch))
  }

  public func writeEpochKey(_ key: some ContiguousBytes, userID: UserID, epoch: UInt32) throws(SecretStoreError) {
    try store.write(.epochKey(userID: userID, epoch: epoch), key.withUnsafeBytes { Data($0) })
  }

  /// The DWK seed (alg `0x01`, Ed25519), or `nil` when absent.
  public func writerSeed(userID: UserID, writerID: WriterID) throws(SecretStoreError) -> SecureBytes? {
    guard let d = try store.read(.writerKey(userID: userID, writerID: writerID)) else { return nil }
    guard d.count == 33, d.first == 0x01 else { throw .failed(status: -2) }
    return SecureBytes(copying: d.dropFirst())
  }

  public func writeWriterSeed(_ seed: some ContiguousBytes, userID: UserID, writerID: WriterID)
    throws(SecretStoreError)
  {
    var v = Data([0x01])
    seed.withUnsafeBytes { v.append(contentsOf: $0) }
    defer { v.resetBytes(in: 0..<v.count) }
    guard v.count == 33 else { throw .failed(status: -2) }
    try store.write(.writerKey(userID: userID, writerID: writerID), v)
  }

  /// Deletes every item of an account (§4.7 row 2): session, binding, keys,
  /// the DAK handle and the mail tokens. Absent items are fine.
  public func wipeAccount(userID: UserID, writerID: WriterID?, epochs: ClosedRange<UInt32> = 1...1)
    throws(SecretStoreError)
  {
    try store.delete(.session(apiHost: apiHost))
    try store.delete(.accountBinding)
    for e in epochs { try store.delete(.epochKey(userID: userID, epoch: e)) }
    if let w = writerID {
      try store.delete(.writerKey(userID: userID, writerID: w))
      try store.delete(.approvalKey(userID: userID, writerID: w))
    }
    for p in MailSecretProvider.allCases { try store.delete(.mailRefresh(provider: p, userID: userID)) }
    try store.delete(.outlookClientState(userID: userID))
    try store.delete(.textKeySecret)
    try store.delete(.readerWordKey)
  }
}
