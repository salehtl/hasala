// The two identifiers every signed message, AAD and Keychain item is keyed by
// (spec 01 §1 `uuid_str`/`uuid_raw`, §4.8 writer ids; spec 04 §2.7 seams).
//
// They live in L0 because three L1 modules need the same types: CoreWire (the
// frame envelope and AAD), CoreCrypto (every signing message) and CoreAuth (the
// `ApprovalKeySigner` seam). Both are validated on construction, so a value of
// either type is always one the wire accepts.
import Foundation

/// An account id: the 36-character lower-case RFC 4122 form (`uuid_str`) and its
/// 16 network-order bytes (`uuid_raw`). Foundation's `UUID().uuidString` is upper
/// case, which the AAD and every signed message refuse (spec 01 §1), so this type
/// never goes through it.
public struct UserID: Sendable, Hashable, CustomStringConvertible {
  /// `uuid_str(u)`: `8-4-4-4-12` lower-case hex.
  public let string: String
  /// `uuid_raw(u)`: the 16 bytes in RFC 4122 network order.
  public let raw: Data

  /// Accepts only the canonical lower-case form, and refuses the nil UUID (the
  /// frame envelope refuses it too, wire/blob.ts `validateEnvelope`).
  public init?(_ s: String) {
    let u = Array(s.utf8)
    guard u.count == 36 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(16)
    var i = 0
    while i < 36 {
      if i == 8 || i == 13 || i == 18 || i == 23 {
        guard u[i] == 0x2d else { return nil }
        i += 1
        continue
      }
      guard let hi = UserID.nibble(u[i]), i + 1 < 36, let lo = UserID.nibble(u[i + 1]) else { return nil }
      bytes.append(hi << 4 | lo)
      i += 2
    }
    guard bytes.count == 16, bytes.contains(where: { $0 != 0 }) else { return nil }
    string = s
    raw = Data(bytes)
  }

  /// From the 16 raw bytes; `nil` for any other length or the nil UUID.
  public init?(raw bytes: some DataProtocol) {
    guard bytes.count == 16 else { return nil }
    let h = Hex.encode(bytes)
    let c = Array(h.utf8)
    func part(_ r: Range<Int>) -> String { String(decoding: c[r], as: UTF8.self) }
    self.init("\(part(0..<8))-\(part(8..<12))-\(part(12..<16))-\(part(16..<20))-\(part(20..<32))")
  }

  public var description: String { string }

  private static func nibble(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: c - 0x30
    case 0x61...0x66: c - 0x61 + 10
    default: nil
    }
  }
}

/// A device writer id (spec 01 §4.8): `"ios-" ‖ uuid_str(random UUIDv4)`, exactly
/// 40 ASCII characters matching
/// `^ios-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`.
/// It contains neither `|` (the AAD separator) nor `0x00` (the signing-message
/// separator), which is what keeps every encoding that carries it unambiguous.
public struct WriterID: Sendable, Hashable, CustomStringConvertible {
  public static let byteCount = 40
  public let string: String

  public init?(_ s: String) {
    let u = Array(s.utf8)
    guard u.count == WriterID.byteCount, u.starts(with: Array("ios-".utf8)) else { return nil }
    let uuid = Array(u[4...])
    for (i, c) in uuid.enumerated() {
      switch i {
      case 8, 13, 18, 23: guard c == 0x2d else { return nil }
      case 14: guard c == 0x34 else { return nil }  // version 4
      case 19: guard c == 0x38 || c == 0x39 || c == 0x61 || c == 0x62 else { return nil }  // variant 8-b
      default: guard (0x30...0x39).contains(c) || (0x61...0x66).contains(c) else { return nil }
      }
    }
    string = s
  }

  /// A new writer id for an enrolment, from `random` (spec 01 §4.8: minted once
  /// per enrolment, never derived from a device name, never reused).
  public static func mint(random: some RandomSource) throws(PrimitivesError) -> WriterID {
    let uuid = try random.uuidV4()
    guard let w = WriterID("ios-" + uuid) else { throw .invalidLength(what: "writer id", expected: "40", got: 0) }
    return w
  }

  /// The 40 ASCII bytes.
  public var bytes: Data { Data(string.utf8) }
  public var description: String { string }
}
