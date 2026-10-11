import Foundation
import Testing

@testable import HasalaDesign

/// Text contrast, from the tokens (spec 04 §17: at least 4.5:1, washes included).
///
/// The UI tests' accessibility audit does not judge contrast: it samples rendered
/// pixels and fails ink on the grey canvas (over 14:1) under the scroll-edge blur and
/// the glass bars, so it cannot be a gate. These pairs are every text colour the
/// screens draw on every surface it sits on, computed exactly (WCAG 2.x relative
/// luminance); a translucent colour is composited over what is under it first.
@Suite("Text contrast")
struct ContrastTests {
  struct Pair: CustomTestStringConvertible, Sendable {
    let name: String
    let text: HRGBA
    let background: HRGBA
    var testDescription: String { name }
  }

  /// The surfaces a wash passes through: its first stop, Paper's sky 38% stop, and the
  /// first stops of the other washes (spec 04 §14.2; `AmbientWash`).
  static let washes: [(String, HRGBA)] = [
    ("sky wash", HPalette.washOnTrack),
    ("sky wash 38%", HRGBA(228, 236, 250, 1)),
    ("sand wash", HPalette.washOverPace),
    ("rose wash", HPalette.washOverBudget),
    ("lilac wash", HPalette.hueLilacStart),
    ("mint wash", HPalette.hueMintStart),
    ("peach wash", HPalette.huePeachStart),
    ("canvas", HPalette.surfaceSecondary),
  ]

  static let hueStops: [(String, HRGBA)] = [
    ("sky", HPalette.hueSkyStart), ("sky end", HPalette.hueSkyEnd),
    ("sand", HPalette.hueSandStart), ("sand end", HPalette.hueSandEnd),
    ("rose", HPalette.hueRoseStart), ("rose end", HPalette.hueRoseEnd),
    ("lilac", HPalette.hueLilacStart), ("lilac end", HPalette.hueLilacEnd),
    ("mint", HPalette.hueMintStart), ("mint end", HPalette.hueMintEnd),
    ("peach", HPalette.huePeachStart), ("peach end", HPalette.huePeachEnd),
  ]

  static let pairs: [Pair] = {
    var p: [Pair] = []
    func add(_ name: String, _ text: HRGBA, _ background: HRGBA) {
      p.append(Pair(name: name, text: text, background: background))
    }
    // Content on the canvas, cards and widgets.
    for (bgName, bg) in [("canvas", HPalette.surfaceSecondary), ("card", HPalette.surfacePrimary),
                         ("widget", HPalette.widgetSurface)] {
      add("primary on \(bgName)", HPalette.textPrimary, bg)
      add("secondary on \(bgName)", HPalette.textSecondary, bg)
      add("link on \(bgName)", HPalette.textLink, bg)
      add("row supporting on \(bgName)", HPalette.listRowSupporting, bg)
      add("money in on \(bgName)", HPalette.moneyIn, bg)
      add("over budget on \(bgName)", HPalette.paceOverBudget, bg)
      add("success on \(bgName)", HPalette.statusSuccessForeground, bg)
    }
    // Buttons, chips and badges.
    add("on accent", HPalette.textOnAccent, HPalette.actionAccent)
    add("link on accent subtle", HPalette.textLink, HPalette.actionAccentSubtle)
    add("white on destructive (unread badge)", HPalette.white, HPalette.actionDestructive)
    add("white on ink (count badge)", HPalette.white, HPalette.textPrimary)
    add("selected chip", HPalette.chipTextSelected, HPalette.chipSurfaceSelected)
    add("chip", HPalette.chipText, HPalette.chipSurface)
    // The hero on its wash: overline, caption, verdict, link, and the stat tiles.
    for (washName, wash) in washes {
      add("primary on \(washName)", HPalette.textPrimary, wash)
      add("wash secondary on \(washName)", HPalette.textOnWashSecondary, wash)
      add("wash link on \(washName)", HPalette.textOnWashLink, wash)
      add("on track on \(washName)", HPalette.paceOnTrack, wash)
      add("over pace on \(washName)", HPalette.paceOverPace, wash)
      add("over budget on \(washName)", HPalette.paceOverBudget, wash)
      let tile = HPalette.surfaceOnWash.over(wash)
      add("wash secondary on a stat tile on \(washName)", HPalette.textOnWashSecondary, tile)
      add("primary on a stat tile on \(washName)", HPalette.textPrimary, tile)
    }
    // Posters and hue cards: ink text, and the mint goal card's own ink and caption.
    for (hueName, stop) in hueStops {
      add("primary on \(hueName)", HPalette.textPrimary, stop)
      add("hue secondary on \(hueName)", HPalette.textOnHueSecondary, stop)
    }
    add("mint ink on mint", HPalette.hueMintInk, HPalette.hueMintStart)
    add("mint ink on mint end", HPalette.hueMintInk, HPalette.hueMintEnd)
    // Status pills: white on posters, tinted on cards.
    for (tone, fg, surface) in [("accent", HPalette.actionAccent, HPalette.statusInfoSurface),
                                ("error", HPalette.statusErrorForeground, HPalette.statusErrorSurface),
                                ("warning", HPalette.statusWarningForeground, HPalette.statusWarningSurface),
                                ("success", HPalette.statusSuccessForeground, HPalette.statusSuccessSurface)] {
      add("\(tone) pill on white", fg, HPalette.white)
      add("\(tone) chip on its tint", fg, surface)
    }
    // The inverse (net worth) widget.
    add("on inverse", HPalette.widgetOnInverse, HPalette.widgetSurfaceInverse)
    add("inverse secondary", HPalette.widgetOnInverseSecondary.over(HPalette.widgetSurfaceInverse),
        HPalette.widgetSurfaceInverse)
    add("green on inverse", HPalette.green300, HPalette.widgetSurfaceInverse)
    return p
  }()

  @Test(arguments: pairs)
  func textIsReadable(_ pair: Pair) {
    let ratio = pair.text.over(pair.background).contrast(with: pair.background)
    #expect(ratio >= 4.5, "\(pair.name): \(String(format: "%.2f", ratio)):1")
  }

  @Test func theFormulaMatchesWCAG() {
    #expect(abs(HRGBA(0, 0, 0, 1).contrast(with: HRGBA(255, 255, 255, 1)) - 21) < 0.001)
    #expect(abs(HRGBA(255, 255, 255, 1).contrast(with: HRGBA(255, 255, 255, 1)) - 1) < 0.001)
    // #767676 on white is the classic 4.54:1.
    #expect(abs(HRGBA(118, 118, 118, 1).contrast(with: HRGBA(255, 255, 255, 1)) - 4.54) < 0.01)
  }
}

extension HRGBA {
  /// This colour composited over an opaque one (source-over, in sRGB as Paper draws it).
  func over(_ base: HRGBA) -> HRGBA {
    func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
      UInt8((Double(a) * opacity + Double(b) * (1 - opacity)).rounded())
    }
    return HRGBA(mix(red, base.red), mix(green, base.green), mix(blue, base.blue), 1)
  }

  var relativeLuminance: Double {
    func channel(_ v: UInt8) -> Double {
      let c = Double(v) / 255
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
  }

  func contrast(with other: HRGBA) -> Double {
    let a = relativeLuminance, b = other.relativeLuminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}
