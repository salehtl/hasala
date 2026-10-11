import Foundation
import HasalaModels
import SwiftUI
import Testing

@testable import HasalaDesign

/// The generated tokens match the values the design was drawn with (spec 04 §14.2,
/// AT-UI-7). If Paper changes a token on purpose, these expectations change with it.
@Suite("Design tokens")
struct TokenTests {
  @Test func tokenSetIdentity() {
    #expect(HTokens.paperHash == "360d497c")
    #expect(HTokens.count == 447)
  }

  @Test(arguments: [
    (HPalette.surfaceCanvas, "#F7F7F8"),
    (HPalette.surfaceSecondary, "#EFEFF1"),
    (HPalette.surfacePrimary, "#FFFFFF"),
    (HPalette.textPrimary, "#202023"),
    (HPalette.textSecondary, "#626267"),
    (HPalette.textLink, "#365BEB"),
    (HPalette.actionAccent, "#365BEB"),
    (HPalette.actionAccentPressed, "#294ACD"),
    (HPalette.actionAccentSubtle, "#EEF1FF"),
    (HPalette.actionDestructive, "#AD3029"),
    (HPalette.statusSuccessForeground, "#176442"),
    (HPalette.statusSuccessSurface, "#EAF7F0"),
    (HPalette.statusWarningForeground, "#7B5100"),
    (HPalette.statusWarningSurface, "#FFF4DD"),
    (HPalette.paceFill, "#365BEB"),
    (HPalette.paceFillOverPace, "#C77700"),
    (HPalette.paceFillOverBudget, "#AD3029"),
    (HPalette.paceOnTrack, "#176442"),
    (HPalette.moneyIn, "#176442"),
    (HPalette.moneyOut, "#202023"),
    (HPalette.widgetSurfaceInverse, "#15171C"),
    (HPalette.washOnTrack, "#D3E6FF"),
    (HPalette.textOnWashSecondary, "#47474D"),
    (HPalette.textOnWashLink, "#294ACD"),
  ])
  func semanticColours(token: HRGBA, hex: String) {
    #expect(token.description == hex)
  }

  @Test func translucentColoursKeepTheirOpacity() {
    #expect(HPalette.paceTrack == HRGBA(118, 118, 128, 0.12))
    #expect(HPalette.surfaceOnWash == HRGBA(255, 255, 255, 0.7))
    #expect(HPalette.progressTrackOnHue == HRGBA(0, 0, 0, 0.12))
    #expect(HPalette.scrim == HRGBA(0, 0, 0, 0.28))
    #expect(HPalette.overlayWhite == HRGBA(255, 255, 255, 0.922))
    #expect(HPalette.materialGlassFrost == HRGBA(255, 255, 255, 0.58))
  }

  @Test(arguments: [
    (Hue.sky, "#E4EEFF", "#CFDDFB", "#1E2A5E"),
    (Hue.sand, "#FFF0DC", "#FBDDB8", "#5A3A12"),
    (Hue.rose, "#FBE6E4", "#F4CBC6", "#5E1F28"),
    (Hue.lilac, "#EFE7FA", "#DCCFF3", "#3C2A66"),
    (Hue.mint, "#E1F5EA", "#C2E7D6", "#164A35"),
    (Hue.peach, "#FFE9D9", "#FFCEB5", "#6A2E0E"),
    (Hue.other, "#F1F1F3", "#E2E2E6", "#3A3A40"),
  ])
  func hues(hue: Hue, start: String, end: String, ink: String) {
    #expect(hue.tokens.start.description == start)
    #expect(hue.tokens.end.description == end)
    #expect(hue.tokens.ink.description == ink)
  }

  /// Bucket colours alias hues: needs→sand, wants→lilac, savings→mint, income→sky,
  /// project→peach; rose is never a bucket.
  @Test func bucketsAliasTheirHues() {
    for bucket in Bucket.allCases {
      #expect(bucket.tokens == bucket.hue.tokens, "\(bucket)")
      #expect(bucket.hue != .rose)
    }
    #expect(Bucket.needs.hue == .sand)
    #expect(Bucket.wants.hue == .lilac)
    #expect(Bucket.savings.hue == .mint)
    #expect(Bucket.income.hue == .sky)
    #expect(Bucket.project.hue == .peach)
  }

  @Test func verdictColours() {
    #expect(Verdict.onTrack.fill == HColor.paceFill)
    #expect(Verdict.overPace.fill == HColor.paceFillOverPace)
    #expect(Verdict.overBudget.fill == HColor.paceFillOverBudget)
    #expect(Verdict.overBudget.foreground == HColor.paceOverBudget)
  }

  @Test func spacingRadiiAndSizes() {
    #expect(HSpacing.xxs == 4)
    #expect(HSpacing.xs == 8)
    #expect(HSpacing.md == 16)
    #expect(HSpacing.insetPage == 20)
    #expect(HSpacing.gapScreenSection == 32)
    #expect(HSpacing.glassButton == 48)
    #expect(HSpacing.tabBarHeight == 64)
    #expect(HSpacing.targetMinimum == 44)
    #expect(HSpacing.buttonHeightLarge == 54)
    #expect(HSpacing.buttonHeightMedium == 44)
    #expect(HSpacing.buttonHeightSmall == 36)
    #expect(HSpacing.paceBarHeight == 8)
    #expect(HSpacing.paceMarkerHeight == 16)
    #expect(HRadius.listGroup == 24)
    #expect(HRadius.widget == 26)
    #expect(HRadius.field == 14)
    #expect(HRadius.sheet == 40)
    #expect(HContainer.briefCard == 272)
    #expect(HContainer.widgetUnit == 175)
    #expect(HContainer.widgetWide == 362)
  }

  @Test func typeScale() {
    #expect((HType.largeTitle.size, HType.largeTitle.leading, HType.largeTitle.tracking) == (34, 40, -0.8))
    #expect((HType.section.size, HType.section.leading, HType.section.weight) == (22, 28, .bold))
    #expect((HType.body.size, HType.body.leading, HType.body.weight) == (17, 24, .regular))
    #expect((HType.footnote.size, HType.footnote.leading) == (13, 18))
    #expect(HType.overline.uppercase)
    #expect(abs(HType.overline.resolvedTracking - 0.78) < 0.0001)
    #expect((HFigure.display.size, HFigure.display.leading, HFigure.display.tracking) == (56, 58, -1.2))
    #expect((HFigure.large.size, HFigure.large.tracking) == (34, -0.5))
    #expect(HWeight.semibold.cssWeight == 600)
  }

  @Test func fontFamilies() {
    #expect(HFontFamily.sans == "Inter")
    #expect(HFontFamily.numeric == "SF Pro Rounded")
  }

  @Test func interFacesRegister() {
    #expect(HasalaFonts.register())
    #expect(HasalaFonts.allFacesAvailable)
  }
}
