import CoreCrypto
import CorePrimitives
import CoreResources
import Foundation

// Client-side rules for what people type at signup, sign-in and recovery (spec 04
// §6.1.2, §6.1.4, §6.7, §6.8). The byte-level rules live in CoreCrypto; this file maps
// them to the field states and copy the screens show.

// MARK: - Invite code (spec 04 §6.1.4; `02` §14.1's normalization)

/// A 24-character invite code of `[A-Z2-7]`.
struct InviteCode: Equatable, Hashable, Sendable {
  static let length = 24
  let value: String

  /// Uppercased, spaces and hyphens dropped.
  static func normalize(_ raw: String) -> String {
    String(raw.uppercased().unicodeScalars.filter { $0 != " " && $0 != "-" }.map(Character.init))
  }

  static func isAlphabet(_ s: String) -> Bool {
    s.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) }
  }

  init?(_ raw: String) {
    let n = Self.normalize(raw)
    guard n.unicodeScalars.count == Self.length, Self.isAlphabet(n) else { return nil }
    value = n
  }

  /// `ABCD-EFGH-IJKL-MNOP-QRST-UVWX`.
  var grouped: String { Self.group(value) }

  /// Groups any normalized text in fours, for the field.
  static func group(_ normalized: String) -> String {
    var out = ""
    for (i, c) in normalized.enumerated() {
      if i > 0, i % 4 == 0 { out.append("-") }
      out.append(c)
    }
    return out
  }

  /// What the invite field keeps of typed or pasted text: upper-cased, with spaces, line
  /// breaks, hyphens and other dashes, and invisible format and control characters
  /// dropped. Anything else stays, so a character no code holds (`1`, `0`, `#`) is shown
  /// and `SignupModel.inviteHint` says so.
  static func entryCharacters(_ raw: String) -> String {
    var out = String.UnicodeScalarView()
    for s in raw.uppercased().unicodeScalars {
      switch s.properties.generalCategory {
      case .dashPunctuation, .format, .control, .spaceSeparator, .lineSeparator, .paragraphSeparator: continue
      default: if s != "\u{2212}" { out.append(s) }  // U+2212 MINUS SIGN is a dash too
      }
    }
    return String(out)
  }
}

/// The invite field's state, derived from the code characters alone (spec 04 §6.1.4).
///
/// Every edit, typed, pasted or deleted, is applied to the characters, never to the
/// grouped text, and the text and the caret are then rebuilt from them. Typed characters
/// can never come out reordered, however fast they arrive and wherever a hyphen lands.
struct InviteCodeEntry: Equatable, Sendable {
  /// The code characters (`InviteCode.entryCharacters`): upper-cased, no separators.
  private(set) var characters: String
  /// The caret, as the number of `characters` before it.
  private(set) var caret: Int

  /// `raw`'s characters, with the caret at the end.
  init(_ raw: String = "") {
    characters = InviteCode.entryCharacters(raw)
    caret = characters.count
  }

  /// What the field shows: `ABCD-EFGH-IJKL-…`.
  var text: String { InviteCode.group(characters) }

  /// The caret's UTF-16 offset in `text` (what `UITextView.selectedRange` takes): right
  /// after the character before it, never after a hyphen.
  var textCaret: Int { InviteCode.group(String(characters.prefix(caret))).utf16.count }

  /// UIKit's edit of the shown text `shown`: `range` (UTF-16 offsets into `shown`)
  /// replaced by `replacement`. `forward` is a forward delete (the caret was at the start
  /// of `range`, not its end).
  ///
  /// The characters before `range`, then those of `replacement`, then those after it: so
  /// keys land in the order they were typed, a paste in the order it was copied. Deleting
  /// only a hyphen deletes the character next to it instead, as Delete would in a field
  /// without hyphens; otherwise Delete just after a hyphen would do nothing.
  static func edit(_ shown: String, range: NSRange, replacement: String, forward: Bool = false) -> InviteCodeEntry {
    let ns = shown as NSString
    // UIKit's range, held to the text rather than trusted.
    let lower = range.location == NSNotFound ? ns.length : min(max(range.location, 0), ns.length)
    let upper = min(lower + max(range.length, 0), ns.length)
    var before = InviteCode.entryCharacters(ns.substring(to: lower))
    var after = InviteCode.entryCharacters(ns.substring(from: upper))
    let removed = InviteCode.entryCharacters(ns.substring(with: NSRange(location: lower, length: upper - lower)))
    let inserted = InviteCode.entryCharacters(replacement)
    if inserted.isEmpty, upper > lower, removed.isEmpty {
      if forward {
        if !after.isEmpty { after.removeFirst() }
      } else if !before.isEmpty {
        before.removeLast()
      }
    }
    var entry = InviteCodeEntry()
    entry.characters = before + inserted + after
    entry.caret = (before + inserted).count
    return entry
  }
}

/// `https://hasala.app/i/<CODE>#<LINK_KEY>` (spec 04 §13.5's four rules).
struct InviteLink: Equatable, Sendable {
  var code: InviteCode
  /// The 43-character b64url key; nil when the link carries none (never proven).
  var linkKey: String?

  static func parse(_ url: URL) -> InviteLink? {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme == "https", c.host == "hasala.app", c.port == nil, c.user == nil, c.password == nil,
      c.query == nil
    else { return nil }
    let path = c.percentEncodedPath
    let fragment = c.percentEncodedFragment ?? ""
    if path == "/i" {
      // Rule 4: the legacy fragment-only form, code only.
      guard let code = InviteCode(fragment.removingPercentEncoding ?? "") else { return nil }
      return InviteLink(code: code, linkKey: nil)
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].isEmpty, parts[1] == "i",
      let seg = String(parts[2]).removingPercentEncoding, let code = InviteCode(seg)
    else { return nil }
    let keyOK =
      fragment.utf8.count == 43
      && fragment.unicodeScalars.allSatisfy {
        ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
      }
    return InviteLink(code: code, linkKey: keyOK ? fragment : nil)
  }

  /// Pasted text that is an invite link and nothing else (surrounding white space aside),
  /// held to the same rules as a link that opens the app.
  static func parse(pasted text: String) -> InviteLink? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return parse(url)
  }
}

// MARK: - Address and name (spec 04 §6.8)

enum AccountFields {
  /// The normalized address, or nil when `EmailNorm` refuses it.
  static func email(_ raw: String) -> String? { try? EmailNorm.normalize(raw) }

  /// The name to send, or nil (the field shows `AuthFailure.badName`'s copy).
  static func displayName(_ raw: String) -> String? {
    if case .success(let name) = DisplayName.validate(raw) { return name }
    return nil
  }
}

// MARK: - Passwords (spec 04 §6.1.2)

/// The new-password field's state (Paper "Password (too short)" / "(strong, confirmed)").
struct PasswordAssessment: Equatable, Sendable {
  enum Strength: Int, Equatable, Sendable, Comparable {
    case empty = 0, tooShort, weak, fair, strong

    static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
  }

  var strength: Strength
  var longEnough: Bool
  var notPersonal: Bool
  var notCommon: Bool
  /// The one message under the meter.
  var message: String?

  var acceptable: Bool { longEnough && notPersonal && notCommon && strength >= .fair }
}

enum PasswordRules {
  /// The bundled list, read once.
  static let blocklist = PasswordPolicy.Blocklist(text: CoreResources.commonPasswords())

  /// The creation checks (only where a password is created, never where one is proved).
  /// `personal` holds the name and address, which a password must not be.
  static func assess(_ password: String, personal: [String] = []) -> PasswordAssessment {
    if password.isEmpty {
      return PasswordAssessment(strength: .empty, longEnough: false, notPersonal: true, notCommon: true, message: nil)
    }
    let violation = PasswordPolicy.check(password, blocklist: blocklist)
    let lowered = password.lowercased().filter { !$0.isWhitespace }
    let notPersonal = !personal.contains { p in
      let q = p.lowercased().filter { !$0.isWhitespace }
      guard q.count >= 3 else { return false }
      return lowered == q || (lowered.contains(q) && q.count * 2 >= lowered.count)
    }
    switch violation {
    case .tooShort:
      // Paper EQ6: how far there is to go, counted as the rule counts (scalars after NFC).
      let typed = password.precomposedStringWithCanonicalMapping.unicodeScalars.count
      return PasswordAssessment(strength: .tooShort, longEnough: false, notPersonal: notPersonal, notCommon: true,
                                message: "Too short. \(typed) of \(PasswordPolicy.minScalars) characters.")
    case .tooLong:
      return PasswordAssessment(strength: .weak, longEnough: false, notPersonal: notPersonal, notCommon: true,
                                message: "Use 128 characters or fewer.")
    case .tooCommon:
      return PasswordAssessment(strength: .weak, longEnough: true, notPersonal: notPersonal, notCommon: false,
                                message: "That password is too common. Try a longer phrase or let iPhone suggest one.")
    case nil:
      break
    }
    if !notPersonal {
      return PasswordAssessment(strength: .weak, longEnough: true, notPersonal: false, notCommon: true,
                                message: "Don't use your name or email.")
    }
    // A rough meter only: length and variety. The policy above is the rule.
    let scalars = password.unicodeScalars
    let classes = [
      scalars.contains { CharacterSet.lowercaseLetters.contains($0) },
      scalars.contains { CharacterSet.uppercaseLetters.contains($0) },
      scalars.contains { CharacterSet.decimalDigits.contains($0) },
      scalars.contains { !CharacterSet.alphanumerics.contains($0) },
    ].filter { $0 }.count
    let distinct = Set(scalars).count
    let strong = scalars.count >= 16 || (classes >= 3 && distinct >= 8)
    if distinct < 5 {
      return PasswordAssessment(strength: .weak, longEnough: true, notPersonal: true, notCommon: true,
                                message: "Too many repeats. Try a short phrase instead.")
    }
    return PasswordAssessment(
      strength: strong ? .strong : .fair, longEnough: true, notPersonal: true, notCommon: true,
      message: strong ? "Strong. Hard to guess, easy for you to type." : "Good. Longer is even better.")
  }
}

// MARK: - Recovery phrase (spec 04 §6.7; 01 §4.3)

enum PhraseRules {
  static let wordCount = Phrase.wordCount

  /// A new phrase from the system random source.
  static func generate() throws(AuthFailure) -> RecoveryPhrase {
    do {
      let e = try Phrase.generate(random: SystemRandom())
      defer { e.wipe() }
      return RecoveryPhrase(words: try Phrase.words(entropy: e))
    } catch {
      throw .unsupported
    }
  }

  /// Validates typed words (length → unknown word → checksum, one S-16 message each).
  /// Returns the normalized words.
  static func validate(_ typed: String) -> Result<[String], AuthFailure> {
    let words = Phrase.normalize(typed)
    do {
      let e = try Phrase.entropy(words: words)
      e.wipe()
      return .success(words)
    } catch {
      return .failure(.badPhrase(message(error)))
    }
  }

  static func message(_ error: PhraseError) -> String {
    switch error {
    case .length(let n): "A recovery phrase has 12 words. This has \(n)."
    case .unknownWord(let i, let w): "Word \(i + 1), \u{201C}\(w)\u{201D}, isn't a recovery-phrase word."
    case .checksum: "Every word is real, but together they aren't a Hasala phrase. Two words may be swapped."
    case .entropyLength: "A recovery phrase has 12 words."
    }
  }

  /// Words from the list that start with `prefix` (the entry field's suggestions).
  static func suggestions(for prefix: String, limit: Int = 4) -> [String] {
    let p = prefix.lowercased().trimmingCharacters(in: .whitespaces)
    guard p.count >= 2 else { return [] }
    return Array(BIP39English.words.lazy.filter { $0.hasPrefix(p) }.prefix(limit))
  }

  static func isWord(_ w: String) -> Bool { BIP39English.words.contains(w) }
}
