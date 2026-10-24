import CorePrimitives
import Foundation

public enum MessageIDEvidence {
  public static func normalized(headers: String) -> String? {
    var value: String?
    var collecting = false
    for line in headers.components(separatedBy: "\n") {
      let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
      if collecting {
        if l.first == " " || l.first == "\t" {
          value! += l
          continue
        }
        break
      }
      guard let colon = l.firstIndex(of: ":") else { continue }
      let name = l[..<colon].trimmingCharacters(in: .whitespaces)
      guard name.utf8.count == 10, name.lowercased() == "message-id" else { continue }
      value = String(l[l.index(after: colon)...])
      collecting = true
    }
    guard var v = value?.trimmingCharacters(in: .whitespaces) else { return nil }
    if v.hasPrefix("<"), let close = v.firstIndex(of: ">") {
      v = String(v[v.index(after: v.startIndex)..<close])
    }
    let folded = v.utf8.filter { $0 != 0x20 && $0 != 0x09 }.map(asciiLower)
    guard !folded.isEmpty else { return nil }
    return String(decoding: folded, as: UTF8.self)
  }

  public static func hash(headers: String) -> String? {
    guard let id = normalized(headers: headers) else { return nil }
    return Hex.encode(sha256(Data(id.utf8)).prefix(16))
  }
}
