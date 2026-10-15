import SwiftUI

/// The four bundled Inter weights.
public enum HWeight: Sendable, Hashable, CaseIterable {
  case regular, medium, semibold, bold

  /// PostScript name of the bundled face.
  public var interFace: String {
    switch self {
    case .regular: "Inter-Regular"
    case .medium: "Inter-Medium"
    case .semibold: "Inter-SemiBold"
    case .bold: "Inter-Bold"
    }
  }

  /// The CSS weight Paper uses (`--font-weight-*`).
  public var cssWeight: Int {
    switch self {
    case .regular: HFontWeight.regular
    case .medium: HFontWeight.medium
    case .semibold: HFontWeight.semibold
    case .bold: HFontWeight.bold
    }
  }

  /// One step heavier, for Bold Text (spec 01 §2.4: "Inter steps up one weight").
  public var bolder: HWeight {
    switch self {
    case .regular: .medium
    case .medium: .semibold
    case .semibold, .bold: .bold
    }
  }

  public var systemWeight: Font.Weight {
    switch self {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    }
  }
}

/// An Inter text style: size / line height, weight and tracking from the Paper
/// tokens (spec 04 §14.3). Sizes scale with Dynamic Type relative to `textStyle`.
public struct HType: Sendable, Hashable {
  public var size: CGFloat
  public var leading: CGFloat
  public var weight: HWeight
  /// Points, or a fraction of `size` when `trackingEm` is set.
  public var tracking: CGFloat
  public var trackingEm: CGFloat?
  public var uppercase: Bool
  public var textStyle: Font.TextStyle

  public init(
    size: CGFloat, leading: CGFloat, weight: HWeight, tracking: CGFloat = 0, trackingEm: CGFloat? = nil,
    uppercase: Bool = false, textStyle: Font.TextStyle
  ) {
    self.size = size
    self.leading = leading
    self.weight = weight
    self.tracking = tracking
    self.trackingEm = trackingEm
    self.uppercase = uppercase
    self.textStyle = textStyle
  }

  /// The same style at another weight (Paper often sets 15/20 at 600, 13/18 at 600).
  public func weight(_ w: HWeight) -> HType {
    var t = self
    t.weight = w
    return t
  }

  public var resolvedTracking: CGFloat { trackingEm.map { $0 * size } ?? tracking }

  public var font: Font { .custom(weight.interFace, size: size, relativeTo: textStyle) }

  // The scale (Paper `--text-*`, `--leading-*`, `--tracking-*`, `--font-weight-*`).
  public static let largeTitle = HType(size: HFontSize.largeTitle, leading: HLeading.largeTitle, weight: .bold,
                                       tracking: HTracking.largeTitle, textStyle: .largeTitle)
  public static let title1 = HType(size: HFontSize.title1, leading: HLeading.title1, weight: .bold,
                                   tracking: HTracking.title1, textStyle: .title)
  public static let title2 = HType(size: HFontSize.title2, leading: HLeading.title2, weight: .semibold,
                                   tracking: HTracking.title2, textStyle: .title2)
  /// Section headings on screens: title-2 at the section weight (700).
  public static let section = HType(size: HFontSize.title2, leading: HLeading.title2, weight: .bold,
                                    tracking: HTracking.title2, textStyle: .title2)
  public static let title3 = HType(size: HFontSize.title3, leading: HLeading.title3, weight: .semibold,
                                   tracking: HTracking.title3, textStyle: .title3)
  public static let headline = HType(size: HFontSize.headline, leading: HLeading.headline, weight: .semibold,
                                     tracking: HTracking.headline, textStyle: .headline)
  public static let body = HType(size: HFontSize.body, leading: HLeading.body, weight: .regular,
                                 tracking: HTracking.body, textStyle: .body)
  public static let callout = HType(size: HFontSize.callout, leading: HLeading.callout, weight: .regular,
                                    tracking: HTracking.callout, textStyle: .callout)
  /// List-row titles: callout at 600, as the screens draw them.
  public static let rowTitle = HType(size: HFontSize.callout, leading: HLeading.callout, weight: .semibold,
                                     tracking: HTracking.callout, textStyle: .callout)
  public static let subheadline = HType(size: HFontSize.subheadline, leading: HLeading.subheadline,
                                        weight: .regular, tracking: HTracking.subheadline, textStyle: .subheadline)
  public static let footnote = HType(size: HFontSize.footnote, leading: HLeading.footnote, weight: .regular,
                                     tracking: HTracking.footnote, textStyle: .footnote)
  public static let caption1 = HType(size: HFontSize.caption1, leading: HLeading.caption1, weight: .medium,
                                     tracking: HTracking.caption1, textStyle: .caption)
  public static let caption2 = HType(size: HFontSize.caption2, leading: HLeading.caption2, weight: .medium,
                                     tracking: HTracking.caption2, textStyle: .caption2)
  public static let button = HType(size: HFontSize.button, leading: HLeading.button, weight: .semibold,
                                   tracking: HTracking.button, textStyle: .body)
  /// Small button (36-tall pills, chips): 15/20, 600, no tracking.
  public static let smallButton = HType(size: HFontSize.subheadline, leading: HLeading.subheadline,
                                        weight: .semibold, textStyle: .subheadline)
  /// The old name of `smallButton` (kept until Stage I).
  public static let buttonSmall = smallButton
  /// Text button (header links "See all", "Edit"): 17/24, 500, −0.15, in `--color-text-link`.
  public static let textButton = HType(size: HFontSize.body, leading: HLeading.body, weight: .medium,
                                       tracking: HTracking.body, textStyle: .body)
  /// "DAY 10 OF 31": 13/16, 600, 0.06 em, uppercase in styling only (the source stays
  /// sentence case, so VoiceOver reads words).
  public static let overline = HType(size: HFontSize.footnote, leading: HLeading.overline, weight: .semibold,
                                     trackingEm: HTracking.overlineEm, uppercase: true, textStyle: .footnote)
}

/// A rounded figure style (SF Pro Rounded, spec 04 §14.4).
public struct HFigure: Sendable, Hashable {
  public var size: CGFloat
  public var leading: CGFloat
  public var weight: HWeight
  public var tracking: CGFloat
  public var textStyle: Font.TextStyle
  /// Tabular digits, so amounts line up in lists (spec 04 §14.4). Off for heroes and
  /// widgets, where Paper sets proportional figures.
  public var tabular: Bool
  /// The largest Dynamic Type size this figure grows to. `.display` and `.hero` stop
  /// at `.accessibility3`; larger sizes reflow the layout instead (spec 04 §14.4).
  public var maxDynamicTypeSize: DynamicTypeSize
  /// How far a long figure may shrink to stay on one line (spec 01 §6.10): never cut, never
  /// wrapped. 1 means it never scales; rows and lists reflow instead.
  public var minimumScale: CGFloat

  public init(
    size: CGFloat, leading: CGFloat, weight: HWeight, tracking: CGFloat = 0, textStyle: Font.TextStyle,
    tabular: Bool = false, maxDynamicTypeSize: DynamicTypeSize = .accessibility5, minimumScale: CGFloat = 1
  ) {
    self.size = size
    self.leading = leading
    self.weight = weight
    self.tracking = tracking
    self.textStyle = textStyle
    self.tabular = tabular
    self.maxDynamicTypeSize = maxDynamicTypeSize
    self.minimumScale = minimumScale
  }

  /// The smallest size the figure may scale to (its floor, page 06).
  public var floor: CGFloat { (size * minimumScale).rounded() }

  public func weight(_ w: HWeight) -> HFigure {
    var f = self
    f.weight = w
    return f
  }

  /// Home hero, recap: 56/58 bold, −1.2. Capped at AX3; scales down to 34.
  public static let display = HFigure(size: HFontSize.numericDisplay, leading: HLeading.numericDisplay,
                                      weight: .bold, tracking: HTracking.numericDisplay, textStyle: .largeTitle,
                                      maxDynamicTypeSize: .accessibility3, minimumScale: 0.6)
  /// Detail heroes, the review card, Bills "to pay": 44/46 bold, −0.8. Capped at AX3; floor 26.
  public static let hero = HFigure(size: HFontSize.numericHero, leading: HLeading.numericHero, weight: .bold,
                                   tracking: HTracking.numericHero, textStyle: .largeTitle,
                                   maxDynamicTypeSize: .accessibility3, minimumScale: 0.6)
  /// Home Screen widget figure: 40/44 bold, −0.8 (no token yet). Floor 22.
  public static let widget = HFigure(size: 40, leading: 44, weight: .bold, tracking: HTracking.numericHero,
                                     textStyle: .largeTitle, minimumScale: 0.55)
  /// Sheet heroes, posters, widgets: 34/40 bold, −0.5. Floor 20.
  public static let large = HFigure(size: HFontSize.numericLarge, leading: HLeading.numericLarge, weight: .bold,
                                    tracking: HTracking.numericLarge, textStyle: .title, minimumScale: 0.6)
  /// Keypad digits, the project card figure: 28/32 medium, −0.4.
  public static let medium = HFigure(size: HFontSize.numericMedium, leading: HLeading.numericMedium,
                                     weight: .medium, tracking: HTracking.numericMedium, textStyle: .title2,
                                     minimumScale: 0.75)
  /// Counts and percentages on stat tiles: 22/28 bold. Floor 17.
  public static let small = HFigure(size: HFontSize.numericSmall, leading: HLeading.numericSmall, weight: .bold,
                                    textStyle: .title3, minimumScale: 0.75)
  /// Home and Insights amount tiles (Needs, Wants, Savings): 17/22 bold. Floor 13.
  public static let stat = HFigure(size: HFontSize.numericUnit, leading: HLeading.numericUnit, weight: .bold,
                                   textStyle: .body, minimumScale: 0.75)
  /// The "AED" unit beside a display figure: 20/24 semibold. It scales with its figure and is
  /// capped with it.
  public static let displayUnit = HFigure(size: HFontSize.numericDisplayUnit, leading: HLeading.numericDisplayUnit,
                                          weight: .semibold, textStyle: .title3, maxDynamicTypeSize: .accessibility3)
  /// The "AED" unit beside a hero or large figure: 17/22 semibold.
  public static let unit = HFigure(size: HFontSize.numericUnit, leading: HLeading.numericUnit, weight: .semibold,
                                   textStyle: .body)
  /// Row amounts: 16/22 bold, tabular. Never scales: the row reflows.
  public static let row = HFigure(size: HFontSize.numericRow, leading: HLeading.numericRow, weight: .bold,
                                  textStyle: .callout, tabular: true)
  /// Widget rows and pace-row figures: 15/20 bold, tabular. Never scales.
  public static let compact = HFigure(size: HFontSize.numericCompact, leading: HLeading.numericCompact,
                                      weight: .bold, textStyle: .subheadline, tabular: true)
  /// Counts in pills and badges: 13/16 bold, tabular.
  public static let badge = HFigure(size: HFontSize.numericBadge, leading: HLeading.numericBadge, weight: .bold,
                                    textStyle: .footnote, tabular: true)
}

/// Inter's ascent + descent is 1.21 em, so CSS line height adds (leading − 1.21 × size).
let interLineRatio: CGFloat = 1.21
/// SF Pro Rounded's natural line height is about 1.19 em.
let roundedLineRatio: CGFloat = 1.19

struct HTypeModifier: ViewModifier {
  let type: HType
  @ScaledMetric private var scale: CGFloat
  @Environment(\.legibilityWeight) private var legibilityWeight

  init(type: HType) {
    self.type = type
    _scale = ScaledMetric(wrappedValue: 1, relativeTo: type.textStyle)
  }

  func body(content: Content) -> some View {
    let extra = max(0, (type.leading - type.size * interLineRatio) * scale)
    // Bundled faces ignore Bold Text on their own, so the style steps up a weight itself.
    let weight = legibilityWeight == .bold ? type.weight.bolder : type.weight
    content
      .font(.custom(weight.interFace, size: type.size, relativeTo: type.textStyle))
      // Size, leading and tracking scale together (spec 01 §2.4).
      .tracking(type.resolvedTracking * scale)
      .textCase(type.uppercase ? .uppercase : nil)
      .lineSpacing(extra)
      .padding(.vertical, extra / 2)
  }
}

struct HFigureModifier: ViewModifier {
  let figure: HFigure
  @ScaledMetric private var size: CGFloat

  init(figure: HFigure) {
    self.figure = figure
    _size = ScaledMetric(wrappedValue: figure.size, relativeTo: figure.textStyle)
  }

  func body(content: Content) -> some View {
    let scale = size / figure.size
    let extra = max(0, (figure.leading - figure.size * roundedLineRatio) * scale)
    let font = Font.system(size: size, weight: figure.weight.systemWeight, design: .rounded)
    content
      .font(figure.tabular ? font.monospacedDigit() : font)
      .tracking(figure.tracking * scale)
      .padding(.vertical, extra / 2)
  }
}

public extension View {
  /// Applies an Inter text style (font, tracking, line height, case).
  func hType(_ type: HType) -> some View { modifier(HTypeModifier(type: type)) }

  /// Applies a rounded figure style, scaled with Dynamic Type up to its cap.
  func hFigure(_ figure: HFigure) -> some View {
    // Outside the modifier, so its @ScaledMetric reads the capped size.
    modifier(HFigureModifier(figure: figure))
      .dynamicTypeSize(...figure.maxDynamicTypeSize)
      .modifier(CappedFigureMarker(capped: figure.maxDynamicTypeSize < .accessibility5))
  }

  /// One line, as Paper draws it, at the default text size and smaller; above it the
  /// text wraps instead of truncating, and the layouts around it reflow (spec 04 §17).
  func singleLineAtDefaultTextSize() -> some View { lineLimitAtDefaultTextSize(1) }

  /// At most `lines` lines at the default text size and smaller; unlimited above it.
  func lineLimitAtDefaultTextSize(_ lines: Int) -> some View { modifier(LineLimitAtDefaultTextSize(lines: lines)) }
}

struct LineLimitAtDefaultTextSize: ViewModifier {
  let lines: Int
  @Environment(\.dynamicTypeSize) private var size

  func body(content: Content) -> some View {
    content.lineLimit(size <= .large ? lines : nil)
  }
}

/// The accessibility identifier on text whose growth stops below the largest size on
/// purpose (spec 04 §14.4). The UI tests' accessibility audit accepts "Dynamic Type
/// partially unsupported" only on these.
public let hasalaCappedFigureIdentifier = "hasala.cappedFigure"

struct CappedFigureMarker: ViewModifier {
  let capped: Bool

  func body(content: Content) -> some View {
    if capped {
      content.accessibilityIdentifier(hasalaCappedFigureIdentifier)
    } else {
      content
    }
  }
}
