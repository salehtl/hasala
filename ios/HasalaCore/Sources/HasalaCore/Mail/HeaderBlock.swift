// The header block of a raw RFC 822 message (port of the PWA's mailbox/headers.ts).
//
// AuthResults bounds its input at 256 KiB, a bound on the HEADER BLOCK; handing it a whole
// message (up to 1 MB) would fail every large but ordinary HTML alert on size alone. Slicing at
// the first blank line gives the verdict exactly the fields it would have read anyway, since
// its unfolder stops there too.

public enum MailHeaders {
  /// Everything before the first blank line (`\r\n\r\n`, `\n\n` or `\r\r`, whichever starts
  /// first), or the whole text when it has none (a message with no blank line is all headers;
  /// the caller's parser bounds it).
  public static func headerBlock(_ raw: String) -> String {
    let s = Array(raw.unicodeScalars)
    var i = 0
    while i + 1 < s.count {
      let a = s[i]
      let b = s[i + 1]
      if a == "\r" && b == "\n" && i + 3 < s.count && s[i + 2] == "\r" && s[i + 3] == "\n" { break }
      if (a == "\n" && b == "\n") || (a == "\r" && b == "\r") { break }
      i += 1
    }
    guard i + 1 < s.count else { return raw }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: s[0..<i])
    return String(out)
  }

  /// The header block of raw message bytes, decoded as WHATWG UTF-8 (one U+FFFD per invalid
  /// sequence), the way the lane decodes a fetched message before reading its headers.
  public static func headerBlock(rawMessage: some Collection<UInt8>) -> String {
    headerBlock(String(decoding: rawMessage, as: UTF8.self))
  }
}
