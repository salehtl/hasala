import HasalaDesign
import HasalaModels
import Observation
import SwiftUI

@MainActor
@Observable
final class CheckSuggestionsModel {
  private let app: AppModel
  private(set) var unticked: Set<TxnID> = []
  @ObservationIgnored private var memo = Memo<Int, SuggestionsSnapshot>()

  init(app: AppModel) {
    self.app = app
  }

  var snapshot: SuggestionsSnapshot {
    memo.value(for: app.store.revision) { SuggestionsEngine.snapshot(app.store.state) }
  }

  var hidden: Bool { app.amountsHidden }

  var chosen: Int { snapshot.rows.filter { !unticked.contains($0.id) }.count }

  func isOn(_ id: TxnID) -> Bool { !unticked.contains(id) }

  func toggle(_ id: TxnID) {
    if unticked.contains(id) { unticked.remove(id) } else { unticked.insert(id) }
  }

  @discardableResult
  func use() -> Bool {
    let uses = SuggestionsEngine.uses(snapshot, unticked: unticked)
    guard !uses.isEmpty, app.perform(.useSuggestions(uses)) else { return false }
    unticked = []
    return true
  }
}

struct CheckSuggestionsSheet: View {
  @Bindable var app: AppModel
  @State private var model: CheckSuggestionsModel
  @State private var using = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: CheckSuggestionsModel(app: app))
  }

  var body: some View {
    let snapshot = model.snapshot
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text(snapshot.isEmpty ? "There are no suggestions to check right now." : snapshot.lead)
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("suggestions.lead")
          ForEach(snapshot.groups) { group in section(group) }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 15)
        .padding(.bottom, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("suggestions.sheet")
      }
      .background(HColor.sheetSurfaceLarge)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if !snapshot.isEmpty { dock }
      }
      .navigationTitle("Check suggestions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetCloseButton(identifier: "suggestions.close") { dismiss() }
        ToolbarItem(placement: .principal) {
          Text("Check suggestions").hType(.headline).foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
        }
      }
      .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
    .onDisappear {
      if using { model.use() }
    }
  }

  private func section(_ group: SuggestionGroup) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        CategoryDisc(hue: group.category.hue, glyph: group.category.glyph, size: .s32)
        Text(group.title)
          .hType(.subheadline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("suggestions.group.\(group.id)")
      HListCard {
        ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
          if i > 0 { HDivider(inset: .icon52) }
          suggestionRow(row)
        }
      }
    }
  }

  private func suggestionRow(_ row: SuggestionRow) -> some View {
    let on = model.isOn(row.id)
    return Button { model.toggle(row.id) } label: {
      Group {
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) {
            CheckCircle(on: on)
            rowText(row)
            amount(row)
          }
          .padding(.vertical, 14)
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          HStack(spacing: 14) {
            CheckCircle(on: on)
            rowText(row).frame(maxWidth: .infinity, alignment: .leading)
            amount(row)
          }
          .padding(.vertical, HSpacing.listRowInsetBlock)
          .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
        }
      }
      .padding(.horizontal, HSpacing.listRowInsetInline)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(row.merchant), \(row.dateLine), \(row.source)")
    .accessibilityValue(spokenAmount(row))
    .accessibilityHint(on ? "Untick if it's wrong" : "Tick to use it")
    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("suggestions.row.\(row.id)")
  }

  private func rowText(_ row: SuggestionRow) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.merchant).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        .fixedSize(horizontal: false, vertical: true)
      Text(row.detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func amount(_ row: SuggestionRow) -> some View {
    MoneyText(row.amount, figure: .row, hidden: model.hidden, hiddenGlyphs: 3,
              color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
      .fixedSize()
  }

  private func spokenAmount(_ row: SuggestionRow) -> String {
    model.hidden
      ? "Amount hidden"
      : (row.isIncome ? "plus " : "") + "\(row.amount.currency) \(MoneyFormat.string(row.amount.minor))"
  }

  private var dock: some View {
    let n = model.chosen
    return Button {
      using = true
      dismiss()
    } label: {
      Text(SuggestionsEngine.useLabel(n)).fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.pill(.primary, fill: true))
    .disabled(n == 0)
    .accessibilityIdentifier("suggestions.use")
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(HColor.sheetSurfaceLarge.opacity(0.96).ignoresSafeArea(edges: .bottom))
  }
}
