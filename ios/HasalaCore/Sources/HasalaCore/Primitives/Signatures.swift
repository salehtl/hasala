// Ed25519 (RFC 8032) and P-256 ECDSA verification over CryptoKit (spec 01 §1-§2).
//
// CryptoKit's Ed25519 signatures are RANDOMIZED (Go's and the TypeScript
// reference's are deterministic). Both verify under any RFC 8032 verifier, but
// signature bytes are never comparable: tests MUST verify signatures and MUST NOT
// compare them (spec 01 §1). The public key derived from a seed IS
// deterministic and matches RFC 8032.
import CryptoKit
import Foundation

public enum Ed25519 {
  public static let seedByteCount = 32
  public static let publicKeyByteCount = 32
  public static let signatureByteCount = 64

  /// The 32-byte public key of a 32-byte RFC 8032 seed.
  public static func publicKey(seed: some ContiguousBytes) throws(PrimitivesError) -> Data {
    try privateKey(seed).publicKey.rawRepresentation
  }

  /// A 64-byte signature over `message`. Randomized: verify it, never compare it.
  public static func sign(seed: some ContiguousBytes, message: some DataProtocol) throws(PrimitivesError) -> Data {
    do {
      return try privateKey(seed).signature(for: message)
    } catch let e as PrimitivesError {
      throw e
    } catch {
      throw .invalidKey(what: "ed25519 seed")
    }
  }

  /// Whether `signature` is a valid signature of `message` under `publicKey`.
  /// Malformed keys or signatures verify as `false`.
  public static func verify(publicKey: some ContiguousBytes, signature: some DataProtocol, message: some DataProtocol)
    -> Bool
  {
    guard signature.count == signatureByteCount,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    else { return false }
    return key.isValidSignature(signature, for: message)
  }

  /// A fresh key pair from the system CSPRNG: the 32-byte seed and its public key.
  public static func generate() -> (seed: SecureBytes, publicKey: Data) {
    let key = Curve25519.Signing.PrivateKey()
    let seed = key.rawRepresentation
    return (SecureBytes(copying: seed), key.publicKey.rawRepresentation)
  }

  private static func privateKey(_ seed: some ContiguousBytes) throws(PrimitivesError)
    -> Curve25519.Signing.PrivateKey
  {
    let count = seed.withUnsafeBytes { $0.count }
    guard count == seedByteCount else {
      throw .invalidLength(what: "ed25519 seed", expected: "32", got: count)
    }
    do {
      return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    } catch {
      throw .invalidKey(what: "ed25519 seed")
    }
  }
}

/// ECDSA P-256 over SHA-256, VERIFY only (spec 01 §1: signatures are `r ‖ s`, 64
/// bytes; public keys are the 65-byte X9.63 point `04 ‖ X ‖ Y`). Signing happens
/// in the Secure Enclave (app) or `CoreSoftAuth` (tests), never here.
public enum P256Verify {
  public static func verify(
    publicKeyX963: some ContiguousBytes, signatureRaw: some DataProtocol, message: some DataProtocol
  ) -> Bool {
    let keyCount = publicKeyX963.withUnsafeBytes { $0.count }
    guard keyCount == 65, signatureRaw.count == 64,
      let key = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
      let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signatureRaw)
    else { return false }
    return key.isValidSignature(sig, for: message)
  }
}
