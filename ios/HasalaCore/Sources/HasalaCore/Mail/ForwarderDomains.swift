// The mail providers a message may pass THROUGH (the PWA's senders.ts FORWARDER_DOMAINS, which
// mirrors the server-side origin.ForwarderDomains byte for byte): none of them can ever be a
// trusted sender. Spec 04 §7.6 excludes them from the trusted set and from the sender query,
// and "Trust <domain>" / "Add a sender" never offer one (spec 03c §7.2 calls the list
// ForwarderDomains.v1). Matching is permissive the same way: a subdomain counts.

public enum ForwarderDomains {
  /// ForwarderDomains.v1, sorted. Frozen: a change is a new version, never an edit.
  public static let v1: [String] = [
    "apple.com", "fastmail.com", "gmail.com", "google.com", "googlemail.com", "hotmail.com", "icloud.com",
    "live.com", "mac.com", "me.com", "messagingengine.com", "microsoft.com", "outlook.com", "proton.me",
    "protonmail.ch", "protonmail.com", "yahoo.com", "zoho.com",
  ]

  /// Whether `domain` is, or is under, a known forwarder: trimmed (JavaScript `trim`),
  /// lower-cased, one trailing dot dropped, then an exact or `.<forwarder>` suffix match.
  public static func contains(_ domain: String) -> Bool {
    var d = AuthResults.jsLower(AuthResults.jsTrim(Array(domain.unicodeScalars)))
    if d.last == "." { d.removeLast() }
    if d.isEmpty { return false }
    let bytes = Array(AuthResults.string(d).utf8)
    for f in v1 {
      let fb = Array(f.utf8)
      if bytes == fb { return true }
      if bytes.count > fb.count && bytes[bytes.count - fb.count - 1] == 0x2e && Array(bytes.suffix(fb.count)) == fb {
        return true
      }
    }
    return false
  }
}
