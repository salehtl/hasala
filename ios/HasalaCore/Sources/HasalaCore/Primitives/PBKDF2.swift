// PBKDF2-HMAC-SHA256 (RFC 8018), the one CommonCrypto call in the core
// (spec 01 §2, §4.10; spec 04 §2.3: `CCKeyDerivationPBKDF` appears only here).
import CommonCrypto
import Foundation

public enum PBKDF2 {
  /// The derived key length spec 01 uses everywhere.
  public static let outputByteCount = 32

  /// `PBKDF2(password, salt, iterations)` with HMAC-SHA-256, 32 bytes out, into
  /// `SecureBytes`. Fails unless CommonCrypto returns `kCCSuccess`.
  public static func sha256(
    password: some ContiguousBytes, salt: some ContiguousBytes, iterations: UInt32,
    outputByteCount: Int = outputByteCount
  ) throws(PrimitivesError) -> SecureBytes {
    guard iterations > 0 else {
      throw .invalidLength(what: "pbkdf2 iterations", expected: ">= 1", got: 0)
    }
    guard outputByteCount > 0 else {
      throw .invalidLength(what: "pbkdf2 output", expected: ">= 1", got: outputByteCount)
    }
    let out = SecureBytes(count: outputByteCount)
    let status: Int32 = password.withUnsafeBytes { p in
      salt.withUnsafeBytes { s in
        out.withUnsafeMutableBytes { o in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            p.baseAddress?.assumingMemoryBound(to: CChar.self), p.count,
            s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
            o.baseAddress!.assumingMemoryBound(to: UInt8.self), o.count)
        }
      }
    }
    guard status == Int32(kCCSuccess) else { throw .pbkdf2Failed(status: status) }
    return out
  }
}
