import HasalaDesign
import HasalaModels
import SwiftUI

/// A bill or income row: disc, name over detail, the amount with its note under it.
struct BillRow: View {
  let row: BillRowModel
  let hidden: Bool

  var body: some View {
    HStack(spacing: HSpacing.listRowGap) {
      HueDisc(hue: row.hue, glyph: row.glyph)
      VStack(alignment: .leading, spacing: 0) {
        Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        DetailLine(parts: row.detail, hidden: hidden)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 0) {
        HStack(spacing: 0) {
          if row.approximate && !hidden {
            Text(verbatim: "~").hFigure(.row).foregroundStyle(HColor.moneyOut).accessibilityLabel("about")
          }
          MoneyText(row.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                    color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
        }
        if let note = row.trailingNote { DetailLine(parts: [note], hidden: hidden) }
      }
      .fixedSize()
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("bill.\(row.id)")
  }
}
