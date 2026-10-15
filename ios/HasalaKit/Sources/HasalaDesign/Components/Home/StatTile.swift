import HasalaModels
import SwiftUI

/// A stat tile under the Home hero (Paper "Hero stats", page 16 §01): the label 13/18 in the
/// wash's secondary ink over the figure 17/22 bold, on white 70%, radius 18, inset 12/14.
/// Savings part way through its plan adds "of 5,000" 13/18 on the figure's baseline. Not a
/// control: it reads "Needs, AED 9,040.80" (hidden: "Needs, Amount hidden").
///
/// While the first import runs (S9) the figure is a 64 × 14 skeleton, never a zero.
public struct StatTile: View {
  let tile: HeroTile
  let hidden: Bool
  let skeleton: Bool

  public init(_ tile: HeroTile, hidden: Bool, skeleton: Bool = false) {
    self.tile = tile
    self.hidden = hidden
    self.skeleton = skeleton
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(tile.label).hType(.footnote).foregroundStyle(HColor.textOnWashSecondary)
        .singleLineAtDefaultTextSize()
      if skeleton {
        Capsule().fill(HColor.appleFillsTertiary).frame(width: 64, height: 14).padding(.top, 4)
          .padding(.bottom, 4)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          MoneyText(tile.value, figure: .stat, style: tile.style, hidden: hidden, hiddenGlyphs: 4,
                    color: HColor.textPrimary)
          if let of = tile.of {
            Text("of " + (hidden ? MoneyFormat.hidden(count: 3) : MoneyFormat.string(of.minor, style: .rounded)))
              .hType(.footnote).foregroundStyle(HColor.textOnWashSecondary)
              .singleLineAtDefaultTextSize()
          }
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

  private var spoken: String {
    if skeleton { return "Getting your transactions" }
    if hidden { return "Amount hidden" }
    let value = MoneyFormat.string(tile.value.minor, style: tile.style)
    if let of = tile.of { return "\(value) of \(MoneyFormat.string(of.minor, style: .rounded))" }
    return "\(tile.value.currency) \(value)"
  }
}
