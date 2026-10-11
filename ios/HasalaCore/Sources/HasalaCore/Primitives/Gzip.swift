// gzip level 9 and capped gunzip over the system zlib (spec 01 §2:
// `deflateInit2(level 9, Z_DEFLATED, windowBits 31, memLevel 8,
// Z_DEFAULT_STRATEGY)`, `inflateInit2(31)`).
//
// Not Compression.framework: its COMPRESSION_ZLIB is raw DEFLATE at a fixed
// level with no gzip header, CRC or level control (client-core-a §1).
//
// The gzip header zlib writes is deterministic (mtime 0, no name) but its OS
// byte is the build's OS_CODE: 19 on Apple, 3 on the Linux builds that sealed
// conformance/ts. The DEFLATE stream after the header is what level 9 pins; the
// conformance tests compare decompressed payloads, and say why.
import Foundation
import zlib

public enum Gzip {
  /// The DEFLATE level the seam contracts to (`sealBlob` compresses at 9; the
  /// compressed length decides the size bucket).
  public static let level: Int32 = 9

  /// gzip of `data` at level 9.
  public static func compress(_ data: some DataProtocol) throws(GzipError) -> Data {
    let input = [UInt8](data)
    var stream = z_stream()
    let initStatus = deflateInit2_(
      &stream, level, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, zlibVersion(),
      Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else { throw .zlib(status: initStatus) }
    defer { deflateEnd(&stream) }

    let bound = Int(deflateBound(&stream, uLong(input.count)))
    var out = [UInt8](repeating: 0, count: bound)
    let status: Int32 = input.withUnsafeBufferPointer { inp in
      out.withUnsafeMutableBufferPointer { o in
        stream.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
        stream.avail_in = uInt(inp.count)
        stream.next_out = o.baseAddress
        stream.avail_out = uInt(o.count)
        return deflate(&stream, Z_FINISH)
      }
    }
    // deflateBound guarantees a single Z_FINISH call completes the stream.
    guard status == Z_STREAM_END else { throw .zlib(status: status) }
    return Data(out[0..<Int(stream.total_out)])
  }

  /// gunzip of `data`, refusing any output past `maxOutputBytes`.
  ///
  /// The cap is enforced DURING inflation, never by measuring afterwards: a
  /// blob is attacker-influenced, and the 1 MiB top bucket can carry a stream
  /// that inflates to about a gigabyte. Memory stays bounded by the cap plus one
  /// chunk. Exactly `maxOutputBytes` of output is accepted; one byte more is
  /// refused.
  ///
  /// zlib verifies the CRC-32 and ISIZE trailer itself. Input must be exactly
  /// one gzip member: truncation, a bad trailer and trailing bytes after the
  /// member are all refused (the TypeScript seam's single-member contract; Go's
  /// multistream reader would read a concatenation, which no producer writes).
  public static func decompress(_ data: some DataProtocol, maxOutputBytes: Int) throws(GzipError) -> Data {
    let input = [UInt8](data)
    var stream = z_stream()
    let initStatus = inflateInit2_(&stream, 31, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else { throw .zlib(status: initStatus) }
    defer { inflateEnd(&stream) }

    let chunkSize = 64 * 1024
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    var out = Data()
    var finished = false

    try input.withUnsafeBufferPointer { (inp: UnsafeBufferPointer<UInt8>) throws(GzipError) in
      stream.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
      stream.avail_in = uInt(inp.count)
      while !finished {
        let (status, produced) = chunk.withUnsafeMutableBufferPointer { o -> (Int32, Int) in
          stream.next_out = o.baseAddress
          stream.avail_out = uInt(o.count)
          let s = inflate(&stream, Z_NO_FLUSH)
          return (s, o.count - Int(stream.avail_out))
        }
        switch status {
        case Z_STREAM_END: finished = true
        case Z_OK: break
        case Z_BUF_ERROR:
          // No progress possible: the input ended before the member did.
          if produced == 0 { throw .truncated }
        case Z_DATA_ERROR: throw .corrupt
        default: throw .zlib(status: status)
        }
        if produced > 0 {
          guard out.count + produced <= maxOutputBytes else { throw .overCap(maxOutputBytes) }
          out.append(contentsOf: chunk[0..<produced])
        }
        if !finished, stream.avail_in == 0, produced == 0 { throw .truncated }
      }
      guard stream.avail_in == 0 else { throw .trailingData }
    }
    return out
  }
}

public enum GzipError: Error, Equatable, Sendable {
  /// Output would exceed the cap. Raised during inflation, before the excess
  /// is materialized.
  case overCap(Int)
  /// The input ended before the gzip member did.
  case truncated
  /// Not gzip, a corrupt DEFLATE stream, or a CRC-32/ISIZE mismatch.
  case corrupt
  /// Bytes follow the single gzip member.
  case trailingData
  /// Any other zlib status.
  case zlib(status: Int32)
}
