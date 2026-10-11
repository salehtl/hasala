import HasalaModels
import SwiftUI

/// One token colour: 8-bit sRGB channels plus opacity, exactly as Paper exports it.
public struct HRGBA: Sendable, Hashable, CustomStringConvertible {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8
  public let opacity: Double

  public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ opacity: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
  public var description: String {
    let rgb = String(format: "#%02X%02X%02X", red, green, blue)
    return opacity >= 1 ? rgb : rgb + String(format: "%02X", Int((opacity * 255).rounded()))
  }
}

public extension Color {
  init(_ token: HRGBA) {
    self.init(
      .sRGB,
      red: Double(token.red) / 255,
      green: Double(token.green) / 255,
      blue: Double(token.blue) / 255,
      opacity: token.opacity
    )
  }
}

/// Start, end and ink of a hue (Paper `--color-hue-*`, `--color-bucket-other-*`).
public struct HueColors: Sendable, Hashable {
  public let start: HRGBA
  public let end: HRGBA
  public let ink: HRGBA
}

public extension Hue {
  var tokens: HueColors {
    switch self {
    case .sky: HueColors(start: HPalette.hueSkyStart, end: HPalette.hueSkyEnd, ink: HPalette.hueSkyInk)
    case .sand: HueColors(start: HPalette.hueSandStart, end: HPalette.hueSandEnd, ink: HPalette.hueSandInk)
    case .rose: HueColors(start: HPalette.hueRoseStart, end: HPalette.hueRoseEnd, ink: HPalette.hueRoseInk)
    case .lilac: HueColors(start: HPalette.hueLilacStart, end: HPalette.hueLilacEnd, ink: HPalette.hueLilacInk)
    case .mint: HueColors(start: HPalette.hueMintStart, end: HPalette.hueMintEnd, ink: HPalette.hueMintInk)
    case .peach: HueColors(start: HPalette.huePeachStart, end: HPalette.huePeachEnd, ink: HPalette.huePeachInk)
    case .other:
      HueColors(start: HPalette.bucketOtherStart, end: HPalette.bucketOtherEnd, ink: HPalette.bucketOtherInk)
    }
  }

  var start: Color { Color(tokens.start) }
  var end: Color { Color(tokens.end) }
  var ink: Color { Color(tokens.ink) }

  /// The 160° poster/disc gradient Paper draws for this hue.
  var gradient: LinearGradient {
    LinearGradient(colors: [start, end], startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1))
  }
}

public extension Bucket {
  /// The bucket's colour tokens (Paper `--color-bucket-*`; each aliases a hue).
  var tokens: HueColors {
    switch self {
    case .needs: HueColors(start: HPalette.bucketNeedsStart, end: HPalette.bucketNeedsEnd, ink: HPalette.bucketNeedsInk)
    case .wants: HueColors(start: HPalette.bucketWantsStart, end: HPalette.bucketWantsEnd, ink: HPalette.bucketWantsInk)
    case .savings:
      HueColors(start: HPalette.bucketSavingsStart, end: HPalette.bucketSavingsEnd, ink: HPalette.bucketSavingsInk)
    case .income:
      HueColors(start: HPalette.bucketIncomeStart, end: HPalette.bucketIncomeEnd, ink: HPalette.bucketIncomeInk)
    case .project:
      HueColors(start: HPalette.bucketProjectStart, end: HPalette.bucketProjectEnd, ink: HPalette.bucketProjectInk)
    case .other: HueColors(start: HPalette.bucketOtherStart, end: HPalette.bucketOtherEnd, ink: HPalette.bucketOtherInk)
    }
  }

  var title: String {
    switch self {
    case .needs: "Needs"
    case .wants: "Wants"
    case .savings: "Savings"
    case .income: "Income"
    case .project: "Projects"
    case .other: "Other"
    }
  }
}

public extension Verdict {
  /// Bar fill (Paper `--color-pace-fill*`).
  var fill: Color {
    switch self {
    case .onTrack: HColor.paceFill
    case .overPace: HColor.paceFillOverPace
    case .overBudget: HColor.paceFillOverBudget
    case .done: HColor.statusSuccessForeground
    }
  }

  /// Sentence colour (Paper `--color-pace-on-track` …).
  var foreground: Color {
    switch self {
    case .onTrack, .done: HColor.paceOnTrack
    case .overPace: HColor.paceOverPace
    case .overBudget: HColor.paceOverBudget
    }
  }
}

public extension StatusTone {
  var foreground: Color {
    switch self {
    case .accent: HColor.actionAccent
    case .error: HColor.statusErrorForeground
    case .warning: HColor.statusWarningForeground
    case .success: HColor.statusSuccessForeground
    }
  }

  var surface: Color {
    switch self {
    case .accent: HColor.statusInfoSurface
    case .error: HColor.statusErrorSurface
    case .warning: HColor.statusWarningSurface
    case .success: HColor.statusSuccessSurface
    }
  }
}
