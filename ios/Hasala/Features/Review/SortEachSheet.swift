import HasalaDesign
import HasalaModels
import SwiftUI

struct SortEachSheet: View {
  @Bindable var app: AppModel
  let model: any ReviewDeckModel
  let group: ReviewGroupCardModel

  static let firstPage = 4
  static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

  @State private var expanded = false
  @State private var picking: ReviewPick?
  @State private var picked: [TxnID: CategoryID] = [:]
  @State private var lastPick: CategoryID?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  private var rows: [ReviewCardModel] { model.groupRows(group) }

  private var shown: [ReviewCardModel] {
    let all = rows
    let filed = picked.keys.compactMap { id in app.store.state.txn(id).map { ReviewEngine.card($0, app.store.state) } }
      .sorted { $0.id < $1.id }
    let list = filed + all.filter { picked[$0.id] == nil }
    return expanded ? list : Array(list.prefix(Self.firstPage))
  }

  private var hiddenCount: Int { max(0, rows.count + picked.count - Self.firstPage) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header
          spellings
          list
          actions
        }
        .padding(.top, 8)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 28)
      }
      .scrollBounceBehavior(.basedOnSize)
      .background(HColor.sheetSurface)
      .toolbar(.hidden, for: .navigationBar)
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationBackground(HColor.sheetSurface)
    .presentationCornerRadius(HRadius.sheet)
    .accessibilityIdentifier("review.sortEach.sheet")
    .sheet(item: $picking) { pick in
      ReviewPickSheet(model: model, pick: pick) { category, alwaysUse, project in
        let id = pick.card.id
        picking = nil
        if model.sort(id, into: category, alwaysUse: alwaysUse, project: project) {
          picked[id] = category
          lastPick = category
        }
      }
    }
    .onChange(of: rows.isEmpty) { _, empty in
      if empty, picking == nil { dismiss() }
    }
  }

  private var header: some View {
    HStack {
      GlassIconButton(.close, label: "Close") { dismiss() }
        .accessibilityIdentifier("review.sortEach.close")
      Spacer(minLength: 8)
      Text("\(group.merchant) · \(ReviewEngine.payments(group.total))")
        .hType(.headline.weight(.semibold))
        .foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
    }
    .padding(.top, 12)
  }

  @ViewBuilder private var spellings: some View {
    if !group.spellings.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("Spellings it covers").hType(.overline).foregroundStyle(HColor.textSecondary)
          .accessibilityAddTraits(.isHeader)
        FlowLayout(spacing: 8) {
          ForEach(group.spellings, id: \.self) { s in InfoChip(s, style: .rawText) }
        }
      }
    }
  }

  private var list: some View {
    VStack(spacing: 0) {
      ForEach(Array(shown.enumerated()), id: \.element.id) { i, card in
        if i > 0 { HColor.borderSubtle.frame(height: 1).accessibilityHidden(true) }
        row(card)
      }
      if !expanded, hiddenCount > 0 {
        Button {
          expanded = true
        } label: {
          Text("Show \(hiddenCount) more")
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textLink)
            .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review.sortEach.more")
      }
    }
  }

  private func row(_ card: ReviewCardModel) -> some View {
    let t = app.store.state.txn(card.id)
    let category = picked[card.id].flatMap { app.store.state.category($0) }
    let date = t?.postedAt.date.short ?? ""
    let line = "\(card.rawMerchant ?? card.merchant) · "
    let text = VStack(alignment: .leading, spacing: 2) {
      Text(date).hType(.callout.weight(.semibold)).foregroundStyle(HColor.textPrimary)
      HStack(spacing: 0) {
        Text(line).hType(.footnote).foregroundStyle(HColor.textSecondary)
        MoneyText(card.amount, figure: .compact, unit: .compact, hidden: app.amountsHidden, hiddenGlyphs: 3,
                  color: HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    let trailing = Group {
      if let category {
        HStack(spacing: 6) {
          Circle().fill(category.hue.dotGradient).frame(width: 8, height: 8)
          Text(category.name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(Capsule().fill(HColor.surfaceSecondary))
      } else {
        Text("Pick")
          .hType(.footnote.weight(.semibold))
          .foregroundStyle(HColor.actionAccent)
          .padding(.horizontal, 14)
          .frame(minHeight: 32)
          .background(Capsule().fill(HColor.actionAccentSubtle))
      }
    }
    return Button {
      guard category == nil else { return }
      picking = ReviewPick(card: card, choice: ReviewChoice(filing: card.suggestion?.bucket ?? .needs))
    } label: {
      Group {
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) {
            text
            trailing
          }
        } else {
          HStack(spacing: 12) {
            text
            trailing
          }
        }
      }
      .frame(minHeight: 60)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken(card, date: t?.postedAt.date, category: category?.name))
    .accessibilityHint(category == nil ? "Double-tap to pick" : "")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("review.sortEach.row.\(card.id)")
  }

  private func spoken(_ card: ReviewCardModel, date: LocalDate?, category: String?) -> String {
    let when = date.map { "\(Self.weekdays[$0.weekday]) \($0.day) \(CivilCalendar.monthNames[$0.month - 1])" } ?? ""
    let amount = app.amountsHidden ? "Amount hidden" : "\(card.amount.currency) \(MoneyFormat.string(card.amount.minor))"
    return [when, card.rawMerchant ?? card.merchant, amount, category ?? "Not sorted yet"].filter { !$0.isEmpty }
      .joined(separator: ", ")
  }

  private var actions: some View {
    let rest = rows.count
    let name = lastPick.flatMap { app.store.state.category($0)?.name }
    return VStack(spacing: 10) {
      if let lastPick, let name, rest > 0 {
        Button("Sort the other \(rest) as \(name)") {
          let still = model.group(group.id) ?? group
          if model.sortGroup(still, into: lastPick, alwaysUse: false, project: nil) { dismiss() }
        }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("review.sortEach.rest")
      }
      Button("Done") { dismiss() }
        .buttonStyle(.pill(.secondary, fill: true))
        .accessibilityIdentifier("review.sortEach.done")
    }
  }
}
