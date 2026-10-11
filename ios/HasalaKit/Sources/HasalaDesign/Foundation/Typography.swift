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
  public static let buttonSmall = HType(size: HFontSize.subheadline, leading: HLeading.subheadline,
                                        weight: .semibold, textStyle: .subheadline)
  /// "OCTOBER · DAY 10 OF 31": 13/16, 600, 0.06 em, uppercase.
  public static let overline = HType(size: HFontSize.footnote, leading: HLeading.caption1, weight: .semibold,
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

  public init(
    size: CGFloat, leading: CGFloat, weight: HWeight, tracking: CGFloat = 0, textStyle: Font.TextStyle,
    tabular: Bool = false
  ) {
    self.size = size
    self.leading = leading
    self.weight = weight
    self.tracking = tracking
    self.textStyle = textStyle
    self.tabular = tabular
  }

  public func weight(_ w: HWeight) -> HFigure {
    var f = self
    f.weight = w
    return f
  }

  /// Home hero, recap: 56/58 bold, −1.2.
  public static let display = HFigure(size: HFontSize.numericDisplay, leading: HLeading.numericDisplay,
                                      weight: .bold, tracking: HTracking.numericDisplay, textStyle: .largeTitle)
  /// Kit hero: 44/46 bold, −0.8.
  public static let hero = HFigure(size: HFontSize.numericHero, leading: HLeading.numericHero, weight: .bold,
                                   tracking: HTracking.numericHero, textStyle: .largeTitle)
  /// Sheet heroes, posters, widgets: 34/40 bold, −0.5.
  public static let large = HFigure(size: HFontSize.numericLarge, leading: HLeading.numericLarge, weight: .bold,
                                    tracking: HTracking.numericLarge, textStyle: .title)
  /// Keypad digits: 28/32 medium.
  public static let medium = HFigure(size: HFontSize.numericMedium, leading: HLeading.numericMedium,
                                     weight: .medium, textStyle: .title2)
  /// Stat values: 22/28.
  public static let small = HFigure(size: HFontSize.numericSmall, leading: HLeading.numericSmall, weight: .bold,
                                    textStyle: .title3)
  /// The "AED" unit beside a display figure: 20/24 semibold.
  public static let displayUnit = HFigure(size: 20, leading: 24, weight: .semibold, textStyle: .title3)
  /// The "AED" unit beside a large figure, and stat values: 17/22.
  public static let unit = HFigure(size: HFontSize.numericUnit, leading: HLeading.numericUnit, weight: .semibold,
                                   textStyle: .body)
  /// Row amounts: 16/22 bold.
  public static let row = HFigure(size: HFontSize.callout, leading: HLeading.callout, weight: .bold,
                                  textStyle: .callout, tabular: true)
  /// Widget rows and units: 15/20.
  public static let compact = HFigure(size: HFontSize.subheadline, leading: HLeading.subheadline, weight: .bold,
                                      textStyle: .subheadline, tabular: true)
  /// Badges: 13/16 bold.
  public static let badge = HFigure(size: HFontSize.footnote, leading: HLeading.caption1, weight: .bold,
                                    textStyle: .footnote)
}

/// Inter's ascent + descent is 1.21 em, so CSS line height adds (leading − 1.21 × size).
let interLineRatio: CGFloat = 1.21
/// SF Pro Rounded's natural line height is about 1.19 em.
let roundedLineRatio: CGFloat = 1.19

struct HTypeModifier: ViewModifier {
  let type: HType
  @ScaledMetric private var scale: CGFloat

  init(type: HType) {
    self.type = type
    _scale = ScaledMetric(wrappedValue: 1, relativeTo: type.textStyle)
  }

  func body(content: Content) -> some View {
    let extra = max(0, (type.leading - type.size * interLineRatio) * scale)
    content
      .font(type.font)
      .tracking(type.resolvedTracking)
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
      .tracking(figure.tracking)
      .padding(.vertical, extra / 2)
  }
}

public extension View {
  /// Applies an Inter text style (font, tracking, line height, case).
  func hType(_ type: HType) -> some View { modifier(HTypeModifier(type: type)) }

  /// Applies a rounded figure style.
  func hFigure(_ figure: HFigure) -> some View { modifier(HFigureModifier(figure: figure)) }
}
