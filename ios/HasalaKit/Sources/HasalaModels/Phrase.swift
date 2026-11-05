/// A short line of copy that may carry amounts, e.g. "AED 827.28 still to check".
///
/// Amounts stay `Money` until the moment the line is drawn, so Hide amounts can
/// replace exactly the figures and leave the words (Paper "Home · Amounts hidden": "AED ••••
/// still to check", "•••• of •••• · Jan").
public struct MoneyPhrase: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
  public enum Part: Sendable, Hashable, Codable {
    case text(String)
    /// An amount; `hiddenGlyphs` is how many bullets stand in for it when hidden.
    case money(Money, style: MoneyStyle, hiddenGlyphs: Int)
    /// A signed amount: "+2,140" for money in, "−4,210.50" (U+2212) for money out.
    case signedMoney(Money, style: MoneyStyle, hiddenGlyphs: Int)
  }

  public var parts: [Part]

  public init(_ parts: [Part]) { self.parts = parts }
  public init(stringLiteral value: String) { self.parts = [.text(value)] }

  /// The line as shown. Hidden amounts become bullets; signs and words stay.
  public func rendered(hidden: Bool) -> String {
    parts.map { part in
      switch part {
      case .text(let s):
        return s
      case .money(let m, let style, let glyphs):
        return hidden ? MoneyFormat.hidden(count: glyphs) : MoneyFormat.string(m, style: style)
      case .signedMoney(let m, let style, let glyphs):
        if hidden { return MoneyFormat.hidden(count: glyphs) }
        let sign = m.minor < 0 ? "\u{2212}" : "+"
        return sign + MoneyFormat.string(m, style: style)
      }
    }.joined()
  }

  public func spoken(hidden: Bool) -> String {
    var out: [String] = []
    for (i, part) in parts.enumerated() {
      switch part {
      case .text(let s):
        guard i + 1 < parts.count else { out.append(s); continue }
        switch parts[i + 1] {
        case .money(let m, _, _), .signedMoney(let m, _, _):
          let unit = m.currency + " "
          if s.hasSuffix("+") || s.hasSuffix("\u{2212}") || s.hasSuffix("-") {
            out.append(s)
          } else {
            out.append(s.hasSuffix(unit) ? String(s.dropLast(unit.count)) : s)
          }
        case .text:
          out.append(s)
        }
      case .money(let m, let style, _):
        out.append(hidden ? MoneyFormat.hiddenSpoken : MoneyFormat.spoken(m, style: style))
      case .signedMoney(let m, let style, _):
        out.append(hidden ? MoneyFormat.hiddenSpoken : MoneyFormat.spoken(m, style: style, sign: .signed))
      }
    }
    return out.joined()
  }
}

public extension MoneyPhrase.Part {
  static func amount(_ m: Money, _ style: MoneyStyle = .exact, hidden glyphs: Int = 4) -> Self {
    .money(m, style: style, hiddenGlyphs: glyphs)
  }
}
