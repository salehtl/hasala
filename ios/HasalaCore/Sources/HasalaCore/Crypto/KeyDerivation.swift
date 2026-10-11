// Key derivations (spec 01 §4.4-§4.7, §5.5, §6.4). Every HKDF here is RFC 5869
// HKDF-SHA-256 with a 32-byte output; a salt written `0^32` is passed as 32 zero
// bytes, explicitly (spec 01 §1).
//
//   RK_seed = HKDF(E, 0^32, D04)                         recovery_pubkey = Ed25519.pub(RK_seed)
//   RWK     = HKDF(E, salt32, D05)                       PWK = HKDF(P, salt32, D06)
//   amk_commit = HMAC(AMK, D09 ‖ 00 ‖ uuid_raw)
//   K_1     = HKDF(AMK, uuid_raw, D10 ‖ 00 ‖ u32be(1))
//   K_blob  = HKDF(K_e, nonce12, D11 ‖ 00 ‖ SHA256(AD))
//   K_pv    = HKDF(AMK, uuid_raw, D35)
//   PRF_SALT = SHA256(D08)
//
// Secrets come back as `SecureBytes`; the intermediate `Data` CryptoKit hands
// out is outside this type's reach (spec 01 §11.5: best effort).
import CorePrimitives
import Foundation

public enum KeyDerivation {
  static let zeroSalt = Data(count: 32)

  /// `PRF_SALT = SHA256(utf8("hasala/v1/prf-salt/unlock"))` (A01): the single,
  /// constant PRF evaluation input, passed as `saltInput1`.
  public static let prfSalt: Data = sha256(Domain.prfSaltUnlock.bytes)

  /// `RK_seed = HKDF(E, 0^32, "hasala/v1/recovery-key")`.
  public static func recoveryKeySeed(entropy: some ContiguousBytes) throws(PrimitivesError) -> SecureBytes {
    try requireLength(entropy, Phrase.entropyByteCount, "phrase entropy")
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: entropy, salt: zeroSalt, info: Domain.recoveryKey.bytes))
  }

  /// `recovery_pubkey = Ed25519.pub(RK_seed)`.
  public static func recoveryPublicKey(entropy: some ContiguousBytes) throws(PrimitivesError) -> Data {
    try Ed25519.publicKey(seed: try recoveryKeySeed(entropy: entropy))
  }

  /// `RWK = HKDF(E, salt, "hasala/v1/wrap/recovery")`.
  public static func recoveryWrapKey(entropy: some ContiguousBytes, salt: some DataProtocol) throws(PrimitivesError)
    -> SecureBytes
  {
    try requireLength(entropy, Phrase.entropyByteCount, "phrase entropy")
    try requireCount(salt.count, 32, "wrap salt")
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: entropy, salt: salt, info: Domain.wrapRecovery.bytes))
  }

  /// `PWK = HKDF(P, salt, "hasala/v1/wrap/prf")`.
  public static func prfWrapKey(prfOutput: some ContiguousBytes, salt: some DataProtocol) throws(PrimitivesError)
    -> SecureBytes
  {
    try requireLength(prfOutput, 32, "prf output")
    try requireCount(salt.count, 32, "wrap salt")
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: prfOutput, salt: salt, info: Domain.wrapPRF.bytes))
  }

  /// `amk_commit = HMAC(AMK, "hasala/v1/amk-commitment" ‖ 0x00 ‖ uuid_raw(user_id))`.
  public static func amkCommitment(amk: some ContiguousBytes, userID: UserID) throws(PrimitivesError) -> Data {
    try requireLength(amk, 32, "amk")
    return hmacSHA256(key: amk, message: Domain.amkCommitment.prefix + userID.raw)
  }

  /// `K_1 = HKDF(AMK, uuid_raw(user_id), "hasala/v1/epoch-key" ‖ 0x00 ‖ u32be(1))`.
  /// Epochs above 1 are random keys from the keyring [P], never derived.
  public static func epochKey1(amk: some ContiguousBytes, userID: UserID) throws(PrimitivesError) -> SecureBytes {
    try requireLength(amk, 32, "amk")
    let info = Domain.epochKey.prefix + Data([0, 0, 0, 1])
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: amk, salt: userID.raw, info: info))
  }

  /// `K_blob = HKDF(K_e, nonce, "hasala/v1/blob-key" ‖ 0x00 ‖ SHA256(AD))`: one
  /// AES-GCM message per key, bound to its nonce and position (DEV-1).
  public static func blobKey(epochKey: some ContiguousBytes, nonce: some DataProtocol, associatedData: some DataProtocol)
    throws(PrimitivesError) -> SecureBytes
  {
    try requireLength(epochKey, 32, "epoch key")
    try requireCount(nonce.count, 12, "frame nonce")
    let info = Domain.blobKey.prefix + sha256(associatedData)
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: epochKey, salt: nonce, info: info))
  }

  /// `K_pv = HKDF(AMK, uuid_raw(user_id), "hasala/v1/phrase-box-key")` (no `0x00`).
  public static func phraseBoxKey(amk: some ContiguousBytes, userID: UserID) throws(PrimitivesError) -> SecureBytes {
    try requireLength(amk, 32, "amk")
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: amk, salt: userID.raw, info: Domain.phraseBoxKey.bytes))
  }

  static func requireLength(_ k: some ContiguousBytes, _ n: Int, _ what: String) throws(PrimitivesError) {
    try requireCount(k.withUnsafeBytes { $0.count }, n, what)
  }

  static func requireCount(_ got: Int, _ n: Int, _ what: String) throws(PrimitivesError) {
    guard got == n else { throw .invalidLength(what: what, expected: String(n), got: got) }
  }
}
