// The Latin-only gate of the Foundation Models tier (spec 03c §8.6.2): fixed
// tables, no ICU, no script detection. The model does not read Arabic
// reliably, so the gate is on script, not on what the SDK says it supports.
//
// Pass iff: at least 3 letter scalars; every letter in LATIN_V1; every Nd in
// 0030-0039; every combining mark in 0300-036F; every other scalar in
// 0020-007E or U+00A0. Letters and marks are told apart by general category,
// which is the one Unicode-table lookup here (the gate runs in the pipeline,
// never in the fold).
public enum LatinGate {
  static let latinV1: [ClosedRange<UInt32>] = [
    0x41...0x5A, 0x61...0x7A, 0xAA...0xAA, 0xBA...0xBA, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF,
    0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
  ]

  /// Whether the canonical `subject` may be sent to the model.
  public static func passes(_ subject: String) -> Bool {
    var letters = 0
    for s in subject.unicodeScalars {
      let v = s.value
      switch s.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        guard latinV1.contains(where: { $0.contains(v) }) else { return false }
        letters += 1
      case .decimalNumber:
        guard (0x30...0x39).contains(v) else { return false }
      case .nonspacingMark, .spacingMark, .enclosingMark:
        guard (0x300...0x36F).contains(v) else { return false }
      default:
        guard (0x20...0x7E).contains(v) || v == 0xA0 else { return false }
      }
    }
    return letters >= 3
  }
}
