// WebAuthn on the wire (spec 04 §6.1.1; `02` §7 #3–#6, #10–#11, the step-up
// `passkey` proof): go-webauthn's `CredentialCreation` / `CredentialAssertion`
// options in, `PublicKeyCredential` JSON out.
//
// The raw `clientDataJSON` and `attestationObject` are kept as the
// authenticator returned them and sent unparsed (base64url, no padding):
// BootstrapPayload's `auth_hash` (D17, R-01), RecoverySigninMessage (D18) and
// PasskeyAddMessage (D33) hash those exact bytes.
import CorePrimitives
import Foundation

public enum WebAuthnError: Error, Sendable, Hashable {
  /// The options are not go-webauthn's shape (a missing or non-base64url field).
  case badOptions(String)
}

/// `options.publicKey` of a registration ceremony (#3, #10, #48), the fields the
/// app uses.
public struct CreationOptions: Sendable, Hashable {
  public let challenge: Data
  public let rpID: String
  public let userID: Data
  public let userName: String
  public let excludeCredentialIDs: [Data]

  public init(challenge: Data, rpID: String, userID: Data, userName: String, excludeCredentialIDs: [Data] = []) {
    self.challenge = challenge
    self.rpID = rpID
    self.userID = userID
    self.userName = userName
    self.excludeCredentialIDs = excludeCredentialIDs
  }
}

/// `options.publicKey` of an assertion ceremony (#5).
public struct AssertionOptions: Sendable, Hashable {
  public let challenge: Data
  public let rpID: String?
  public let allowCredentialIDs: [Data]

  public init(challenge: Data, rpID: String?, allowCredentialIDs: [Data]) {
    self.challenge = challenge
    self.rpID = rpID
    self.allowCredentialIDs = allowCredentialIDs
  }
}

/// The go-webauthn JSON shapes, decoded leniently (unknown fields ignored).
struct WireCredentialDescriptor: Codable, Hashable {
  let type: String?
  let id: String

  static func ids(_ descriptors: [WireCredentialDescriptor]?, field: String) throws(WebAuthnError) -> [Data] {
    var out: [Data] = []
    for d in descriptors ?? [] {
      guard let id = try? Base64.decodeURL(d.id) else { throw .badOptions(field) }
      out.append(id)
    }
    return out
  }
}

public struct WireCreationOptions: Codable, Sendable, Hashable {
  struct PublicKey: Codable, Hashable {
    struct RP: Codable, Hashable {
      let id: String?
      let name: String?
    }
    struct User: Codable, Hashable {
      let id: String
      let name: String?
      let displayName: String?
    }
    let challenge: String
    let rp: RP
    let user: User
    let excludeCredentials: [WireCredentialDescriptor]?
  }
  let publicKey: PublicKey

  public func decoded() throws(WebAuthnError) -> CreationOptions {
    guard let challenge = try? Base64.decodeURL(publicKey.challenge) else { throw .badOptions("challenge") }
    guard let user = try? Base64.decodeURL(publicKey.user.id) else { throw .badOptions("user.id") }
    let exclude = try WireCredentialDescriptor.ids(publicKey.excludeCredentials, field: "excludeCredentials")
    return CreationOptions(
      challenge: challenge, rpID: publicKey.rp.id ?? "", userID: user, userName: publicKey.user.name ?? "",
      excludeCredentialIDs: exclude)
  }

  public init(_ o: CreationOptions) {
    publicKey = PublicKey(
      challenge: Base64.encodeURL(o.challenge), rp: .init(id: o.rpID, name: "Hasala"),
      user: .init(id: Base64.encodeURL(o.userID), name: o.userName, displayName: o.userName),
      excludeCredentials: o.excludeCredentialIDs.map { WireCredentialDescriptor(type: "public-key", id: Base64.encodeURL($0)) })
  }
}

public struct WireAssertionOptions: Codable, Sendable, Hashable {
  struct PublicKey: Codable, Hashable {
    let challenge: String
    let rpId: String?
    let allowCredentials: [WireCredentialDescriptor]?
  }
  let publicKey: PublicKey

  public func decoded() throws(WebAuthnError) -> AssertionOptions {
    guard let challenge = try? Base64.decodeURL(publicKey.challenge) else { throw .badOptions("challenge") }
    let allow = try WireCredentialDescriptor.ids(publicKey.allowCredentials, field: "allowCredentials")
    return AssertionOptions(challenge: challenge, rpID: publicKey.rpId, allowCredentialIDs: allow)
  }

  public init(_ o: AssertionOptions) {
    publicKey = PublicKey(
      challenge: Base64.encodeURL(o.challenge), rpId: o.rpID,
      allowCredentials: o.allowCredentialIDs.map { WireCredentialDescriptor(type: "public-key", id: Base64.encodeURL($0)) })
  }
}

/// What a registration returned (spec 04 §6.1.1). `prfFirst` is the PRF output
/// for `PRF_SALT` when the authenticator evaluated it at creation.
///
/// `@unchecked Sendable`: `prfFirst` is a `SecureBytes` handed from the
/// authenticator to one ceremony, which wipes it; nothing mutates it meanwhile.
public struct RawRegistration: @unchecked Sendable {
  public let credentialID: Data
  public let rawClientDataJSON: Data
  public let rawAttestationObject: Data
  public let prfFirst: SecureBytes?

  public init(credentialID: Data, rawClientDataJSON: Data, rawAttestationObject: Data, prfFirst: SecureBytes?) {
    self.credentialID = credentialID
    self.rawClientDataJSON = rawClientDataJSON
    self.rawAttestationObject = rawAttestationObject
    self.prfFirst = prfFirst
  }

  /// `PublicKeyCredential` JSON for go-webauthn's `ParseCredentialCreationResponse`.
  public var credential: PublicKeyCredentialJSON {
    PublicKeyCredentialJSON(
      id: Base64.encodeURL(credentialID), rawId: Base64.encodeURL(credentialID), type: "public-key",
      response: .init(
        clientDataJSON: Base64.encodeURL(rawClientDataJSON), attestationObject: Base64.encodeURL(rawAttestationObject),
        authenticatorData: nil, signature: nil, userHandle: nil, transports: ["internal", "hybrid"]),
      clientExtensionResults: Empty(), authenticatorAttachment: "platform")
  }
}

/// What an assertion returned (spec 04 §6.1.1).
public struct RawAssertion: @unchecked Sendable {  // as RawRegistration
  public let credentialID: Data
  public let rawClientDataJSON: Data
  public let authenticatorData: Data
  public let signature: Data
  public let userHandle: Data?
  public let prfFirst: SecureBytes?

  public init(
    credentialID: Data, rawClientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?,
    prfFirst: SecureBytes?
  ) {
    self.credentialID = credentialID
    self.rawClientDataJSON = rawClientDataJSON
    self.authenticatorData = authenticatorData
    self.signature = signature
    self.userHandle = userHandle
    self.prfFirst = prfFirst
  }

  public var credential: PublicKeyCredentialJSON {
    PublicKeyCredentialJSON(
      id: Base64.encodeURL(credentialID), rawId: Base64.encodeURL(credentialID), type: "public-key",
      response: .init(
        clientDataJSON: Base64.encodeURL(rawClientDataJSON), attestationObject: nil,
        authenticatorData: Base64.encodeURL(authenticatorData), signature: Base64.encodeURL(signature),
        userHandle: userHandle.map { Base64.encodeURL($0) }, transports: nil),
      clientExtensionResults: Empty(), authenticatorAttachment: "platform")
  }
}

/// The W3C `PublicKeyCredential` JSON (base64url without padding), as
/// go-webauthn reads it.
public struct PublicKeyCredentialJSON: Codable, Sendable, Hashable {
  public struct Response: Codable, Sendable, Hashable {
    public let clientDataJSON: String
    public let attestationObject: String?
    public let authenticatorData: String?
    public let signature: String?
    public let userHandle: String?
    public let transports: [String]?
  }
  public let id: String
  public let rawId: String
  public let type: String
  public let response: Response
  public let clientExtensionResults: Empty
  public let authenticatorAttachment: String?
}

public enum PasskeyError: Error, Sendable, Hashable {
  /// The user closed the system sheet (not an error to show, §6.1.5).
  case cancelled
  /// Passkey creation unavailable: no passcode, iCloud Keychain off.
  case unsupported
  /// No Hasala passkey on this iPhone.
  case noCredential
  /// The registration returned no attestation object (01 §10.1): abort.
  case noAttestation
  /// The options failed the client's own check (e.g. `C_reg` mismatch).
  case challengeMismatch
  case failed(String)
}

/// The platform passkey seam: `Platform/Passkeys` (AuthenticationServices,
/// RP ID `hasala.app`, UV required) in the app, `CoreSoftAuth.SoftPasskey` in
/// tests. `prfSalt` asks for the PRF extension's first output.
public protocol PasskeyProvider: Sendable {
  func register(_ options: CreationOptions, prfSalt: Data?) async throws(PasskeyError) -> RawRegistration
  func assert(challenge: Data, allowCredentialIDs: [Data], prfSalt: Data?) async throws(PasskeyError) -> RawAssertion
}

public struct BackupFlags: Sendable, Hashable {
  public let eligible: Bool
  public let backedUp: Bool

  public init(eligible: Bool, backedUp: Bool) {
    self.eligible = eligible
    self.backedUp = backedUp
  }

  public var synced: Bool { eligible && backedUp }

  public static func fromAuthenticatorData(_ authData: Data) -> BackupFlags? {
    guard authData.count >= 37 else { return nil }
    let flags = authData[authData.startIndex + 32]
    return BackupFlags(eligible: flags & 0x08 != 0, backedUp: flags & 0x10 != 0)
  }

  public static func fromAttestationObject(_ attestation: Data) -> BackupFlags? {
    AttestationReader.authData(attestation).flatMap(fromAuthenticatorData)
  }
}

extension RawRegistration {
  public var backupFlags: BackupFlags? { BackupFlags.fromAttestationObject(rawAttestationObject) }
}

enum AttestationReader {
  static func authData(_ attestation: Data) -> Data? {
    let b = [UInt8](attestation)
    var i = 0
    guard let top = head(b, &i), top.major == 5 else { return nil }
    var found: Data?
    for _ in 0..<top.n {
      guard let k = head(b, &i) else { return nil }
      var key: String?
      if k.major == 3 {
        guard let end = advance(i, k.n, b.count) else { return nil }
        key = String(bytes: b[i..<end], encoding: .utf8)
        i = end
      } else if !skipBody(b, &i, k, depth: 1) {
        return nil
      }
      if key == "authData" {
        guard let v = head(b, &i), v.major == 2, let end = advance(i, v.n, b.count), found == nil else { return nil }
        found = Data(b[i..<end])
        i = end
      } else if !skip(b, &i, depth: 1) {
        return nil
      }
    }
    return i == b.count ? found : nil
  }

  struct Head {
    let major: UInt8
    let n: UInt64
  }

  static func advance(_ i: Int, _ n: UInt64, _ count: Int) -> Int? {
    guard n <= UInt64(count - i) else { return nil }
    return i + Int(n)
  }

  static func head(_ b: [UInt8], _ i: inout Int) -> Head? {
    guard i < b.count else { return nil }
    let first = b[i]
    i += 1
    let major = first >> 5
    let info = first & 0x1f
    switch info {
    case 0..<24:
      return Head(major: major, n: UInt64(info))
    case 24...27:
      let width = 1 << Int(info - 24)
      guard b.count - i >= width else { return nil }
      var n: UInt64 = 0
      for _ in 0..<width {
        n = n << 8 | UInt64(b[i])
        i += 1
      }
      return Head(major: major, n: n)
    default:
      return nil
    }
  }

  static func skip(_ b: [UInt8], _ i: inout Int, depth: Int) -> Bool {
    guard let h = head(b, &i) else { return false }
    return skipBody(b, &i, h, depth: depth)
  }

  static func skipBody(_ b: [UInt8], _ i: inout Int, _ h: Head, depth: Int) -> Bool {
    guard depth <= 8 else { return false }
    switch h.major {
    case 0, 1, 7:
      return true
    case 2, 3:
      guard let end = advance(i, h.n, b.count) else { return false }
      i = end
      return true
    case 4, 5:
      let remaining = UInt64(b.count - i)
      guard h.n <= remaining else { return false }
      let items = h.major == 5 ? h.n * 2 : h.n
      for _ in 0..<items {
        if !skip(b, &i, depth: depth + 1) { return false }
      }
      return true
    case 6:
      return skip(b, &i, depth: depth + 1)
    default:
      return false
    }
  }
}
