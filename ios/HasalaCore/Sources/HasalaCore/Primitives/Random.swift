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
    try out.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) throws(PrimitivesError) in
      try fill(b)
    }
    return out
  }

  /// A random version-4 UUID in canonical LOWER-case form. Foundation's
  /// `UUID().uuidString` is upper case, which the AAD and envelopes refuse.
  public func uuidV4() throws(PrimitivesError) -> String {
    var b = [UInt8](try bytes(16))
    b[6] = (b[6] & 0x0f) | 0x40  // version 4
    b[8] = (b[8] & 0x3f) | 0x80  // RFC 4122 variant
    let hex = Hex.encode(b)
    let s = Array(hex.utf8)
    func part(_ r: Range<Int>) -> String { String(decoding: s[r], as: UTF8.self) }
    return "\(part(0..<8))-\(part(8..<12))-\(part(12..<16))-\(part(16..<20))-\(part(20..<32))"
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
