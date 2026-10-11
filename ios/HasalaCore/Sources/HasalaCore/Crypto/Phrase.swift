// The recovery phrase (spec 01 §4.3): 16 bytes of entropy `E`, shown as twelve
// BIP-39 English words. Every derivation uses the 16 bytes, never the string.
//
//   checksum = SHA256(E)[0] >> 4;  E ‖ checksum (132 bits) → twelve 11-bit indices, MSB first
//
// Typed input is normalized exactly once, here, and only for matching words:
// NFKD, `lowercased()`, every run of the JavaScript `\s` set W collapsed to one
// U+0020, trimmed, split on U+0020. Then: twelve words (`length`), each an exact
// list word (`unknownWord`, no prefix matching), and the checksum (`checksum`).
//
// `E`, the words and everything derived from them are never persisted, logged,
// put on the pasteboard or sent (the phrase box is the one sealed exception).
import CorePrimitives
import Foundation

public enum PhraseError: Error, Equatable, Sendable {
  /// Not twelve words.
  case length(count: Int)
  /// The word at `index` (0-based) is not in the list.
  case unknownWord(index: Int, word: String)
  /// Twelve list words whose checksum does not hold.
  case checksum
  /// Entropy that is not 16 bytes (a caller bug).
  case entropyLength(Int)
}

public enum Phrase {
  public static let wordCount = 12
  public static let entropyByteCount = 16

  private static let index: [String: Int] = {
    var d = [String: Int](minimumCapacity: 2048)
    for (i, w) in BIP39English.words.enumerated() { d[w] = i }
    return d
  }()

  /// Fresh entropy `E` from `random` (spec 01 §4.3).
  public static func generate(random: some RandomSource) throws(PrimitivesError) -> SecureBytes {
    SecureBytes(copying: try random.bytes(entropyByteCount))
  }

  /// The twelve words of 16 bytes of entropy.
  public static func words(entropy: some ContiguousBytes) throws(PhraseError) -> [String] {
    let e = entropy.withUnsafeBytes { [UInt8]($0) }
    guard e.count == entropyByteCount else { throw .entropyLength(e.count) }
    let checksum = sha256(e)[0] >> 4
    var out: [String] = []
    out.reserveCapacity(wordCount)
    for w in 0..<wordCount {
      var v = 0
      for b in 0..<11 {
        let bit = w * 11 + b
        let set: Bool
        if bit < 128 {
          set = (e[bit / 8] >> (7 - UInt8(bit % 8))) & 1 == 1
        } else {
          set = (checksum >> (3 - UInt8(bit - 128))) & 1 == 1
        }
        v = v << 1 | (set ? 1 : 0)
      }
      out.append(BIP39English.words[v])
    }
    return out
  }

  /// Typed input → words, by the §4.3 normalization (no validation).
  public static func normalize(_ typed: String) -> [String] {
    let folded = typed.decomposedStringWithCompatibilityMapping.lowercased()
    var scalars = String.UnicodeScalarView()
    var inRun = false
    for s in folded.unicodeScalars {
      if isW(s) {
        if !inRun { scalars.append(" ") }
        inRun = true
      } else {
        scalars.append(s)
        inRun = false
      }
    }
    var text = String(scalars)
    while text.unicodeScalars.first == " " { text.unicodeScalars.removeFirst() }
    while text.unicodeScalars.last == " " { text.unicodeScalars.removeLast() }
    // An input of nothing but W is zero words (the Go generator's reading,
    // pinned by crypto-v3/phrase.json). After the collapse and trim there are no
    // empty words otherwise.
    if text.isEmpty { return [] }
    return text.unicodeScalars.split(separator: " ", omittingEmptySubsequences: false).map { String($0) }
  }

  /// Validates twelve words and returns their entropy.
  public static func entropy(words: [String]) throws(PhraseError) -> SecureBytes {
    guard words.count == wordCount else { throw .length(count: words.count) }
    var indices: [Int] = []
    for (i, w) in words.enumerated() {
      guard let v = index[w], BIP39English.words[v].utf8.elementsEqual(w.utf8) else {
        throw .unknownWord(index: i, word: w)
      }
      indices.append(v)
    }
    var bits = [UInt8](repeating: 0, count: 17)  // 132 bits, MSB first
    for (w, v) in indices.enumerated() {
      for b in 0..<11 where (v >> (10 - b)) & 1 == 1 {
        let bit = w * 11 + b
        bits[bit / 8] |= 0x80 >> UInt8(bit % 8)
      }
    }
    let e = SecureBytes(copying: Array(bits[0..<16]))
    let want = bits[16] >> 4
    let got = e.withUnsafeBytes { sha256($0)[0] >> 4 }
    for i in bits.indices { bits[i] = 0 }
    guard constantTimeEquals([want], [got]) else { throw .checksum }
    return e
  }

  /// Typed input → entropy: normalize, then validate.
  public static func entropy(typed: String) throws(PhraseError) -> SecureBytes {
    try entropy(words: normalize(typed))
  }

  /// Four distinct word positions (0-based, ascending) for the confirmation step
  /// (spec 04 §6.2, PO F), drawn from `random` without modulo bias.
  public static func confirmationPositions(random: some RandomSource) throws(PrimitivesError) -> [Int] {
    var picked = Set<Int>()
    while picked.count < 4 {
      let b = try random.bytes(1)[0]
      guard b < 240 else { continue }  // 240 = 20 × 12
      picked.insert(Int(b) % wordCount)
    }
    return picked.sorted()
  }

  /// The JavaScript `\s` set W of spec 01 §4.3.
  static func isW(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
  }
}
