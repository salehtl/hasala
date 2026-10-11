// AES-256-GCM over CryptoKit (spec 01 §2), with the TypeScript seam's shape:
// the output of a seal is `ciphertext ‖ tag` (the nonce is carried separately
// by the caller's framing).
//
// The 32-byte key and 12-byte nonce are checked explicitly: CryptoKit accepts
// 16- and 24-byte keys and other nonce sizes, and a frame that sealed with one
// would not open anywhere else (client-core-a §1).
import CryptoKit
import Foundation

public enum AESGCM {
  public static let keyByteCount = 32
  public static let nonceByteCount = 12
  public static let tagByteCount = 16

  /// Seals `plaintext` under `key` and `nonce`, authenticating `aad`.
  /// Returns `ciphertext ‖ tag` (plaintext length + 16 bytes).
  public static func seal(
    key: some ContiguousBytes, nonce: some DataProtocol, aad: some DataProtocol,
    plaintext: some DataProtocol
  ) throws(PrimitivesError) -> Data {
    let symmetric = try checkedKey(key)
    let gcmNonce = try checkedNonce(nonce)
    do {
      let box = try AES.GCM.seal(plaintext, using: symmetric, nonce: gcmNonce, authenticating: aad)
      return box.ciphertext + box.tag
    } catch {
      // Unreachable with checked lengths; reported as a length fault, not a crash.
      throw .invalidLength(what: "aes-gcm seal", expected: "valid inputs", got: 0)
    }
  }

  /// Opens `ciphertext ‖ tag`. Any failure, including input shorter than the
  /// tag, is ``PrimitivesError/authenticationFailed``; a key or nonce of the
  /// wrong length is a caller bug and reported as such.
  public static func open(
    key: some ContiguousBytes, nonce: some DataProtocol, aad: some DataProtocol,
    sealed: some DataProtocol
  ) throws(PrimitivesError) -> Data {
    let symmetric = try checkedKey(key)
    let gcmNonce = try checkedNonce(nonce)
    let bytes = Data(sealed)
    guard bytes.count >= tagByteCount else { throw .authenticationFailed }
    let split = bytes.count - tagByteCount
    do {
      let box = try AES.GCM.SealedBox(
        nonce: gcmNonce, ciphertext: bytes.prefix(split), tag: bytes.suffix(tagByteCount))
      return try AES.GCM.open(box, using: symmetric, authenticating: aad)
    } catch {
      throw .authenticationFailed
    }
  }

  private static func checkedKey(_ key: some ContiguousBytes) throws(PrimitivesError) -> SymmetricKey {
    let count = key.withUnsafeBytes { $0.count }
    guard count == keyByteCount else {
      throw .invalidLength(what: "aes-256-gcm key", expected: "32", got: count)
    }
    return SymmetricKey(data: key)
  }

  private static func checkedNonce(_ nonce: some DataProtocol) throws(PrimitivesError) -> AES.GCM.Nonce {
    guard nonce.count == nonceByteCount, let n = try? AES.GCM.Nonce(data: nonce) else {
      throw .invalidLength(what: "aes-gcm nonce", expected: "12", got: nonce.count)
    }
    return n
  }
}
