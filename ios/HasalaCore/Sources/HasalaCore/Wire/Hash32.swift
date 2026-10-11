// A 32-byte SHA-256 value: chain hashes, `prev_hash`, pinned heads.
import CorePrimitives
import Foundation

public struct Hash32: Sendable, Hashable, CustomStringConvertible {
  public static let byteCount = 32
  /// `0^32`: the `prev_hash` of counter 1 (spec 01 §7).
  public static let zero = Hash32(unchecked: Data(count: 32))

  public let bytes: Data

  /// `nil` unless `bytes` is exactly 32 bytes.
  public init?(_ bytes: some DataProtocol) {
    guard bytes.count == Hash32.byteCount else { return nil }
    self.bytes = Data(bytes)
  }

  /// Lower-case hex of 64 characters, strictly.
  public init?(hex: String) {
    guard let d = try? Hex.decode(hex), d.count == Hash32.byteCount else { return nil }
    bytes = d
  }

  init(unchecked bytes: Data) { self.bytes = bytes }

  /// SHA-256 of `data`.
  public static func of(_ data: some DataProtocol) -> Hash32 { Hash32(unchecked: sha256(data)) }

  public var hex: String { Hex.encode(bytes) }
  public var description: String { hex }
}
