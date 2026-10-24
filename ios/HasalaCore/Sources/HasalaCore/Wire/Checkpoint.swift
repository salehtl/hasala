// `writer_checkpoint` payloads (wire/op.ts `encodeCheckpointPayload`,
// `decodeCheckpointPayload`): the one payload whose bytes the executors must
// agree on, so its heads are sorted by (writer_id, stream) in UTF-8 byte order
// and each head's keys are in Go's struct order.
import CoreJSON
import CorePrimitives
import Foundation
import HasalaText

public struct CheckpointHead: Sendable, Hashable {
  public let writerID: String
  public let stream: String
  /// A decimal string: counters are never JSON numbers.
  public let counter: String
  /// 64 lower-case hex characters.
  public let hash: String

  public init(writerID: String, stream: String, counter: String, hash: String) {
    self.writerID = writerID
    self.stream = stream
    self.counter = counter
    self.hash = hash
  }
}

public enum Checkpoint {
  /// The canonical payload `{"heads":[…]}`: validated, sorted, duplicates refused.
  public static func encodePayload(_ heads: [CheckpointHead]) throws(OpValidationError) -> JSONValue {
    for h in heads {
      if let m = problem(h) { throw .invalid(m) }
    }
    let sorted = heads.sorted { compare($0, $1) < 0 }
    for i in sorted.indices.dropFirst() where compare(sorted[i - 1], sorted[i]) == 0 {
      throw .invalid("duplicate checkpoint head for (\(sorted[i].writerID), \(sorted[i].stream))")
    }
    return .object(JSONObject([("heads", .array(sorted.map { .object(object($0)) }))]))
  }

  /// Reads a payload, refusing one that is not canonically ordered.
  public static func decodePayload(_ payload: JSONValue) throws(WireDecodeError) -> [CheckpointHead] {
    guard let o = payload.objectValue else { throw .setAside("checkpoint payload is not an object") }
    guard let raw = o["heads"]?.arrayValue else { throw .setAside("checkpoint payload has no heads array") }
    var heads: [CheckpointHead] = []
    for h in raw {
      guard let r = h.objectValue else { throw .setAside("checkpoint head is not an object") }
      if let m = rawProblem(r) { throw .setAside(m) }
      heads.append(
        CheckpointHead(
          writerID: r["writer_id"]!.stringValue!, stream: r["stream"]!.stringValue!,
          counter: r["counter"]!.stringValue!, hash: r["hash"]!.stringValue!))
    }
    for i in heads.indices.dropFirst() {
      let c = compare(heads[i - 1], heads[i])
      if c > 0 { throw .setAside("checkpoint heads are not sorted by (writer_id, stream)") }
      if c == 0 { throw .setAside("duplicate checkpoint head for (\(heads[i].writerID), \(heads[i].stream))") }
    }
    return heads
  }

  static func compare(_ a: CheckpointHead, _ b: CheckpointHead) -> Int {
    let c = compareUTF8(a.writerID, b.writerID)
    return c != 0 ? c : compareUTF8(a.stream, b.stream)
  }

  static func object(_ h: CheckpointHead) -> JSONObject {
    JSONObject([
      ("writer_id", .string(h.writerID)), ("stream", .string(h.stream)), ("counter", .string(h.counter)),
      ("hash", .string(h.hash)),
    ])
  }

  static func problem(_ h: CheckpointHead) -> String? { rawProblem(object(h)) }

  /// wire/op.ts `validateHead`, its messages included.
  static func rawProblem(_ r: JSONObject) -> String? {
    guard let w = r["writer_id"]?.stringValue, !w.isEmpty else { return "checkpoint head has no writer_id" }
    guard let stream = r["stream"]?.stringValue, !stream.isEmpty else {
      return "checkpoint head for \(showValue(.string(w))) names no stream"
    }
    guard ASCII.isDecimal(r["counter"]?.stringValue ?? "") else {
      return "want a decimal-integer string, got \(showValue(r["counter"]))"
    }
    guard ASCII.isLowerHex(r["hash"]?.stringValue ?? "", count: 64) else {
      return "checkpoint head for \(showValue(.string(w))) has hash \(showValue(r["hash"])), want 64 hex chars"
    }
    return nil
  }
}
