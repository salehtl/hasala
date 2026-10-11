// The anchor inputs of spec 01 §15.5, and the server-only derivations the Swift
// tests reproduce for A19 and A19-K (D27-D30, D41). The server derivations live
// here, in test code, because the device never holds `salt_key` or `auth_key`.
import CoreCrypto
import CorePrimitives
import CoreSoftAuth
import CoreWire
import Foundation

enum Anchor {
  /// `a..b`: the run of consecutive byte values (spec 01 §1).
  static func run(_ a: UInt8, _ b: UInt8) -> Data { Data(a...b) }
  static func hex(_ s: String) -> Data { try! Hex.decode(s.filter { !$0.isWhitespace }) }

  static let userID = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
  static let writerID = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
  static let entropy = hex("9e885d952ad362caeb4efe34a8e91bd2")
  static let amk = run(0x40, 0x5f)
  static let aakSeed = run(0x60, 0x7f)
  static let dwkSeed = run(0x80, 0x9f)
  static let prfOutput = run(0xc0, 0xdf)
  static let credentialID = run(0x01, 0x10)
  static let recoveryWrapSalt = run(0x10, 0x2f)
  static let recoveryWrapNonce = run(0xa0, 0xab)
  static let prfWrapSalt = run(0x30, 0x4f)
  static let prfWrapNonce = run(0xb0, 0xbb)
  static let frameNonce1 = run(0xd0, 0xdb)
  static let frameNonce2 = run(0xe0, 0xeb)
  static let stepUpNonce = run(0xf0, 0xff) + run(0x00, 0x0f)
  static let writerChallengeNonce = run(0x50, 0x6f)
  static let registerNonce = run(0x20, 0x3f)
  static let attestationObject = run(0x00, 0x3f)
  static let clientDataJSON = Data(#"{"type":"webauthn.create","challenge":"AAAA","origin":"https://hasala.app"}"#.utf8)
  static let dakScalar = run(0x01, 0x20)
  static let saltKey = run(0x11, 0x30)
  static let authKeyA19 = run(0x11, 0x30)
  static let authKeyA19K = run(0x31, 0x50)
  static let address = "  Maya.Rahman+Hasala@Gmail.COM "
  /// NFD: `e` + U+0301.
  static let passwordNFD = "Hasala cafe\u{301} 2026!"
  static let pwSalt = run(0xa0, 0xaf)
  static let phraseBoxNonce = run(0xf0, 0xfb)
  static let codeID = UserID("0f1e2d3c-4b5a-4968-8776-655443322110")!
  static let codePurpose = "password_reset"
  static let code = "042817"
  static let ekSeed = run(0xb0, 0xcf)
  static let resetNonce = run(0x10, 0x2f)
  static let newAddress = "Maya@Example.AE"
  static let loginChallenge = run(0x70, 0x8f)
  static let recoverNonce = run(0x90, 0xaf)

  /// `R = u32be(16) ‖ 00..0f ‖ zeros` to `|R|` (an AEAD-layer anchor; not gzip).
  static func region(_ length: Int) -> Data {
    var r = Data([0, 0, 0, 16]) + run(0x00, 0x0f)
    r.append(Data(count: length - r.count))
    return r
  }
}

/// Server-only derivations (spec 01 §4.11), for the A19/A19-K vectors only.
enum ServerKeys {
  static let zero32 = Data(count: 32)
  static func subkey(_ k: Data, _ d: Domain) -> Data {
    try! hkdfSHA256(inputKeyMaterial: k, salt: zero32, info: d.bytes)
  }
  static func kSalt(_ saltKey: Data) -> Data { subkey(saltKey, .serverPasswordSalt) }
  static func kPepper(_ authKey: Data) -> Data { subkey(authKey, .serverPasswordPepper) }
  static func kCode(_ authKey: Data) -> Data { subkey(authKey, .serverEmailCode) }
  static func kTag(_ authKey: Data) -> Data { subkey(authKey, .serverEmailTag) }
  static func serverSalt(_ saltKey: Data, emailNorm: String) -> Data {
    hmacSHA256(key: kSalt(saltKey), message: Data(emailNorm.utf8))
  }
  static func emailTag(_ authKey: Data, emailNorm: String) -> Data {
    hmacSHA256(key: kTag(authKey), message: Data(emailNorm.utf8))
  }
  static func keyID(_ k: Data) -> String { Hex.encode(hmacSHA256(key: k, message: Domain.serverAuthKeyID.bytes).prefix(8)) }
  static func pepperedVerifier(_ authKey: Data, s: some ContiguousBytes) -> Data {
    hmacSHA256(key: kPepper(authKey), message: s.withUnsafeBytes { Data($0) })
  }
  static func passwordHash(_ authKey: Data, s: some ContiguousBytes, pwSalt: Data) -> Data {
    let mac = pepperedVerifier(authKey, s: s)
    return try! PBKDF2.sha256(password: mac, salt: pwSalt, iterations: 100_000).withUnsafeBytes { Data($0) }
  }
  static func codeMAC(_ authKey: Data, purpose: String, codeID: UserID, emailTag: Data, code: String) -> Data {
    hmacSHA256(key: kCode(authKey), message: Data(purpose.utf8) + [0] + codeID.raw + emailTag + Data(code.utf8))
  }
}

/// A13's DAK, as a software approval key with the fixed scalar `01..20`.
enum SoftDAK {
  static func signer() throws -> SoftwareApprovalKeySigner {
    let s = SoftwareApprovalKeySigner()
    try s.install(privateScalar: Anchor.dakScalar, userID: Anchor.userID, writerID: Anchor.writerID)
    return s
  }

  static func publicKey(scalar: Data) throws -> Data {
    let s = SoftwareApprovalKeySigner()
    try s.install(privateScalar: scalar, userID: Anchor.userID, writerID: Anchor.writerID)
    return try s.publicKeyX963(userID: Anchor.userID, writerID: Anchor.writerID)
  }
}

extension SecureBytes {
  var data: Data { withUnsafeBytes { Data($0) } }
}
