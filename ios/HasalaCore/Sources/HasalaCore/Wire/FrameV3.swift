// Frame v3: the one layout every offset comes from (spec 01 §6.1-§6.3, §6.8).
//
//   offset 0    1   version      0x03
//          1    4   key_epoch    u32be, 1 ≤ e ≤ 2^31-1
//          5    2   aad_len      u16be = L
//          7    L   aad          uuid_str ‖ "|hot|" ‖ writer_id ‖ "|" ‖ dec(counter)
//        7+L   12   nonce
//       19+L  |R|   ct           AES-256-GCM of R = u32be(m) ‖ gzip ‖ zero pad
//       n-16   16   tag
//
// `n` is exactly one bucket. The v1 helpers read `aad_len` at bytes 1-2, which
// is the epoch here, so nothing v1 is ever applied to a v3 frame
// (`FrameV1Reader` is separate and refuses version 3).
import CorePrimitives
import Foundation
import HasalaText

public enum FrameV3 {
  public static let version: UInt8 = 0x03
  public static let epochSize = 4
  /// Bytes before `aad`: version, epoch, aad_len.
  public static let fixedHeaderSize = 7
  public static let nonceSize = 12
  public static let tagSize = 16
  public static let payloadLengthSize = 4

  /// The size ladder (unchanged from v1).
  public static let buckets = [1024, 4096, 16384, 65536, 262_144, 524_288, 1_048_576]
  public static let maxBucket = 1_048_576
  /// The largest op-blob plaintext a seal accepts and an open inflates.
  public static let maxPlaintext = 2_097_152
  public static let maxEpoch: UInt32 = 0x7FFF_FFFF

  /// Everything that is not payload or padding: header `7+L`, nonce, the
  /// payload length and the tag.
  public static func overhead(aadLength: Int) -> Int { fixedHeaderSize + aadLength + nonceSize + payloadLengthSize + tagSize }

  public static func isBucket(_ n: Int) -> Bool { buckets.contains(n) }

  /// The smallest bucket holding `n` bytes, or `nil` past the top one.
  public static func bucket(for n: Int) -> Int? { buckets.first { n <= $0 } }

  public static func isValidEpoch(_ e: UInt32) -> Bool { e >= 1 && e <= maxEpoch }

  /// Offsets of a frame of `frameLength` bytes whose `aad_len` is `aadLength`.
  public struct Layout: Sendable, Hashable {
    public let aadLength: Int
    public let frameLength: Int

    public init(aadLength: Int, frameLength: Int) {
      self.aadLength = aadLength
      self.frameLength = frameLength
    }

    public var header: Range<Int> { 0..<(FrameV3.fixedHeaderSize + aadLength) }
    public var aad: Range<Int> { FrameV3.fixedHeaderSize..<(FrameV3.fixedHeaderSize + aadLength) }
    public var nonce: Range<Int> { header.upperBound..<(header.upperBound + FrameV3.nonceSize) }
    /// The ciphertext of `R`.
    public var region: Range<Int> { nonce.upperBound..<(frameLength - FrameV3.tagSize) }
    public var tag: Range<Int> { (frameLength - FrameV3.tagSize)..<frameLength }
    /// `|R| = n − 35 − L`.
    public var regionLength: Int { frameLength - 35 - aadLength }
  }

  /// The cleartext header fields.
  public struct Header: Sendable, Hashable {
    public let version: UInt8
    public let epoch: UInt32
    public let aadLength: Int
  }

  /// Reads the fixed header, or `nil` when the frame is shorter than it.
  public static func parseHeader(_ frame: some DataProtocol) -> Header? {
    guard frame.count >= fixedHeaderSize else { return nil }
    let b = [UInt8](frame.prefix(fixedHeaderSize))
    let epoch = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
    return Header(version: b[0], epoch: epoch, aadLength: Int(b[5]) << 8 | Int(b[6]))
  }

  /// `0x03 ‖ u32be(epoch) ‖ u16be(L) ‖ aad`.
  public static func header(epoch: UInt32, aad: some DataProtocol) -> Data {
    var h = Data([version])
    h.append(contentsOf: [UInt8(epoch >> 24), UInt8(epoch >> 16 & 0xff), UInt8(epoch >> 8 & 0xff), UInt8(epoch & 0xff)])
    h.append(contentsOf: [UInt8(aad.count >> 8), UInt8(aad.count & 0xff)])
    h.append(contentsOf: aad)
    return h
  }
}

/// A refused envelope: a programming error, never a set-aside condition.
public enum EnvelopeError: Error, Equatable, Sendable {
  case invalid(String)
}

/// The position a v3 frame is sealed at (spec 01 §6.2). Only the hot stream
/// exists (A-6), the user id is canonical and the writer id has the §4.8
/// grammar, so the AAD is `82 + digits(counter)` bytes (83 ≤ L ≤ 101).
public struct Envelope: Sendable, Hashable {
  public static let stream = "hot"

  public let userID: UserID
  public let writerID: WriterID
  public let counter: Int64

  /// `counter` is 1-based; `Int64.max` is the last counter.
  public init(userID: UserID, writerID: WriterID, counter: Int64) throws(EnvelopeError) {
    guard counter >= 1 else { throw .invalid("writer_counter is \(counter), and counters are 1-based") }
    self.userID = userID
    self.writerID = writerID
    self.counter = counter
  }

  /// `uuid_str(user_id) ‖ "|hot|" ‖ writer_id ‖ "|" ‖ dec(counter)`.
  public var aad: Data {
    Data("\(userID.string)|\(Envelope.stream)|\(writerID.string)|\(counter)".utf8)
  }
}
