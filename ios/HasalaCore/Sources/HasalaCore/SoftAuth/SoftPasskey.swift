// A software platform authenticator for tests (spec 04 §19.3 `CoreSoftAuth`):
// ES256 credentials, `fmt: "none"` attestation, UV and UP set, and the
// deterministic PRF of spec 01 §12.1:
//
//   P = HMAC-SHA256(cred_secret, SHA256("WebAuthn PRF" ‖ 0x00 ‖ PRF_SALT))
//
// It produces the same raw structs as the app's AuthenticationServices adapter
// (`RawRegistration`, `RawAssertion`), byte-for-byte in the WebAuthn formats
// (CBOR attestation object, authenticator data, DER signature), so a server
// verifies them like a real platform credential.
//
// TODO(WS-11, §19.3): a line-by-line port of server/internal/authtest/softauth.go
// once that file exists on main; this one is written from the WebAuthn spec.
import CoreAuth
import CorePrimitives
import CryptoKit
import Foundation
import Synchronization

public final class SoftPasskey: PasskeyProvider {
  public struct Credential: Sendable {
    public let id: Data
    public let userHandle: Data
    /// The credential's P-256 private key (a software stand-in for the platform's).
    let signer: P256.Signing.PrivateKey
    let prfSecret: Data
    public var signCount: UInt32
  }

  public let rpID: String
  public let origin: String
  private let state = Mutex<[Credential]>([])
  private let uv = Mutex(true)
  private let failure = Mutex<PasskeyError?>(nil)
  private let prfSupported = Mutex(true)
  private let backup = Mutex<UInt8>(0)

  public init(rpID: String = "hasala.app", origin: String = "https://hasala.app") {
    self.rpID = rpID
    self.origin = origin
  }

  /// Clears the UV flag on the next ceremonies (a server must refuse them).
  public func setUserVerified(_ v: Bool) { uv.withLock { $0 = v } }
  /// Whether the authenticator evaluates PRF (an iCloud Keychain without it returns none).
  public func setPRFSupported(_ v: Bool) { prfSupported.withLock { $0 = v } }
  public func setBackup(eligible: Bool, backedUp: Bool) {
    backup.withLock { $0 = (eligible ? 0x08 : 0) | (backedUp ? 0x10 : 0) }
  }
  /// The next ceremony fails with `error`, once.
  public func failNext(_ error: PasskeyError) { failure.withLock { $0 = error } }

  public var credentials: [Credential] { state.withLock { $0 } }

  /// `P` for a credential and salt (01 §12.1).
  public static func prf(secret: Data, salt: Data) -> Data {
    let input = Data(SHA256.hash(data: Data("WebAuthn PRF".utf8) + [0] + salt))
    return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret)))
  }

  public func register(_ options: CreationOptions, prfSalt: Data?) async throws(PasskeyError) -> RawRegistration {
    if let f = takeFailure() { throw f }
    if options.rpID != rpID, !options.rpID.isEmpty { throw .failed("rp id") }
    let key = P256.Signing.PrivateKey()
    var id = Data(count: 16)
    var secret = Data(count: 32)
    _ = id.withUnsafeMutableBytes { SecRandomFill($0) }
    _ = secret.withUnsafeMutableBytes { SecRandomFill($0) }
    let cred = Credential(id: id, userHandle: options.userID, signer: key, prfSecret: secret, signCount: 0)
    if state.withLock({ creds in creds.contains { options.excludeCredentialIDs.contains($0.id) } }) {
      throw .failed("excluded credential")
    }
    state.withLock { $0.append(cred) }

    let clientData = Self.clientData(type: "webauthn.create", challenge: options.challenge, origin: origin)
    let pub = key.publicKey.x963Representation  // 04 ‖ X ‖ Y
    let cose = CBOR.map([
      (.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)),
      (.int(-2), .bytes(pub[1..<33])), (.int(-3), .bytes(pub[33..<65])),
    ]).encoded()
    var authData = rpIDHash()
    authData.append(flags(attested: true))
    authData.append(contentsOf: [0, 0, 0, 0])
    authData.append(Data(count: 16))  // AAGUID
    authData.append(contentsOf: [UInt8(id.count >> 8), UInt8(id.count & 0xff)])
    authData.append(id)
    authData.append(cose)
    let att = CBOR.map([
      (.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(authData)),
    ]).encoded()
    let p = (prfSalt != nil && prfSupported.withLock { $0 }) ? Self.prf(secret: secret, salt: prfSalt!) : nil
    return RawRegistration(
      credentialID: id, rawClientDataJSON: clientData, rawAttestationObject: att,
      prfFirst: p.map { SecureBytes(copying: $0) })
  }

  public func assert(challenge: Data, allowCredentialIDs: [Data], prfSalt: Data?) async throws(PasskeyError)
    -> RawAssertion
  {
    if let f = takeFailure() { throw f }
    let picked: Credential? = state.withLock { creds in
      guard let i = creds.lastIndex(where: { allowCredentialIDs.isEmpty || allowCredentialIDs.contains($0.id) }) else {
        return nil
      }
      creds[i].signCount += 1
      return creds[i]
    }
    guard let cred = picked else { throw .noCredential }
    let clientData = Self.clientData(type: "webauthn.get", challenge: challenge, origin: origin)
    var authData = rpIDHash()
    authData.append(flags(attested: false))
    let c = cred.signCount
    authData.append(contentsOf: [UInt8(c >> 24), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)])
    let signed = authData + Data(SHA256.hash(data: clientData))
    guard let sig = try? cred.signer.signature(for: signed) else { throw .failed("sign") }
    let p = (prfSalt != nil && prfSupported.withLock { $0 }) ? Self.prf(secret: cred.prfSecret, salt: prfSalt!) : nil
    return RawAssertion(
      credentialID: cred.id, rawClientDataJSON: clientData, authenticatorData: authData, signature: sig.derRepresentation,
      userHandle: cred.userHandle, prfFirst: p.map { SecureBytes(copying: $0) })
  }

  /// Forgets every credential (a new iPhone without iCloud Keychain).
  public func removeAll() { state.withLock { $0.removeAll() } }

  func rpIDHash() -> Data { Data(SHA256.hash(data: Data(rpID.utf8))) }

  func flags(attested: Bool) -> UInt8 {
    var f: UInt8 = 0x01  // UP
    if uv.withLock({ $0 }) { f |= 0x04 }  // UV
    if attested { f |= 0x40 }  // AT
    f |= backup.withLock { $0 }
    return f
  }

  static func clientData(type: String, challenge: Data, origin: String) -> Data {
    Data(#"{"type":"\#(type)","challenge":"\#(Base64.encodeURL(challenge))","origin":"\#(origin)","crossOrigin":false}"#.utf8)
  }

  private func takeFailure() -> PasskeyError? {
    failure.withLock { f in
      defer { f = nil }
      return f
    }
  }
}

/// Test randomness for ids and PRF secrets (not a key path: CryptoKit makes the keys).
func SecRandomFill(_ b: UnsafeMutableRawBufferPointer) -> Bool {
  (try? SystemRandom().fill(b)) != nil
}

/// The CBOR subset WebAuthn needs (RFC 8949): unsigned and negative integers,
/// byte and text strings, arrays and maps, definite lengths only.
public indirect enum CBOR: Sendable, Hashable {
  case int(Int64)
  case bytes(Data)
  case text(String)
  case array([CBOR])
  case map([(CBOR, CBOR)])

  public static func == (a: CBOR, b: CBOR) -> Bool { a.encoded() == b.encoded() }
  public func hash(into h: inout Hasher) { h.combine(encoded()) }

  public func encoded() -> Data {
    var out = Data()
    encode(into: &out)
    return out
  }

  func encode(into out: inout Data) {
    switch self {
    case .int(let v):
      if v >= 0 { Self.head(0, UInt64(v), &out) } else { Self.head(1, UInt64(-1 - v), &out) }
    case .bytes(let d):
      Self.head(2, UInt64(d.count), &out)
      out.append(d)
    case .text(let s):
      Self.head(3, UInt64(s.utf8.count), &out)
      out.append(contentsOf: Array(s.utf8))
    case .array(let a):
      Self.head(4, UInt64(a.count), &out)
      for x in a { x.encode(into: &out) }
    case .map(let m):
      Self.head(5, UInt64(m.count), &out)
      for (k, v) in m {
        k.encode(into: &out)
        v.encode(into: &out)
      }
    }
  }

  static func head(_ major: UInt8, _ n: UInt64, _ out: inout Data) {
    let m = major << 5
    switch n {
    case 0..<24: out.append(m | UInt8(n))
    case 24..<256: out.append(contentsOf: [m | 24, UInt8(n)])
    case 256..<65536: out.append(contentsOf: [m | 25, UInt8(n >> 8), UInt8(n & 0xff)])
    case 65536..<4_294_967_296:
      out.append(m | 26)
      for i in (0..<4).reversed() { out.append(UInt8(n >> (8 * UInt64(i)) & 0xff)) }
    default:
      out.append(m | 27)
      for i in (0..<8).reversed() { out.append(UInt8(n >> (8 * UInt64(i)) & 0xff)) }
    }
  }
}
