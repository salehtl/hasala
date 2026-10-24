import HasalaModels
import SwiftUI

/// An amount in the rounded figure face, optionally with its "AED" unit before it.
///
/// One rule set for every figure (spec 01 §6): money out is plain ink with no sign, money in is
/// "+" and green, money owed is "−" (U+2212); VoiceOver reads "plus AED 25,000" / "minus AED
/// 4,210.50". Hidden amounts become a fixed count of dots (6 for totals and the hero, 4 for
/// figures and stats, 3 for bills and rows) and read "Amount hidden". The dots draw at 55% of
/// a large figure's size with 2 pt tracking, unless the caller states the size Paper draws
/// them at in its place (`hiddenDots`, `hiddenTracking`: the Home hero's 38 with 3 pt).
///
/// A long figure never cuts or wraps: it scales down to its figure's floor (`minimumScale`),
/// and the unit scales with it by the same factor so both stay on one baseline. The unit and
/// the figure are one text for that reason.
public struct MoneyText: View {
  public enum Sign: Sendable {
    /// Money out, or a balance: no sign.
    case none
    /// Money in: "+".
    case income
    /// Money owed: "−".
    case debt

    var glyph: String {
      switch self {
      case .none: ""
      case .income: "+"
      case .debt: "\u{2212}"
      }
    }

    var spoken: String {
      switch self {
      case .none: ""
      case .income: "plus "
      case .debt: "minus "
      }
    }
  }

  let money: Money
  let figure: HFigure
  let unit: HFigure?
  let style: MoneyStyle
  let hidden: Bool
  let hiddenGlyphs: Int
  let hiddenDots: CGFloat?
  let hiddenTracking: CGFloat
  let color: Color
  let unitColor: Color?
  let unitGap: CGFloat
  let sign: Sign
  let approx: Bool

  public init(
    _ money: Money, figure: HFigure, unit: HFigure? = nil, style: MoneyStyle = .exact, hidden: Bool = false,
    hiddenGlyphs: Int = 4, hiddenDots: CGFloat? = nil, hiddenTracking: CGFloat = 2,
    color: Color = HColor.moneyOut, unitColor: Color? = nil, unitGap: CGFloat = 8, sign: Sign = .none,
    approx: Bool = false
  ) {
    self.money = money
    self.figure = figure
    self.unit = unit
    self.style = style
    self.hidden = hidden
    self.hiddenGlyphs = hiddenGlyphs
    self.hiddenDots = hiddenDots
    self.hiddenTracking = hiddenTracking
    self.color = color
    self.unitColor = unitColor
    self.unitGap = unitGap
    self.sign = sign
    self.approx = approx
  }

  /// The sign leads the whole amount: "+AED 25,000", or "+25,000.00" without a unit.
  private var shownSign: String { hidden ? "" : (approx ? "\u{2248} " : "") + sign.glyph }

  private var digits: String {
    hidden
      ? MoneyFormat.hidden(count: hiddenGlyphs)
      : (unit == nil ? shownSign : "") + MoneyFormat.string(money.minor, style: style)
  }

  public var body: some View {
    FigureLine(
      unit: unit.map { (shownSign + money.currency, $0, unitColor ?? color) },
      digits: digits, figure: hidden ? figure.forHiddenGlyphs(hiddenDots) : figure, color: color, gap: unitGap,
      hiddenTracking: hidden ? hiddenTracking : nil, numericValue: hidden ? nil : Double(money.minor)
    )
    .privacySensitive()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.spoken(money, style: style, sign: sign, approx: approx, hidden: hidden))
  }

  static func spoken(_ money: Money, style: MoneyStyle = .exact, sign: Sign = .none, approx: Bool = false,
                     hidden: Bool) -> String
  {
    hidden
      ? "Amount hidden"
      : "\(approx ? "about " : "")\(sign.spoken)\(money.currency) \(MoneyFormat.string(money.minor, style: style))"
  }
}

extension HFigure {
  /// Bullets at a large figure's full size read far heavier than the digits they replace;
  /// Paper draws them at about half size on the same baseline, or at `dots` points where a
  /// board states it. The figure's line height stays.
  func forHiddenGlyphs(_ dots: CGFloat? = nil) -> HFigure {
    var f = self
    if let dots {
      f.size = dots
    } else {
      guard size >= 28 else { return self }
      f.size = (size * 0.55).rounded()
    }
    f.leading = leading
    return f
  }
}

/// One line of figure text: an optional unit run, then the digits, scaled with Dynamic Type up
/// to the figure's cap and shrinking together to the figure's floor. Internal: `MoneyText` and
/// `AmountFigure` draw through it.
struct FigureLine: View {
  let unit: (text: String, figure: HFigure, color: Color)?
  let digits: String
  let figure: HFigure
  let color: Color
  let gap: CGFloat
  /// The dots' tracking when the digits are hidden dots; nil for digits.
  let hiddenTracking: CGFloat?
  /// The value the digits show, for the numeric roll; nil when they show no number.
  let numericValue: Double?

  var body: some View {
    FigureLineBody(line: self)
      // Outside the body, so its @ScaledMetric reads the capped size.
      .cappedDynamicType(figure)
  }
}

private struct FigureLineBody: View {
  let line: FigureLine
  @ScaledMetric private var figureSize: CGFloat
  @ScaledMetric private var unitSize: CGFloat
  @ResolvedMotion private var motion: MotionPolicy

  init(line: FigureLine) {
    self.line = line
    _figureSize = ScaledMetric(wrappedValue: line.figure.size, relativeTo: line.figure.textStyle)
    _unitSize = ScaledMetric(wrappedValue: line.unit?.figure.size ?? line.figure.size,
                             relativeTo: line.figure.textStyle)
  }

  var body: some View {
    let scale = figureSize / line.figure.size
    let extra = max(0, (line.figure.leading - line.figure.size * roundedLineRatio) * scale)
    Text(attributed(scale: scale))
      .lineLimit(1)
      // A row or compact figure never scales by design: its row reflows instead. If a container
      // squeezes it anyway, shrinking a little is still better than cutting the amount.
      .minimumScaleFactor(line.figure.minimumScale < 1 ? line.figure.minimumScale : 0.75)
      .padding(.vertical, extra / 2)
      .contentTransition(motion.isStill || line.numericValue == nil
        ? .identity : .numericText(value: line.numericValue ?? 0))
  }

  private func attributed(scale: CGFloat) -> AttributedString {
    var out = AttributedString()
    if let unit = line.unit {
      var u = AttributedString(unit.text)
      u.font = unit.figure.font(size: unitSize)
      u.foregroundColor = unit.color
      u.tracking = unit.figure.tracking * scale
      // The gap between "AED" and the figure rides on the unit's last letter, so it scales
      // with the line when it shrinks.
      if let last = u.characters.indices.last {
        u[last...].kern = line.gap * scale
      }
      out += u
    }
    var d = AttributedString(line.digits)
    d.font = line.figure.font(size: figureSize)
    d.foregroundColor = line.color
    d.tracking = line.hiddenTracking ?? line.figure.tracking * scale
    out += d
    return out
  }
}

/// The amount being typed, as the field it is (page 11 · Amount keypad): "AED", the figure at
/// display size (56/58 bold, −1.2) and a 3 × 46 accent caret after the last digit. Docked (one
/// amount on a screen): "AED" 20/24 secondary, 8 to the figure, the caret 3 after it. Inline (a
/// sheet with other rows): "AED" 22/28 primary, 6 to the figure, the caret 8 after. The figure
/// shrinks to fit before it would wrap; it never wraps. VoiceOver reads one element.
public struct AmountFigure: View {
  public enum Layout: Sendable { case docked, inline }

  let unit: String
  let entry: AmountEntry
  let caret: Bool
  let layout: Layout

  public init(unit: String = "AED", entry: AmountEntry, caret: Bool = true, layout: Layout = .docked) {
    self.unit = unit
    self.entry = entry
    self.caret = caret
    self.layout = layout
  }

  public var body: some View {
    HStack(alignment: .center, spacing: layout == .docked ? 3 : 8) {
      FigureLine(
        unit: (unit, unitFigure, layout == .docked ? HColor.textSecondary : HColor.textPrimary),
        digits: entry.display, figure: Self.figure, color: HColor.moneyOut, gap: layout == .docked ? 8 : 6,
        hiddenTracking: nil, numericValue: nil)
      if caret {
        RoundedRectangle(cornerRadius: 2)
          .fill(HColor.actionAccent)
          .frame(width: 3, height: 46)
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Amount")
    .accessibilityValue(entry.spoken(unit: unit))
  }

  private var unitFigure: HFigure {
    layout == .docked ? .displayUnit : HFigure(size: 22, leading: 28, weight: .semibold, textStyle: .title3,
                                               maxDynamicTypeSize: .accessibility3)
  }

  /// The display figure, shrinking to half before it would wrap (page 11: no floor is set).
  static let figure: HFigure = {
    var f = HFigure.display
    f.minimumScale = 0.5
    return f
  }()
}
