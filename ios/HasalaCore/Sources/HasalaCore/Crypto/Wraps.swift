// The key body, its two wraps and the phrase box (spec 01 §4.5, §5).
//
//   body = 0x01 ‖ AMK ‖ AAK_seed                                         65 bytes
//   wrap = version 0x01 ‖ kdf ‖ salt32 ‖ nonce12 ‖ ct65 ‖ tag16          127 bytes, header = wrap[0:46]
//     recovery: key RWK = HKDF(E, salt, D05), kdf 0x01, AD = D07 ‖ 00 ‖ header ‖ uuid_raw
//     PRF:      key PWK = HKDF(P, salt, D06), kdf 0x02, AD = D07 ‖ 00 ‖ header ‖ uuid_raw ‖ credential_id
//   box  = 0x01 ‖ nonce12 ‖ ct16 ‖ tag16                                  45 bytes
//     key K_pv = HKDF(AMK, uuid_raw, D35), AD = D36 ‖ 00 ‖ uuid_raw ‖ recovery_pubkey32 ‖ box[0:1]
//
// Opening has one error for every cause (`unwrapFailed`: no oracle), except the
// two named integrity alarms, which are never "wrong phrase".
import CorePrimitives
import Foundation

public enum UnwrapError: Error, Equatable, Sendable {
  /// The phrase derives a recovery key that is not this account's (S-15).
  case notThisAccountsPhrase
  /// Any failure to open, of any cause.
  case unwrapFailed
  /// Integrity alarm: the body opened but its AMK or AAK is not the published one.
  case accountKeysMismatch
  /// Integrity alarm: the phrase box opened to a phrase that is not this account's.
  case phraseBoxMismatch
}

/// The 65-byte key body. Its keys never touch disk; zero it as soon as the
/// ceremony is done (``wipe()``).
///
/// `@unchecked Sendable` because `SecureBytes` is a reference to mutable memory:
/// ``wipe()`` zeroes it in place for every holder. The caller must not wipe
/// while any other task still uses the body (no lock guards it; a wipe racing a
/// read is a data race and can hand that read zeros).
public final class KeyBody: @unchecked Sendable {
  public static let byteCount = 65
  public static let version: UInt8 = 0x01

  public let amk: SecureBytes
  public let aakSeed: SecureBytes

  public init(amk: some ContiguousBytes, aakSeed: some ContiguousBytes) throws(PrimitivesError) {
    try KeyDerivation.requireLength(amk, 32, "amk")
    try KeyDerivation.requireLength(aakSeed, 32, "aak seed")
    self.amk = SecureBytes(copying: amk)
    self.aakSeed = SecureBytes(copying: aakSeed)
  }

  /// A fresh AMK and AAK seed (C1).
  public static func generate(random: some RandomSource) throws(PrimitivesError) -> KeyBody {
    let amk = SecureBytes(copying: try random.bytes(32))
    let aak = SecureBytes(copying: try random.bytes(32))
    return try KeyBody(amk: amk, aakSeed: aak)
  }

  /// `0x01 ‖ AMK ‖ AAK_seed`, or `nil` for any other length or version.
  init?(decoding body: some ContiguousBytes) {
    let ok: (SecureBytes, SecureBytes)? = body.withUnsafeBytes { b in
      guard b.count == KeyBody.byteCount, b[0] == KeyBody.version else { return nil }
      // Straight from the caller's buffer: no intermediate Array copy of a key.
      return (
        SecureBytes(copying: UnsafeRawBufferPointer(rebasing: b[1..<33])),
        SecureBytes(copying: UnsafeRawBufferPointer(rebasing: b[33..<65]))
      )
    }
    guard let ok else { return nil }
    amk = ok.0
    aakSeed = ok.1
  }

  /// The 65 plaintext bytes.
  public func encoded() -> SecureBytes {
    let out = SecureBytes(count: KeyBody.byteCount)
    out.withUnsafeMutableBytes { o in
      o[0] = KeyBody.version
      amk.withUnsafeBytes { a in for i in 0..<32 { o[1 + i] = a[i] } }
      aakSeed.withUnsafeBytes { a in for i in 0..<32 { o[33 + i] = a[i] } }
    }
    return out
  }

  /// `authority_pubkey = Ed25519.pub(AAK_seed)`.
  public func authorityPublicKey() throws(PrimitivesError) -> Data { try Ed25519.publicKey(seed: aakSeed) }

  public func amkCommitment(userID: UserID) throws(PrimitivesError) -> Data {
    try KeyDerivation.amkCommitment(amk: amk, userID: userID)
  }

  public func epochKey1(userID: UserID) throws(PrimitivesError) -> SecureBytes {
    try KeyDerivation.epochKey1(amk: amk, userID: userID)
  }

  /// Signs with the AAK (bootstrap, writer registration, rotations).
  public func signWithAuthority(_ message: some DataProtocol) throws(PrimitivesError) -> Data {
    try Ed25519.sign(seed: aakSeed, message: message)
  }

  public func wipe() {
    amk.wipe()
    aakSeed.wipe()
  }
}

/// What the server publishes in `account_keys`, which an unlocked body must match.
public struct PublishedAccountKeys: Sendable, Hashable {
  public let userID: UserID
  public let recoveryPublicKey: Data
  public let amkCommitment: Data
  public let authorityPublicKey: Data

  public init(userID: UserID, recoveryPublicKey: Data, amkCommitment: Data, authorityPublicKey: Data) {
    self.userID = userID
    self.recoveryPublicKey = recoveryPublicKey
    self.amkCommitment = amkCommitment
    self.authorityPublicKey = authorityPublicKey
  }
}

public enum Wrap {
  public static let byteCount = 127
  public static let headerByteCount = 46
  public static let version: UInt8 = 0x01

  public enum KDF: UInt8, Sendable {
    /// HKDF over the phrase entropy (the recovery wrap).
    case phrase = 0x01
    /// HKDF over a PRF output (a PRF wrap).
    case prf = 0x02
    // 0x03 is reserved for a stretched PHRASE root, never a password (§4.10).
  }

  /// The PRF credential id bounds (`02` §5.3).
  public static let credentialIDBytes = 16...1023

  // MARK: Seal

  /// The recovery wrap of `body` under `E` (§5.2), with a fresh salt and nonce.
  public static func sealRecovery(body: KeyBody, entropy: some ContiguousBytes, userID: UserID, random: some RandomSource)
    throws(PrimitivesError) -> Data
  {
    try sealRecovery(body: body, entropy: entropy, userID: userID, salt: try random.bytes(32), nonce: try random.bytes(12))
  }

  package static func sealRecovery(
    body: KeyBody, entropy: some ContiguousBytes, userID: UserID, salt: Data, nonce: Data
  ) throws(PrimitivesError) -> Data {
    let key = try KeyDerivation.recoveryWrapKey(entropy: entropy, salt: salt)
    return try seal(body: body, kdf: .phrase, key: key, salt: salt, nonce: nonce, userID: userID, credentialID: nil)
  }

  /// A PRF wrap of `body` under the credential's PRF output `P` (§5.3).
  public static func sealPRF(
    body: KeyBody, prfOutput: some ContiguousBytes, userID: UserID, credentialID: Data, random: some RandomSource
  ) throws(PrimitivesError) -> Data {
    try sealPRF(
      body: body, prfOutput: prfOutput, userID: userID, credentialID: credentialID, salt: try random.bytes(32),
      nonce: try random.bytes(12))
  }

  package static func sealPRF(
    body: KeyBody, prfOutput: some ContiguousBytes, userID: UserID, credentialID: Data, salt: Data, nonce: Data
  ) throws(PrimitivesError) -> Data {
    guard credentialIDBytes.contains(credentialID.count) else {
      throw .invalidLength(what: "credential id", expected: "16...1023", got: credentialID.count)
    }
    let key = try KeyDerivation.prfWrapKey(prfOutput: prfOutput, salt: salt)
    return try seal(body: body, kdf: .prf, key: key, salt: salt, nonce: nonce, userID: userID, credentialID: credentialID)
  }

  private static func seal(
    body: KeyBody, kdf: KDF, key: SecureBytes, salt: Data, nonce: Data, userID: UserID, credentialID: Data?
  ) throws(PrimitivesError) -> Data {
    try KeyDerivation.requireCount(salt.count, 32, "wrap salt")
    try KeyDerivation.requireCount(nonce.count, 12, "wrap nonce")
    let header = Data([version, kdf.rawValue]) + salt + nonce
    // CryptoKit takes a DataProtocol: the one Data copy of the body is zeroed
    // on the way out, with the SecureBytes it came from (§11.5, best effort).
    let encoded = body.encoded()
    var plaintext = encoded.withUnsafeBytes { Data($0) }
    defer {
      plaintext.resetBytes(in: 0..<plaintext.count)
      encoded.wipe()
    }
    let sealed = try AESGCM.seal(
      key: key, nonce: nonce, aad: associatedData(header: header, userID: userID, credentialID: credentialID),
      plaintext: plaintext)
    return header + sealed
  }

  /// `"hasala/v1/wrap" ‖ 0x00 ‖ header46 ‖ uuid_raw [‖ credential_id]`.
  static func associatedData(header: Data, userID: UserID, credentialID: Data?) -> Data {
    Domain.wrap.prefix + header + userID.raw + (credentialID ?? Data())
  }

  // MARK: Open (§5.4 steps 2-4)

  public static func openRecovery(_ wrap: Data, entropy: some ContiguousBytes, userID: UserID) throws(UnwrapError)
    -> KeyBody
  {
    try open(wrap, kdf: .phrase, userID: userID, credentialID: nil) { salt throws(PrimitivesError) in
      try KeyDerivation.recoveryWrapKey(entropy: entropy, salt: salt)
    }
  }

  public static func openPRF(_ wrap: Data, prfOutput: some ContiguousBytes, userID: UserID, credentialID: Data)
    throws(UnwrapError) -> KeyBody
  {
    guard credentialIDBytes.contains(credentialID.count) else { throw .unwrapFailed }
    return try open(wrap, kdf: .prf, userID: userID, credentialID: credentialID) { salt throws(PrimitivesError) in
      try KeyDerivation.prfWrapKey(prfOutput: prfOutput, salt: salt)
    }
  }

  private static func open(
    _ wrap: Data, kdf: KDF, userID: UserID, credentialID: Data?,
    key derive: (Data) throws(PrimitivesError) -> SecureBytes
  ) throws(UnwrapError) -> KeyBody {
    let w = [UInt8](wrap)
    guard w.count == byteCount, w[0] == version, w[1] == kdf.rawValue else { throw .unwrapFailed }
    let header = Data(w[0..<headerByteCount])
    let salt = Data(w[2..<34])
    let nonce = Data(w[34..<46])
    do {
      let key = try derive(salt)
      var body = try AESGCM.open(
        key: key, nonce: nonce, aad: associatedData(header: header, userID: userID, credentialID: credentialID),
        sealed: Data(w[46...]))
      defer { body.resetBytes(in: 0..<body.count) }
      guard let decoded = KeyBody(decoding: body) else { throw UnwrapError.unwrapFailed }
      return decoded
    } catch {
      throw .unwrapFailed
    }
  }
}

/// §5.4 in order: the RK check (phrase path), the wrap, the body version, and
/// the commitments. A PRF wrap that fails to open is never deleted
/// automatically (W14): the caller falls back to the phrase.
public enum AccountUnlock {
  public static func withPhrase(entropy: some ContiguousBytes, recoveryWrap: Data, published: PublishedAccountKeys)
    throws(UnwrapError) -> KeyBody
  {
    let rkPub: Data
    do { rkPub = try KeyDerivation.recoveryPublicKey(entropy: entropy) } catch { throw .notThisAccountsPhrase }
    guard constantTimeEquals(rkPub, published.recoveryPublicKey) else { throw .notThisAccountsPhrase }
    let body = try Wrap.openRecovery(recoveryWrap, entropy: entropy, userID: published.userID)
    try checkCommitments(body, published)
    return body
  }

  public static func withPRF(
    prfOutput: some ContiguousBytes, credentialID: Data, prfWrap: Data, published: PublishedAccountKeys
  ) throws(UnwrapError) -> KeyBody {
    let body = try Wrap.openPRF(prfWrap, prfOutput: prfOutput, userID: published.userID, credentialID: credentialID)
    try checkCommitments(body, published)
    return body
  }

  /// `amk_commit` and `Ed25519.pub(AAK_seed)` against the published values, in
  /// constant time. A mismatch is an integrity alarm, never "wrong phrase".
  public static func checkCommitments(_ body: KeyBody, _ published: PublishedAccountKeys) throws(UnwrapError) {
    do {
      let commit = try body.amkCommitment(userID: published.userID)
      let aak = try body.authorityPublicKey()
      let a = constantTimeEquals(commit, published.amkCommitment)
      let b = constantTimeEquals(aak, published.authorityPublicKey)
      guard a && b else {
        body.wipe()
        throw UnwrapError.accountKeysMismatch
      }
    } catch let e as UnwrapError {
      throw e
    } catch {
      throw .accountKeysMismatch
    }
  }
}

public enum PhraseBox {
  public static let byteCount = 45
  public static let version: UInt8 = 0x01

  /// `E` sealed under `K_pv` with a fresh nonce (§5.5).
  public static func seal(
    entropy: some ContiguousBytes, amk: some ContiguousBytes, userID: UserID, recoveryPublicKey: Data,
    random: some RandomSource
  ) throws(PrimitivesError) -> Data {
    try seal(entropy: entropy, amk: amk, userID: userID, recoveryPublicKey: recoveryPublicKey, nonce: try random.bytes(12))
  }

  package static func seal(
    entropy: some ContiguousBytes, amk: some ContiguousBytes, userID: UserID, recoveryPublicKey: Data, nonce: Data
  ) throws(PrimitivesError) -> Data {
    try KeyDerivation.requireLength(entropy, Phrase.entropyByteCount, "phrase entropy")
    try KeyDerivation.requireCount(recoveryPublicKey.count, 32, "recovery public key")
    try KeyDerivation.requireCount(nonce.count, 12, "phrase box nonce")
    let key = try KeyDerivation.phraseBoxKey(amk: amk, userID: userID)
    let ad = associatedData(userID: userID, recoveryPublicKey: recoveryPublicKey, versionByte: version)
    var e = entropy.withUnsafeBytes { Data($0) }
    defer { e.resetBytes(in: 0..<e.count) }
    return Data([version]) + nonce + (try AESGCM.seal(key: key, nonce: nonce, aad: ad, plaintext: e))
  }

  /// §5.5 "Open", steps 1-3: the version byte, AEAD under `AD`, then the RK
  /// check. Returns `E`.
  public static func open(_ box: Data, amk: some ContiguousBytes, userID: UserID, recoveryPublicKey: Data)
    throws(UnwrapError) -> SecureBytes
  {
    let b = [UInt8](box)
    guard b.count == byteCount, b[0] == version, recoveryPublicKey.count == 32 else { throw .unwrapFailed }
    let entropy: SecureBytes
    do {
      let key = try KeyDerivation.phraseBoxKey(amk: amk, userID: userID)
      let ad = associatedData(userID: userID, recoveryPublicKey: recoveryPublicKey, versionByte: b[0])
      entropy = SecureBytes(copying: try AESGCM.open(key: key, nonce: Data(b[1..<13]), aad: ad, sealed: Data(b[13...])))
    } catch {
      throw .unwrapFailed
    }
    let rk: Data
    do { rk = try KeyDerivation.recoveryPublicKey(entropy: entropy) } catch { throw .phraseBoxMismatch }
    guard constantTimeEquals(rk, recoveryPublicKey) else {
      entropy.wipe()
      throw .phraseBoxMismatch
    }
    return entropy
  }

  /// `"hasala/v1/phrase-box" ‖ 0x00 ‖ uuid_raw ‖ recovery_pubkey32 ‖ box[0:1]`.
  static func associatedData(userID: UserID, recoveryPublicKey: Data, versionByte: UInt8) -> Data {
    Domain.phraseBox.prefix + userID.raw + recoveryPublicKey + Data([versionByte])
  }
}
