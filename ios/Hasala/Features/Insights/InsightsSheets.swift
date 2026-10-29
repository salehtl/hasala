import HasalaDesign
import HasalaModels
import SwiftUI

struct InsightsDrillSheet: View {
  let model: InsightsModel
  let target: InsightsTarget
  @Environment(\.dismiss) private var dismiss
  @State private var path: [InsightsTarget] = []

  var body: some View {
    NavigationStack(path: $path) {
      page(target)
        .toolbar { SheetCloseButton(identifier: "drill.close") { dismiss() } }
        .navigationDestination(for: InsightsTarget.self) { page($0) }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
  }

  private func page(_ target: InsightsTarget) -> InsightsDrillPage {
    InsightsDrillPage(drill: model.drill(target), hidden: model.hidden) { path.append($0) }
  }
}

struct InsightsDrillPage: View {
  let drill: InsightsDrill
  let hidden: Bool
  let narrow: (InsightsTarget) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if !drill.categories.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            overline("Narrow to a category")
            VStack(spacing: 0) {
              ForEach(Array(drill.categories.enumerated()), id: \.element.id) { i, c in
                if i > 0 { InsightsSeparator(inset: HSpacing.listRowInsetInline) }
                Button { narrow(.category(c.id)) } label: { categoryRow(c) }
                  .buttonStyle(HRowPressStyle())
                  .accessibilityIdentifier("drill.category.\(c.id)")
              }
            }
            .listCard()
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          overline(drill.rowsTitle)
          if drill.rows.isEmpty {
            EmptyNote(systemImage: "tray", message: "No transactions")
          } else {
            VStack(spacing: 0) {
              ForEach(Array(drill.rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { InsightsSeparator() }
                txnRow(r)
              }
            }
            .listCard()
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 15)
      .padding(.bottom, 40)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("drill.sheet")
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle(drill.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text(drill.title).hType(.headline).foregroundStyle(HColor.textPrimary)
          .lineLimit(1).truncationMode(.middle)
          .accessibilityAddTraits(.isHeader)
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("AED").hFigure(.unit).foregroundStyle(HColor.textPrimary)
        MoneyText(drill.total, figure: InsightsInk.figure, hidden: hidden, hiddenGlyphs: 6,
                  color: HColor.textPrimary, sign: drill.total.minor < 0 ? .income : .none)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Total")
      .accessibilityValue(InsightsSpeech.amount(drill.total, hidden: hidden))
      .accessibilityIdentifier("drill.total")
      Text(drill.line.rendered(hidden: hidden)).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(drill.line.spoken(hidden: hidden))
        .accessibilityIdentifier("drill.line")
    }
    .padding(.horizontal, 4)
  }

  private func overline(_ title: String) -> some View {
    Text(title.uppercased()).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
      .padding(.horizontal, 4)
      .accessibilityAddTraits(.isHeader)
  }

  private func categoryRow(_ c: InsightsDrillCategory) -> some View {
    Group {
      if typeSize.isAccessibilitySize {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text(c.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            Text(c.payments).hType(.footnote).foregroundStyle(HColor.textSecondary)
            MoneyText(c.amount, figure: .row, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary)
          }
          Spacer(minLength: 0)
          HIconView(.chevronRight, size: 14, color: HColor.listRowChevron)
        }
      } else {
        HStack(spacing: 12) {
          Text(c.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          Spacer(minLength: 0)
          Text(c.payments).hType(.footnote).foregroundStyle(HColor.textSecondary)
          MoneyText(c.amount, figure: .row, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary)
            .frame(minWidth: 76, alignment: .trailing)
          HIconView(.chevronRight, size: 14, color: HColor.listRowChevron)
        }
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .frame(maxWidth: .infinity, minHeight: HSpacing.listRowMinHeight)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(c.title), \(InsightsSpeech.amount(c.amount, hidden: hidden)), \(c.payments)")
    .accessibilityAddTraits(.isButton)
  }

  private func txnRow(_ r: InsightsDrillRow) -> some View {
    HStack(spacing: HSpacing.listRowGap) {
      CategoryDisc(hue: r.hue, glyph: r.glyph)
      ReflowingRow(alignment: .center) {
        VStack(alignment: .leading, spacing: 2) {
          Text(r.merchant).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          Text(r.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
      } trailing: {
        MoneyText(r.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                  color: r.amount.minor < 0 ? HColor.moneyIn : HColor.moneyOut,
                  sign: r.amount.minor < 0 ? .income : .none)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, minHeight: HSpacing.listRowMinHeightTwoLine, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(r.merchant), \(InsightsSpeech.amount(Money.aed(abs(r.amount.minor)), hidden: hidden))\(r.amount.minor < 0 ? " refunded" : ""), \(r.detail)")
    .accessibilityIdentifier("drill.row.\(r.id)")
  }
}
