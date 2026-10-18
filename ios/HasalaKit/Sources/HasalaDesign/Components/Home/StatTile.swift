import HasalaModels
import SwiftUI

/// A stat tile under the Home hero (Paper "Hero stats", page 16 §01): the label 13/18 in the
/// wash's secondary ink over the figure 17/22 bold, on white 70%, radius 18, inset 12/14.
/// The figure stays on one line and shrinks to fit the tile rather than cut. Not a control: it
/// reads "Needs, AED 9,040.80" (hidden: "Needs, Amount hidden").
public struct StatTile: View {
  let tile: HeroTile
  let hidden: Bool

  public init(_ tile: HeroTile, hidden: Bool) {
    self.tile = tile
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(tile.label).hType(.footnote).foregroundStyle(HColor.textOnWashSecondary)
        .singleLineAtDefaultTextSize()
      MoneyText(tile.value, figure: Self.figure, style: tile.style, hidden: hidden, hiddenGlyphs: 4,
                color: HColor.textPrimary)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: HRadius.statTile, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tile.label)
    .accessibilityValue(spoken)
  }

  static let figure: HFigure = {
    var f = HFigure.stat
    f.minimumScale = 0.76
    f.maxDynamicTypeSize = .xxLarge
    return f
  }()

  /// "AED 9,040.80"; hidden, one "Amount hidden" for the tile.
  private var spoken: String {
    if hidden { return "Amount hidden" }
    let value = MoneyPhrase([.amount(tile.value, tile.style)]).spoken(hidden: false)
    return "\(tile.value.currency) \(value)" + (tile.label == "Savings" ? " saved" : "")
  }
}
