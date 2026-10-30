// Which senders the lane lists (spec 04 §7.5, §7.6; spec 03c §7.2; port of the PWA's
// bankDomains.ts without its unfiltered fallback, PO G). Each MailSource turns a group of these
// domains into its own query (Gmail: `GmailClient.senderQuery`).
//
// The trusted set T (03c §7.2) is the sender_trust_set fold minus forwarders and shared
// suffixes. Under PO G it is ALSO the listing set: the lane asks the provider only for mail
// from T, so T empty means nothing is listed (never "list everything"). Listing is not trust: a
// listed message is filed without review only when the provider's Authentication-Results
// verdict passes for a domain in T (the trust gate, `MessageDisposer`).
import CoreMail
import CoreTemplate
import Foundation

public enum BankDomains {
  /// At most this many `from:` terms per Gmail query (spec 04 §7.5).
  public static let maxTermsPerQuery = 20
  /// Re-list overlap behind the watermark: late-delivered or clock-skewed mail is re-listed and
  /// deduplicated, never lost.
  public static let overlapMs: Int64 = 2 * 86_400_000

  /// 03c §7.2's SharedSuffixes.v1 (exact match): multi-label public suffixes no bank owns.
  public static let sharedSuffixesV1: Set<String> = [
    "ac.ae", "co.ae", "gov.ae", "mil.ae", "name.ae", "net.ae", "org.ae", "pro.ae", "sch.ae", "com.sa", "gov.sa",
    "net.sa", "org.sa", "com.qa", "com.kw", "com.bh", "com.om", "com.eg", "ac.uk", "co.uk", "gov.uk", "org.uk",
    "com.au", "co.in", "com.pk", "co.za",
  ]

  /// `^[a-z0-9-]+(\.[a-z0-9-]+)+$` (spec 04 §7.5): safe to splice into a provider's query.
  public static func isQuerySafe(_ d: String) -> Bool {
    let labels = d.utf8.split(separator: 0x2e, omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for l in labels {
      if l.isEmpty { return false }
      for b in l where !((b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x2d) { return false }
    }
    return true
  }

  /// The effective trusted set T: trusted domains, minus forwarders (and their subdomains) and
  /// shared suffixes, keeping only query-safe ones, sorted by UTF-8 bytes (03c `queryDomains`).
  public static func effectiveTrusted(_ senderTrust: [String: Bool]) -> [String] {
    senderTrust.compactMap { d, trusted -> String? in
      guard trusted, isQuerySafe(d), !ForwarderDomains.contains(d), !sharedSuffixesV1.contains(d) else { return nil }
      return d
    }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
  }

  /// `domain == s || domain` ends with `.s` for some s in `set` (never a bare suffix:
  /// `notdib.ae` is not `dib.ae`).
  public static func isMember(_ domain: String, of set: [String]) -> Bool {
    guard !domain.isEmpty else { return false }
    let d = Array(domain.utf8)
    for s in set {
      let sb = Array(s.utf8)
      if d == sb { return true }
      if d.count > sb.count, d[d.count - sb.count - 1] == 0x2e, Array(d.suffix(sb.count)) == sb { return true }
    }
    return false
  }

  /// The domains cut, in order, into groups of at most `size` (a source's `maxSendersPerList`).
  public static func groups(_ domains: [String], size: Int = maxTermsPerQuery) -> [[String]] {
    let size = max(1, size)
    return stride(from: 0, to: domains.count, by: size).map {
      Array(domains[$0..<min($0 + size, domains.count)])
    }
  }

  /// `floor((watermark − OVERLAP) / 1000)`, never negative.
  public static func sinceSec(watermarkMs: Int64) -> Int64 {
    max(0, (watermarkMs - overlapMs) / 1000)
  }

  /// The domain of an address or a `From:` value, ASCII-lower-cased: the addr-spec the A-R rule
  /// reads (`AuthResults.fromDomain`). A value that rule cannot read never passes it; for those,
  /// the part after the last `@`, cut at `>` or whitespace; "" when there is none.
  public static func domainOf(_ address: String) -> String {
    let read = AuthResults.fromDomain(address)
    if !read.isEmpty { return read }
    let u = Array(address.utf8)
    guard let at = u.lastIndex(of: 0x40) else { return "" }
    var out: [UInt8] = []
    for b in u[(at + 1)...] {
      if b == 0x3e || b == 0x20 || b == 0x09 || b == 0x0d || b == 0x0a || b == 0x22 || b == 0x29 { break }
      out.append(asciiLower(b))
    }
    while out.last == 0x2e { out.removeLast() }
    return String(decoding: out, as: UTF8.self)
  }

  /// The sender domains of a bank's bundled templates (Setup's bank step authors
  /// `sender_trust_set {trusted: true}` for each, 03c §7.2), lower-cased, sorted, unique.
  public static func templateDomains(bank: String, templates: [TemplateDefinition]) -> [String] {
    var out = Set<String>()
    for t in templates where t.bank == bank {
      for d in t.match.senderDomain { out.insert(asciiLowered(d)) }
    }
    return out.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
  }

  public enum TypedDomainError: Error, Sendable, Equatable {
    case empty, notQuerySafe, forwarder, sharedSuffix, nonASCII, addressRequired
  }

  /// "Add a sender": a typed domain or address, normalized (trim, ASCII lower-case, one trailing
  /// dot and a leading `@` or local part dropped), then refused if it is a forwarder, a shared
  /// suffix, non-ASCII or not query-safe (03c §7.2 author rules).
  public static func normalizeTyped(_ typed: String) throws(TypedDomainError) -> String {
    var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.unicodeScalars.contains(where: { !$0.isASCII }) { throw .nonASCII }
    if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
    s = asciiLowered(s)
    if s.hasSuffix(".") { s.removeLast() }
    if s.isEmpty { throw .empty }
    guard isQuerySafe(s) else { throw .notQuerySafe }
    if ForwarderDomains.contains(s) { throw .forwarder }
    if sharedSuffixesV1.contains(s) { throw .sharedSuffix }
    return s
  }

  public static func normalizeTypedAddress(_ typed: String) throws(TypedDomainError) -> String {
    let s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.unicodeScalars.contains(where: { !$0.isASCII }) { throw .nonASCII }
    if s.isEmpty { throw .empty }
    guard let at = s.lastIndex(of: "@"), at != s.startIndex else { throw .addressRequired }
    let domain = try normalizeTyped(String(s[s.index(after: at)...]))
    let address = String(s[..<at]) + "@" + domain
    guard OutlookSenders.isQuerySafe(address) else { throw .notQuerySafe }
    return address
  }
}
