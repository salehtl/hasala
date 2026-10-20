import Foundation

public enum MailRecipients {
  static let gmailDomains: Set<String> = ["gmail.com", "googlemail.com"]

  public static func addresses(headers: String) -> [String] {
    var out: [String] = []
    for value in fieldValues(headers: headers, names: ["to", "cc"]) {
      out += scan(stripQuotesAndComments(Array(value.utf8)))
    }
    return out
  }

  public static func names(_ linked: String?, headers: String) -> Bool {
    guard let linked, let want = canonical(linked) else { return false }
    return addresses(headers: headers).contains { canonical($0) == want }
  }

  public static func canonical(_ address: String) -> String? {
    var u = Array(address.utf8).map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }
    while let f = u.first, f == 0x20 || f == 0x09 { u.removeFirst() }
    while let l = u.last, l == 0x20 || l == 0x09 || l == 0x2e { u.removeLast() }
    guard let at = u.lastIndex(of: 0x40), at > 0, at < u.count - 1 else { return nil }
    var local = Array(u[..<at])
    var domain = String(decoding: u[(at + 1)...], as: UTF8.self)
    if let plus = local.firstIndex(of: 0x2b) { local = Array(local[..<plus]) }
    if gmailDomains.contains(domain) {
      local.removeAll { $0 == 0x2e }
      domain = "gmail.com"
    }
    guard !local.isEmpty, domain.utf8.contains(0x2e) else { return nil }
    return String(decoding: local, as: UTF8.self) + "@" + domain
  }

  static func fieldValues(headers: String, names: Set<String>) -> [String] {
    var values: [String] = []
    var current: String?
    let lines = headers.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
    for line in lines {
      if line.first == " " || line.first == "\t" {
        if current != nil { current! += line }
        continue
      }
      if let c = current { values.append(c) }
      current = nil
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      if names.contains(name) { current = String(line[line.index(after: colon)...]) }
    }
    if let c = current { values.append(c) }
    return values
  }

  static func stripQuotesAndComments(_ u: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var quoted = false
    var depth = 0
    var i = 0
    while i < u.count {
      let b = u[i]
      if (quoted || depth > 0) && b == 0x5c {
        i += 2
        continue
      }
      if quoted {
        if b == 0x22 { quoted = false }
        out.append(0x20)
      } else if b == 0x28 {
        depth += 1
        out.append(0x20)
      } else if depth > 0 {
        if b == 0x29 { depth -= 1 }
        out.append(0x20)
      } else if b == 0x22 {
        quoted = true
        out.append(0x20)
      } else {
        out.append(b)
      }
      i += 1
    }
    return out
  }

  static let delimiters: Set<UInt8> = [0x20, 0x09, 0x3c, 0x3e, 0x2c, 0x3b, 0x3a, 0x22, 0x28, 0x29, 0x5b, 0x5d]

  static func scan(_ u: [UInt8]) -> [String] {
    var out: [String] = []
    for (i, b) in u.enumerated() where b == 0x40 {
      var lo = i
      while lo > 0, !delimiters.contains(u[lo - 1]), u[lo - 1] != 0x40 { lo -= 1 }
      var hi = i + 1
      while hi < u.count, !delimiters.contains(u[hi]), u[hi] != 0x40 { hi += 1 }
      if lo < i, hi > i + 1 { out.append(String(decoding: u[lo..<hi], as: UTF8.self)) }
    }
    return out
  }
}
