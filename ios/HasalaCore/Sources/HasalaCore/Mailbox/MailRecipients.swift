import Foundation

public enum RecipientCheck: String, Sendable, Codable {
  case confirmed, unconfirmed, mismatch
}

public enum MailRecipients {
  static let gmailDomains: Set<String> = ["gmail.com", "googlemail.com"]

  public static func check(
    linked: String?, headers: String, provider: MailProviderID, signingDomain: String?, signature: String?
  ) -> RecipientCheck {
    guard let linked, let want = canonical(linked, provider: provider) else { return .mismatch }
    let fields = headerFields(headers)
    var anyAddress = false
    var named: Set<String> = []
    for f in fields where f.name == "to" || f.name == "cc" {
      for a in scan(stripQuotesAndComments(Array(f.value.utf8))) {
        anyAddress = true
        if canonical(a, provider: provider) == want { named.insert(f.name) }
      }
    }
    if !anyAddress { return .unconfirmed }
    if named.isEmpty { return .mismatch }
    let signed = signedNames(fields: fields, domain: signingDomain, signature: signature)
    for name in named {
      let present = fields.filter { $0.name == name }.count
      if let covered = signed?[name], covered >= present { return .confirmed }
    }
    return .unconfirmed
  }

  public static func canonical(_ address: String, provider: MailProviderID) -> String? {
    var u = Array(address.utf8).map(asciiLower)
    while let f = u.first, f == 0x20 || f == 0x09 { u.removeFirst() }
    while let l = u.last, l == 0x20 || l == 0x09 || l == 0x2e { u.removeLast() }
    guard let at = u.lastIndex(of: 0x40), at > 0, at < u.count - 1 else { return nil }
    var local = Array(u[..<at])
    var domain = String(decoding: u[(at + 1)...], as: UTF8.self)
    if provider == .gmail {
      if let plus = local.firstIndex(of: 0x2b) { local = Array(local[..<plus]) }
      if gmailDomains.contains(domain) {
        local.removeAll { $0 == 0x2e }
        domain = "gmail.com"
      }
    }
    guard !local.isEmpty, domain.utf8.contains(0x2e) else { return nil }
    return String(decoding: local, as: UTF8.self) + "@" + domain
  }

  static func signedNames(fields: [(name: String, value: String)], domain: String?, signature: String?) -> [String: Int]? {
    guard let domain, !domain.isEmpty else { return nil }
    var candidates: [[String: String]] = []
    for f in fields where f.name == "dkim-signature" {
      let tags = tagList(f.value)
      guard let d = tags["d"], d.lowercased() == domain else { continue }
      if let signature, !(tags["b"] ?? "").hasPrefix(signature) { continue }
      candidates.append(tags)
    }
    guard !candidates.isEmpty else { return nil }
    var out: [String: Int]?
    for tags in candidates {
      var counts: [String: Int] = [:]
      for n in (tags["h"] ?? "").split(separator: ":") {
        counts[n.trimmingCharacters(in: .whitespaces).lowercased(), default: 0] += 1
      }
      if let prev = out {
        out = Dictionary(uniqueKeysWithValues: prev.compactMap { k, v in counts[k].map { (k, min(v, $0)) } })
      } else {
        out = counts
      }
    }
    return out
  }

  static func tagList(_ value: String) -> [String: String] {
    var out: [String: String] = [:]
    for part in value.split(separator: ";") {
      guard let eq = part.firstIndex(of: "=") else { continue }
      let name = part[..<eq].filter { !$0.isWhitespace }.lowercased()
      let v = String(part[part.index(after: eq)...].filter { !$0.isWhitespace })
      if out[name] == nil { out[name] = v }
    }
    return out
  }

  static func headerFields(_ headers: String) -> [(name: String, value: String)] {
    var out: [(name: String, value: String)] = []
    let lines = headers.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
    for line in lines {
      if line.first == " " || line.first == "\t" {
        if !out.isEmpty { out[out.count - 1].value += line }
        continue
      }
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      out.append((name, String(line[line.index(after: colon)...])))
    }
    return out
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
