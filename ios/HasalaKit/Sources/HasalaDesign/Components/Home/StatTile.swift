import HasalaModels
import SwiftUI

/// A stat tile under the Home hero (Paper "Hero stats", page 16 §01): the label 13/18 in the
/// wash's secondary ink over the figure 17/22 bold, on white 70%, radius 18, inset 12/14.
/// Savings part way through its plan adds "of 5,000" 13/18 on the figure's baseline. Not a
/// control: it reads "Needs, AED 9,040.80" (hidden: "Needs, Amount hidden").
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
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        MoneyText(tile.value, figure: .stat, style: tile.style, hidden: hidden, hiddenGlyphs: 4,
                  color: HColor.textPrimary)
        if let of = ofPhrase {
          Text(of.rendered(hidden: hidden))
            .hType(.footnote).foregroundStyle(HColor.textOnWashSecondary)
            .singleLineAtDefaultTextSize()
        }
      }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: HRadius.statTile, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tile.label)
    .accessibilityValue(spoken)
  }

  /// "of 5,000" in whole dirhams, 3 dots when hidden.
  private var ofPhrase: MoneyPhrase? {
    tile.of.map { MoneyPhrase([.text("of "), .amount($0, .rounded, hidden: 3)]) }
  }

  /// "AED 9,040.80", or "2,000.00 of 5,000"; hidden, one "Amount hidden" for the tile.
  private var spoken: String {
    if hidden { return "Amount hidden" }
    let value = MoneyPhrase([.amount(tile.value, tile.style)]).spoken(hidden: false)
    if let of = ofPhrase { return "\(value) \(of.spoken(hidden: false))" }
    return "\(tile.value.currency) \(value)"
  }
}
