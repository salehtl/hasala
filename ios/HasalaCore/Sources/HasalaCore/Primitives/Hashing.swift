// SHA-256, HMAC-SHA-256 and HKDF-SHA-256 over CryptoKit (spec 01 §2).
//
// Every function takes and returns plain bytes so the callers above (CoreWire,
// CoreCrypto) never touch CryptoKit's types; only this module and CoreCrypto may
// (spec 04 §2.3, 01 AT-C11).
import CryptoKit
import Foundation

/// SHA-256 of `data`: 32 bytes, never aliasing the input.
public func sha256(_ data: some DataProtocol) -> Data {
  Data(SHA256.hash(data: data))
}

/// HMAC-SHA-256 of `message` under `key` (any length, RFC 2104): 32 bytes.
public func hmacSHA256(key: some ContiguousBytes, message: some DataProtocol) -> Data {
  Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
}

/// HKDF-SHA-256 (RFC 5869), as Go's `hkdf.Key(sha256.New, ikm, salt, info, n)`.
///
/// `outputByteCount` is 32 everywhere in spec 01; the RFC bound (255 × 32) is
/// checked here so a bad length is a thrown error, never a CryptoKit trap.
public func hkdfSHA256(
  inputKeyMaterial: some ContiguousBytes, salt: some DataProtocol, info: some DataProtocol,
  outputByteCount: Int = 32
) throws(PrimitivesError) -> Data {
  guard outputByteCount > 0, outputByteCount <= 255 * 32 else {
    throw .invalidLength(what: "hkdf output", expected: "1...8160", got: outputByteCount)
  }
  let key = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: SymmetricKey(data: inputKeyMaterial), salt: salt, info: info,
    outputByteCount: outputByteCount)
  return key.withUnsafeBytes { Data($0) }
}

/// Errors from the cryptographic wrappers. Messages never include key bytes or
/// payload content (spec 01 §11.6).
public enum PrimitivesError: Error, Equatable, Sendable {
  /// A key, nonce, seed or output had the wrong length (a caller bug).
  case invalidLength(what: String, expected: String, got: Int)
  /// AES-GCM open failed. Every way of being wrong (key, nonce, AAD, tag,
  /// ciphertext) is this one indistinguishable error.
  case authenticationFailed
  /// A public key or signature could not be parsed.
  case invalidKey(what: String)
  /// `SecRandomCopyBytes` did not succeed. Fatal for the operation; never
  /// retried with a weaker source (spec 01 §1).
  case randomUnavailable(status: Int32)
  /// `CCKeyDerivationPBKDF` did not return `kCCSuccess`.
  case pbkdf2Failed(status: Int32)
}
