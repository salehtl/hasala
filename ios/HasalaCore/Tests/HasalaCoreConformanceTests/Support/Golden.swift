import CoreJSON
import Foundation
import Testing

enum Golden {
  static let updating = ProcessInfo.processInfo.environment["HASALA_UPDATE_GOLDEN"] == "1"

  static func text(_ v: JSONValue, ascii: Bool = true) -> String {
    guard ascii else { return Pretty.text(v) }
    var out = ""
    for u in Pretty.text(v).utf16 {
      if u > 0x7e {
        let hex = String(u, radix: 16)
        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      } else {
        out.unicodeScalars.append(Unicode.Scalar(u)!)
      }
    }
    return out
  }

  static func keepingLayout(of committed: JSONValue?, _ computed: JSONValue) -> JSONValue {
    switch (committed, computed) {
    case (.object(let old)?, .object(let new)):
      var pairs: [(String, JSONValue)] = []
      for k in old.keys { if let v = new[k] { pairs.append((k, keepingLayout(of: old[k], v))) } }
      for k in new.keys where old[k] == nil { pairs.append((k, new[k]!)) }
      return .object(JSONObject(pairs))
    case (.array(let old)?, .array(let new)) where old.count == new.count:
      return .array(zip(old, new).map { keepingLayout(of: $0, $1) })
    default:
      return computed
    }
  }

  static func check(_ relative: String, _ doc: JSONValue, ascii: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let url = Fixtures.conformanceRoot.appendingPathComponent(relative)
    let committed = try String(contentsOf: url, encoding: .utf8)
    let now = text(keepingLayout(of: try JSONParser.parse(Array(committed.utf8)), doc), ascii: ascii)
    if updating {
      if now != committed { try Data(now.utf8).write(to: url) }
      return
    }
    #expect(
      committed == now, "\(relative): the expected output is not what Swift computes; run with HASALA_UPDATE_GOLDEN=1 and review the diff",
      sourceLocation: sourceLocation)
  }

  static func mapping(_ list: JSONValue?, _ f: (JSONValue) throws -> JSONValue) rethrows -> JSONValue {
    .array(try (list?.arrayValue ?? []).map(f))
  }
}

extension JSONValue {
  func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
    guard var o = objectValue else { return self }
    o[key] = value
    return .object(o)
  }
}
