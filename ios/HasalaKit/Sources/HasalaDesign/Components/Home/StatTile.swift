import HasalaModels
import SwiftUI

/// A translucent stat tile on the hero wash: label over a rounded figure. Moved here unchanged
/// from Cards.swift in F1; P5 owns it from Stage P.
public struct StatTile: View {
  let stat: HeroStat
  let hidden: Bool

  public init(_ stat: HeroStat, hidden: Bool) {
    self.stat = stat
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(stat.label).hType(.footnote).foregroundStyle(HColor.textOnWashSecondary)
        .singleLineAtDefaultTextSize()
      MoneyText(stat.value, figure: HFigure.unit.weight(.bold), hidden: hidden, color: HColor.textPrimary)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
