import CoreJSON
import Foundation
import Testing

enum TextGolden {
  static let updating = ProcessInfo.processInfo.environment["HASALA_UPDATE_GOLDEN"] == "1"

  static let conformanceRoot: URL = {
    if let dir = ProcessInfo.processInfo.environment["HASALA_CONFORMANCE_DIR"], !dir.isEmpty {
      return URL(fileURLWithPath: dir, isDirectory: true)
    }
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      let candidate = dir.appendingPathComponent("conformance", isDirectory: true)
      if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("op/manifest.json").path) { return candidate }
      dir.deleteLastPathComponent()
    }
    fatalError("conformance/ not found above \(#filePath); set HASALA_CONFORMANCE_DIR")
  }()

  static func json(_ relative: String) throws -> JSONValue {
    try JSONParser.parse([UInt8](try Data(contentsOf: conformanceRoot.appendingPathComponent(relative))))
  }

  static func check(_ relative: String, _ doc: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let url = conformanceRoot.appendingPathComponent(relative)
    let committed = try String(contentsOf: url, encoding: .utf8)
    let now = ascii(keepingLayout(of: try JSONParser.parse(Array(committed.utf8)), doc))
    if updating {
      if now != committed { try Data(now.utf8).write(to: url) }
      return
    }
    #expect(
      committed == now, "\(relative): the expected output is not what Swift computes; run with HASALA_UPDATE_GOLDEN=1 and review the diff",
      sourceLocation: sourceLocation)
  }

  static func ascii(_ v: JSONValue) -> String {
    var out = ""
    for u in pretty(v).utf16 {
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

  static func pretty(_ v: JSONValue) -> String {
    var out = ""
    write(v, 0, &out)
    return out + "\n"
  }

  static func write(_ v: JSONValue, _ depth: Int, _ out: inout String) {
    let pad = String(repeating: "  ", count: depth + 1)
    let close = String(repeating: "  ", count: depth)
    switch v {
    case .array(let a) where !a.isEmpty && a.contains(where: { $0.objectValue != nil || $0.arrayValue != nil }):
      out += "[\n"
      for (i, x) in a.enumerated() {
        out += pad
        write(x, depth + 1, &out)
        out += i + 1 < a.count ? ",\n" : "\n"
      }
      out += close + "]"
    case .array(let a) where !a.isEmpty:
      out += "[\n" + a.map { pad + JSONWriter(numbers: .literal, keyOrder: .insertion).string($0) }.joined(separator: ",\n")
        + "\n" + close + "]"
    case .object(let o) where o.count > 0:
      out += "{\n"
      for (i, m) in o.members.enumerated() {
        out += pad + JSONWriter().string(.string(m.key)) + ": "
        write(m.value, depth + 1, &out)
        out += i + 1 < o.count ? ",\n" : "\n"
      }
      out += close + "}"
    default:
      out += JSONWriter(numbers: .literal, keyOrder: .insertion).string(v)
    }
  }
}

func jobj(_ pairs: [(String, JSONValue)]) -> JSONValue { .object(JSONObject(pairs)) }
