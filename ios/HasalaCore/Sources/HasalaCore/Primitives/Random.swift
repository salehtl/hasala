// Randomness behind a protocol (spec 04 §2.4 R1, R8): production code takes a
// `RandomSource`, tests pass a seeded one (CoreTestSupport). This file and the
// CoreTime adapters are the only places allowed to reach the system source.
import Foundation
import Security

public protocol RandomSource: Sendable {
  /// Fills `buffer` completely or throws; never a partial fill.
  func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError)
}

extension RandomSource {
  /// `count` random bytes.
  public func bytes(_ count: Int) throws(PrimitivesError) -> Data {
    var out = Data(count: count)
    // Data's withUnsafeMutableBytes only rethrows `any Error` before the
    // Xcode 27 SDK, so the typed error is carried out by hand.
    var failure: PrimitivesError?
    out.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
      do throws(PrimitivesError) { try fill(b) } catch { failure = error }
    }
    if let failure { throw failure }
    return out
  }

  /// A random version-4 UUID in canonical LOWER-case form. Foundation's
  /// `UUID().uuidString` is upper case, which the AAD and envelopes refuse.
  public func uuidV4() throws(PrimitivesError) -> String {
    var b = [UInt8](try bytes(16))
    b[6] = (b[6] & 0x0f) | 0x40  // version 4
    b[8] = (b[8] & 0x3f) | 0x80  // RFC 4122 variant
    return UserID.canonicalString(b)
  }
}

/// `SecRandomCopyBytes(kSecRandomDefault, …)`. A non-success status is an error,
/// never a fallback to a weaker source (spec 01 §1).
public struct SystemRandom: RandomSource {
  public init() {}

  public func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) {
    guard let base = buffer.baseAddress, buffer.count > 0 else { return }
    let status = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
    guard status == errSecSuccess else { throw .randomUnavailable(status: status) }
  }
}
