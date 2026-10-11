// Reader check R0 (spec 01 §6.6): the shape of a pulled row, before anything
// is hashed or opened. A failure is `hardStop(.tampered(.rowShape))`: the
// server's CHECKs already enforce every rule here, so a row that breaks one was
// tampered with.
import CorePrimitives
import Foundation
import HasalaText

public enum RowShape {
  /// A row whose shape held, with its fields typed.
  public struct Checked: Sendable, Hashable {
    public let writerID: WriterID
    public let counter: Int64
    public let prevHash: Hash32
    public let blobHash: Hash32
    public let blob: Data
  }

  /// `stream == "hot"`, the writer id grammar (§4.8), a decimal counter ≥ 1,
  /// `size_bucket == |blob|` on the ladder, and 32-byte hashes. `nil` on any
  /// failure.
  public static func check(
    stream: String, writerID: String, counter: String, sizeBucket: Int, blob: Data, prevHash: Data, blobHash: Data
  ) -> Checked? {
    guard utf8Equal(stream, Envelope.stream), let w = WriterID(writerID) else { return nil }
    guard ASCII.isDecimal(counter), let c = Int64(counter), c >= 1 else { return nil }
    guard sizeBucket == blob.count, FrameV3.isBucket(sizeBucket) else { return nil }
    guard let p = Hash32(prevHash), let h = Hash32(blobHash) else { return nil }
    return Checked(writerID: w, counter: c, prevHash: p, blobHash: h, blob: blob)
  }
}
