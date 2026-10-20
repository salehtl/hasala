public enum OutlookSenders {
  public static let known: [String] = [
    "adibsms@adib.ae",
    "DIB.notification@dib.ae",
    "dib.mail@dib.ae",
    "alert@emiratesnbd.com",
  ]

  public static func addresses(for domains: [String], known: [String] = known) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for a in known where isQuerySafe(a) && BankDomains.isMember(BankDomains.domainOf(a), of: domains) {
      if seen.insert(a.lowercased()).inserted { out.append(a) }
    }
    return out
  }

  public static func isQuerySafe(_ address: String) -> Bool {
    let parts = address.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64, address.utf8.count <= 120 else { return false }
    let local = parts[0].utf8.allSatisfy { b in
      (b >= 0x61 && b <= 0x7a) || (b >= 0x41 && b <= 0x5a) || (b >= 0x30 && b <= 0x39) || b == 0x2e || b == 0x2d
        || b == 0x5f || b == 0x2b
    }
    return local && BankDomains.isQuerySafe(String(parts[1]).lowercased())
  }
}
