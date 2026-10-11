// Charset resolution for the normalizer, stage 2: a port of norm/charset.ts over the generated
// CharsetTables.swift.
//
// Four outcomes, exactly as the Go normalizer's registry decides them:
//
//   kind          bytes                 error raised
//   passthrough   undecoded to stage 3  none
//   unresolved    undecoded to stage 3  unknown-charset (tolerated on the top-level entity,
//                                       fatal to a sub-part walk)
//   singleByte    table-decoded         none
//   unsupported   (none)                UnsupportedCharset (thrown, never guessed)
//
// `unsupported` is where Go uses a stateful or multi-byte codec (UTF-16, Shift_JIS, GB*,
// ISO-2022-*) that no other executor reproduces byte for byte. Swift refuses those exactly as
// the TypeScript twin does; the caller routes the message to review (nothing is dropped).

/// How a declared charset label is treated.
enum CharsetKind: Equatable, Sendable {
  case passthrough
  case unresolved
  case singleByte(Int)  // index into CharsetTables.tables
  case unsupported
}

enum Charset {
  /// A Content-Type `charset` label (go-message's four-step chain, as generated).
  static func classify(_ label: String) -> CharsetKind {
    let low = NormText.jsLower(label)
    // Every listed label is ASCII, and for ASCII text `String` equality is byte equality; a
    // non-ASCII label (which `String ==` could find canonically equal to an ASCII one, as
    // U+037E is to `;`) is unresolved by construction.
    guard isASCII(low) else { return .unresolved }
    if CharsetTables.passthrough.contains(low) { return .passthrough }
    if CharsetTables.unsupported.contains(low) { return .unsupported }
    if let i = CharsetTables.singleByte[low] { return .singleByte(i) }
    return .unresolved
  }

  /// An RFC 2047 encoded-word label (htmlindex alone). `.unresolved` here means the word fails
  /// and the whole field keeps its raw value.
  static func classifyWord(_ label: String) -> CharsetKind {
    let low = NormText.jsLower(label)
    guard isASCII(low) else { return .unresolved }
    if CharsetTables.wordUnsupported.contains(low) { return .unsupported }
    if let i = CharsetTables.wordSingleByte[low] { return .singleByte(i) }
    return .unresolved
  }

  static func isASCII(_ s: String) -> Bool { s.utf8.allSatisfy { $0 < 0x80 } }

  /// Decodes bytes through one generated 256-entry table.
  static func decodeSingleByte(table: Int, _ bytes: some Sequence<UInt8>) -> String {
    let t = CharsetTables.tables[table]
    var out = String.UnicodeScalarView()
    for b in bytes {
      // Every table entry is a BMP scalar (the generator checks), never a surrogate.
      out.append(Unicode.Scalar(t[Int(b)]) ?? "\u{FFFD}")
    }
    return String(out)
  }
}
