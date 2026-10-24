// The effective trusted-sender set (spec 03c §7.2), a READER rule over the
// folded `sender_trust_set` records:
//   T = {d | trusted} \ (ForwarderDomains.v1 ∪ SharedSuffixes.v1)
// `queryDomains(T)` is T sorted by UTF-8 bytes; the Gmail lane builds its
// `from:` queries from it, so mail from any other sender is never listed.
import CoreReplay
import HasalaText

public enum SenderTrust {
  /// ForwarderDomains.v1 (frozen; equal to CoreMail's `ForwarderDomains.v1`, the
  /// PWA's senders.ts list). A domain is excluded if it is one or under one.
  public static let forwardersV1: [String] = [
    "apple.com", "fastmail.com", "gmail.com", "google.com", "googlemail.com", "hotmail.com", "icloud.com",
    "live.com", "mac.com", "me.com", "messagingengine.com", "microsoft.com", "outlook.com", "proton.me",
    "protonmail.ch", "protonmail.com", "yahoo.com", "zoho.com",
  ]

  /// SharedSuffixes.v1 (exact match only, so `bank.co.ae` stays valid).
  public static let sharedSuffixesV1: [String] = [
    "ac.ae", "co.ae", "gov.ae", "mil.ae", "name.ae", "net.ae", "org.ae", "pro.ae", "sch.ae", "com.sa", "gov.sa", "net.sa",
    "org.sa", "com.qa", "com.kw", "com.bh", "com.om", "com.eg", "ac.uk", "co.uk", "gov.uk", "org.uk", "com.au", "co.in",
    "com.pk", "co.za",
  ]

  public static func isForwarder(_ d: String) -> Bool { forwardersV1.contains { utf8Equal(d, $0) || isUnder(d, $0) } }
  public static func isSharedSuffix(_ d: String) -> Bool { sharedSuffixesV1.contains { utf8Equal(d, $0) } }

  static func isUnder(_ d: String, _ parent: String) -> Bool {
    let p = ("." + parent).utf8
    return d.utf8.count > p.count && d.utf8.suffix(p.count).elementsEqual(p)
  }

  /// Why a trusted domain is ignored (03c §7.3 `ignored`), or nil when effective.
  public static func ignored(_ d: String) -> String? {
    if isForwarder(d) { return "forwarder" }
    if isSharedSuffix(d) { return "shared_suffix" }
    return nil
  }

  /// T, sorted by UTF-8 bytes (`queryDomains`).
  public static func queryDomains(_ state: State) -> [String] {
    state.senderTrust.filter { $0.value.value && ignored($0.key) == nil }.keys.sorted { compareUTF8($0, $1) < 0 }
  }

  /// `isTrusted(verified)`: equal to, or a subdomain of, a member of T.
  public static func isTrusted(_ verified: String, _ t: [String]) -> Bool {
    t.contains { utf8Equal(verified, $0) || isUnder(verified, $0) }
  }

  public enum Refusal: String, Error, Sendable {
    case forwarderDomain = "forwarder_domain"
    case sharedSuffix = "shared_suffix"
    case nonASCIIDomain = "non_ascii_domain"
    case tooManySenders = "too_many_senders"
    case notADomain = "not_a_domain"
  }

  /// The author's normalization (03c §7.2): trim, ASCII lower-case, one trailing
  /// dot dropped, a leading `@` or an address's local part dropped.
  public static func normalize(_ typed: String) -> Result<String, Refusal> {
    var s = typed.trimming(.jsTrim)
    if s.unicodeScalars.contains(where: { !$0.isASCII }) { return .failure(.nonASCIIDomain) }
    s = ASCII.lowercased(s)
    if let at = s.utf8.lastIndex(of: 0x40) { s = String(s[s.utf8.index(after: at)...]) }
    if s.utf8.last == 0x2e { s = String(s.dropLast()) }
    guard Grammar.isDomain(s) else { return .failure(.notADomain) }
    return .success(s)
  }
}
