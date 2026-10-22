import HasalaText

public struct MerchantGroup: Sendable {
  public static let maxKeyRunes = 256

  public let bundle: String
  let entries: [PreparedPattern]

  public init(dictionary: MerchantDictionary) {
    bundle = dictionary.bundle
    entries = Matcher.prepare(rules: [], entries: dictionary.entries).entries
  }

  public static func key(raw: String, dictionary: MerchantDictionary) -> String {
    MerchantGroup(dictionary: dictionary).key(raw: raw)
  }

  public func key(raw: String) -> String {
    let subject = Canon.subject(raw)
    let bytes = Array(subject.utf8)
    if bytes.isEmpty { return "" }
    if let hit = entries.first(where: { $0.hits(bytes) }) {
      let name = hit.display.map(Canon.canonical) ?? ""
      let key = name.isEmpty ? "e:\(hit.match.rawValue):\(hit.pattern)" : "d:" + name
      return Canon.truncateRunes(key, Self.maxKeyRunes)
    }
    return Canon.truncateRunes("n:" + Self.name(subject), Self.maxKeyRunes)
  }

  public static func name(_ subject: String) -> String {
    let bytes = Array(subject.utf8)
    var tokens = cleaned(unstarred(bytes))
    if tokens.isEmpty { tokens = cleaned(bytes.filter { $0 != star }) }
    if tokens.isEmpty { return subject }
    return String(decoding: Array(tokens.joined(separator: [space])), as: UTF8.self)
  }

  static let star: UInt8 = 0x2a
  static let space: UInt8 = 0x20

  static let facilitators: [[UInt8]] = [
    "paypal", "pp", "google", "sq", "sp", "tst", "sumup", "iz", "izettle", "zettle", "amzn", "apple.com/bill", "paddle.net", "fs",
    "2co.com", "dd",
  ].map { Array($0.utf8) }

  static let legal: [[UInt8]] = [
    "llc", "l.l.c", "inc", "ltd", "limited", "trdg", "fze", "fzco", "fz", "fz-llc", "fzllc", "est", "corp", "plc", "gmbh",
  ].map { Array($0.utf8) }

  static let countries: [[UInt8]] = [
    "ae", "are", "uae", "us", "usa", "gb", "gbr", "uk", "ie", "irl", "nl", "nld", "sg", "sgp", "lu", "lux", "au", "aus", "ca", "deu",
    "fra", "ind", "sa", "sau", "ksa", "qa", "qat", "om", "omn", "bh", "bhr", "kw", "kwt", "eg", "egy", "hk", "hkg", "ch", "che",
  ].map { Array($0.utf8) }

  static func unstarred(_ bytes: [UInt8]) -> [UInt8] {
    var rest = bytes
    while let i = rest.firstIndex(of: star) {
      let before = trimmedSpaces(Array(rest[..<i]))
      let after = trimmedSpaces(Array(rest[(i + 1)...]))
      if before.isEmpty {
        rest = after
        continue
      }
      guard isFacilitator(before) else {
        rest = before
        continue
      }
      let merchant = cleaned(after.filter { $0 != star })
      if merchant.isEmpty || merchant.allSatisfy(hasDigit) {
        rest = before
      } else {
        rest = after
      }
    }
    return rest
  }

  static func cleaned(_ bytes: [UInt8]) -> [[UInt8]] {
    var tokens: [[UInt8]] = []
    for raw in bytes.split(separator: space) {
      var t = trimmedPunctuation(Array(raw))
      if t.count > 4, t.starts(with: Array("www.".utf8)) { t = trimmedPunctuation(Array(t.dropFirst(4))) }
      if t.count > 4, t.suffix(4).elementsEqual(".com".utf8) { t = trimmedPunctuation(Array(t.dropLast(4))) }
      if t.isEmpty { continue }
      if !tokens.isEmpty && legal.contains(t) { continue }
      tokens.append(t)
    }
    while tokens.count > 1, let last = tokens.last, hasDigit(last) || countries.contains(last) || legal.contains(last) {
      tokens.removeLast()
    }
    return tokens
  }

  static func isFacilitator(_ prefix: [UInt8]) -> Bool {
    guard let first = prefix.split(separator: space).first else { return false }
    return facilitators.contains(trimmedPunctuation(Array(first)))
  }

  static func hasDigit(_ token: [UInt8]) -> Bool { token.contains(where: ASCII.isDigit) }

  static func trimmedSpaces(_ bytes: [UInt8]) -> [UInt8] {
    guard let start = bytes.firstIndex(where: { $0 != space }), let end = bytes.lastIndex(where: { $0 != space }) else { return [] }
    return Array(bytes[start...end])
  }

  static func trimmedPunctuation(_ bytes: [UInt8]) -> [UInt8] {
    guard let start = bytes.firstIndex(where: isKept), let end = bytes.lastIndex(where: isKept) else { return [] }
    return Array(bytes[start...end])
  }

  static func isKept(_ b: UInt8) -> Bool { b >= 0x80 || ASCII.isDigit(b) || ASCII.isLower(b) || ASCII.isUpper(b) }
}
