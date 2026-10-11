// Clocks and randomness for tests (spec 04 §2.2 CoreTestSupport).
import CorePrimitives
import CoreTime
import CryptoKit
import Foundation
import Synchronization

/// A clock tests move by hand.
public final class FakeClock: CoreTime.Clock {
  private let ms: Mutex<Int64>
  public init(ms: Int64 = 1_791_000_000_000) { self.ms = Mutex(ms) }
  public func nowMs() -> Int64 { ms.withLock { $0 } }
  public func advance(ms d: Int64) { ms.withLock { $0 += d } }
}

/// A deterministic `RandomSource`: SHA-256 in counter mode over a seed. Never
/// for production keys.
public final class SeededRandom: RandomSource {
  private let state: Mutex<(seed: Data, counter: UInt64)>

  public init(seed: String = "hasala-test") { state = Mutex((Data(seed.utf8), 0)) }

  public func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) {
    var off = 0
    while off < buffer.count {
      let block: Data = state.withLock { s in
        var c = s.counter.bigEndian
        s.counter += 1
        return Data(SHA256.hash(data: s.seed + Data(bytes: &c, count: 8)))
      }
      for b in block where off < buffer.count {
        buffer[off] = b
        off += 1
      }
    }
  }
}

/// The CBOR subset WebAuthn uses, decoded (the fake server reads attestation
/// objects and COSE keys with it).
public indirect enum CBORValue: Sendable, Hashable {
  case int(Int64)
  case bytes(Data)
  case text(String)
  case array([CBORValue])
  case map([CBORValue: CBORValue])

  public subscript(_ k: CBORValue) -> CBORValue? {
    if case .map(let m) = self { return m[k] }
    return nil
  }

  public var bytes: Data? { if case .bytes(let d) = self { d } else { nil } }
  public var text: String? { if case .text(let s) = self { s } else { nil } }
  public var int: Int64? { if case .int(let i) = self { i } else { nil } }

  /// Decodes one item at `data[offset...]`, advancing `offset`.
  public static func decode(_ data: Data, offset: inout Int) -> CBORValue? {
    let b = [UInt8](data)
    return decode(b, &offset)
  }

  static func decode(_ b: [UInt8], _ i: inout Int) -> CBORValue? {
    guard i < b.count else { return nil }
    let major = b[i] >> 5
    let info = b[i] & 31
    i += 1
    var n: UInt64
    switch info {
    case 0..<24: n = UInt64(info)
    case 24...27:
      let len = 1 << Int(info - 24)
      guard i + len <= b.count else { return nil }
      n = 0
      for k in 0..<len { n = n << 8 | UInt64(b[i + k]) }
      i += len
    default: return nil
    }
    switch major {
    case 0: return .int(Int64(n))
    case 1: return .int(-1 - Int64(n))
    case 2, 3:
      guard i + Int(n) <= b.count else { return nil }
      let d = Data(b[i..<(i + Int(n))])
      i += Int(n)
      return major == 2 ? .bytes(d) : .text(String(decoding: d, as: UTF8.self))
    case 4:
      var a: [CBORValue] = []
      for _ in 0..<n {
        guard let v = decode(b, &i) else { return nil }
        a.append(v)
      }
      return .array(a)
    case 5:
      var m: [CBORValue: CBORValue] = [:]
      for _ in 0..<n {
        guard let k = decode(b, &i), let v = decode(b, &i) else { return nil }
        m[k] = v
      }
      return .map(m)
    default: return nil
    }
  }
}
