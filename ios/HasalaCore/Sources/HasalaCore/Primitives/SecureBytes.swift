// SecureBytes (spec 01 §11.5): an owned buffer for secrets, zeroed on release.
//
// Zeroization is best effort in Swift (copies made by CryptoKit, Data or the
// compiler are outside this type's reach), and that is stated as such. The type
// exposes no content through `description`, `Codable` or `Hashable`.
import Foundation

public final class SecureBytes: ContiguousBytes, CustomStringConvertible, CustomDebugStringConvertible {
  private let buffer: UnsafeMutableRawBufferPointer

  /// `count` zero bytes.
  public init(count: Int) {
    precondition(count >= 0, "SecureBytes count must not be negative")
    buffer = .allocate(byteCount: count, alignment: 1)
    buffer.initializeMemory(as: UInt8.self, repeating: 0)
  }

  /// A copy of `bytes`. The caller remains responsible for its own copy.
  public convenience init(copying bytes: some ContiguousBytes) {
    let count = bytes.withUnsafeBytes { $0.count }
    self.init(count: count)
    bytes.withUnsafeBytes { src in
      if let base = src.baseAddress, count > 0 { buffer.baseAddress!.copyMemory(from: base, byteCount: count) }
    }
  }

  deinit {
    Self.zero(buffer)
    buffer.deallocate()
  }

  public var count: Int { buffer.count }

  public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try body(UnsafeRawBufferPointer(buffer))
  }

  public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
    try body(buffer)
  }

  /// Zeroes the content now (it is zeroed again on release).
  public func wipe() { Self.zero(buffer) }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }

  private static func zero(_ b: UnsafeMutableRawBufferPointer) {
    guard let base = b.baseAddress, b.count > 0 else { return }
    // memset_s is not elided by the optimizer, unlike a plain store loop.
    _ = memset_s(base, b.count, 0, b.count)
  }
}

/// Byte equality in time that depends only on the lengths, never on where the
/// first difference is. The lengths themselves are not secret.
public func constantTimeEquals(_ a: some ContiguousBytes, _ b: some ContiguousBytes) -> Bool {
  a.withUnsafeBytes { x in
    b.withUnsafeBytes { y in
      guard x.count == y.count else { return false }
      var diff: UInt8 = 0
      for i in 0..<x.count { diff |= x[i] ^ y[i] }
      return diff == 0
    }
  }
}
