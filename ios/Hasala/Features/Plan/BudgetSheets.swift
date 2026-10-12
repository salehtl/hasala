import HasalaDesign
import HasalaModels
import SwiftUI

/// Change a category's budget (Paper "Change a budget"): budget, spent and left; a stepper around
/// the new budget; quick chips; what happens to Ready to assign.
struct BudgetEditSheet: View {
  let model: any BudgetSheetModel
  @State private var draft = ""
  @Environment(\.dismiss) private var dismiss

  private var amount: Int64? { MoneyFormat.parseMinor(draft) }

  var body: some View {
    NavigationStack {
      if let row = model.row {
        ScrollView {
          VStack(spacing: 18) {
            HStack(spacing: 0) {
              amountCell("Budget", row.budget)
              Divider().frame(height: 36)
              amountCell("Spent", row.spent)
              Divider().frame(height: 36)
              amountCell(row.budget.minor - row.spent.minor < 0 ? "Over" : "Left", .aed(abs(row.budget.minor - row.spent.minor)))
            }
            .padding(.vertical, 12)
            .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))

            VStack(spacing: 10) {
              Text("New budget").hType(.overline).foregroundStyle(HColor.textSecondary)
              HStack(spacing: 16) {
                stepButton("minus", label: "Less") { step(-100_00) }
                // Inputs show real values while editing (spec 04 §12).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text("AED").hFigure(.displayUnit).foregroundStyle(HColor.textPrimary)
                  TextField("0", text: $draft)
                    .keyboardType(.decimalPad)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .accessibilityIdentifier("budget.amount")
                }
                .frame(maxWidth: .infinity)
                stepButton("plus", label: "More") { step(100_00) }
              }
            }

            FlowLayout(spacing: 8) {
              FilterChip("+ 200", selected: false) { step(200_00) }
              if let projected = model.projected {
                FilterChip("Cover the pace \(MoneyFormat.string(projected.minor, style: .compact))",
                           selected: false) { draft = MoneyFormat.draft(projected.minor) }
              }
              // TODO(03a §6.12): "Match September" needs last month's spending from the Plan engine.
            }

            if let amount {
              let rta = model.plan.readyToAssign.minor - (amount - row.budget.minor)
              // A shortfall leads with "−" (U+2212), as MoneyText draws debts; hidden, the
              // figure and its sign both go (spec 04 §12: only inputs show real values).
              let sign = rta < 0 && !model.hidden ? "\u{2212}" : ""
              PhraseText(MoneyPhrase([.text("Ready to assign becomes \(sign)AED "), .amount(.aed(abs(rta)))]),
                         hidden: model.hidden)
                .hType(.subheadline)
                .foregroundStyle(rta < 0 ? HColor.statusErrorForeground : HColor.textSecondary)
                .accessibilityIdentifier("budget.consequence")
            }
          }
          .padding(HSpacing.insetPage)
        }
        .background(HColor.surfaceSecondary)
        .safeAreaInset(edge: .bottom) {
          Button(amount.map { "Set \(row.name) to AED \(MoneyFormat.string($0, style: .compact))" } ?? "Enter a budget") {
            if let amount { _ = model.setBudget(.aed(amount)) }
          }
          .buttonStyle(.pill(.primary, fill: true))
          .disabled(amount == nil || amount == row.budget.minor)
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.bottom, 8)
          .accessibilityIdentifier("budget.save")
        }
        .navigationTitle("\(row.name) budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SheetCloseButton(identifier: "budget.close") { dismiss() } }
        .onAppear { if draft.isEmpty { draft = MoneyFormat.string(row.budget.minor, style: .compact).filter { $0 != "," } } }
      }
    }
  }

  private func amountCell(_ label: String, _ money: Money) -> some View {
    VStack(spacing: 2) {
      Text(label).hType(.footnote).foregroundStyle(HColor.textSecondary)
      MoneyText(money, figure: .compact, style: .compact, hidden: model.hidden, color: HColor.textPrimary)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func stepButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon).font(.system(size: 20, weight: .semibold))
        .frame(width: 48, height: 48)
        .background(HColor.actionAccentSubtle, in: Circle())
        .foregroundStyle(HColor.textLink)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func step(_ by: Int64) {
    let now = amount ?? 0
    draft = MoneyFormat.string(max(0, now + by), style: .compact).filter { $0 != "," }
  }
}

/// Move money (Paper board), and Assign from Plan when no category is chosen yet:
/// how much, where it comes from, and the preview of both budgets.
struct MoveMoneySheet: View {
  let model: any BudgetSheetModel
  @State private var destination: CategoryID?
  @State private var source: CategoryID??
  @State private var draft = ""
  @State private var showAllSources = false
  @Environment(\.dismiss) private var dismiss

  private var amount: Int64? { MoneyFormat.parseMinor(draft) }
  /// Never the destination: choosing Shopping as "To" takes it off "Take from".
  private var sources: [MoveSource] { model.sources(to: destination) }
  private var chosenSource: MoveSource? {
    let all = sources
    return all.first { $0.id == (source ?? nil) } ?? all.first
  }
  private var toName: String? { model.destinations.first { $0.id == destination }?.name }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("To").hType(.overline).foregroundStyle(HColor.textSecondary)
          VStack(alignment: .leading, spacing: 6) {
            Picker("Category", selection: $destination) {
              Text("Choose a category").tag(CategoryID?.none)
              ForEach(model.destinations) { Text($0.name).tag(CategoryID?.some($0.id)) }
            }
            .labelsHidden()
            .tint(HColor.textPrimary)
            .accessibilityIdentifier("move.to")
            if let row = model.row, let projected = model.projected, projected.minor > row.budget.minor {
              DetailLine(parts: [.status("On course for", .warning),
                                 .text(MoneyPhrase([.amount(projected, .compact), .text(" of "),
                                                    .amount(row.budget, .compact)]))],
                         hidden: model.hidden)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .listCard()

          VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text("AED").hFigure(.displayUnit).foregroundStyle(HColor.textPrimary)
              // Inputs show real values while editing (spec 04 §12).
              TextField("0.00", text: $draft)
                .keyboardType(.decimalPad)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize()
                .accessibilityIdentifier("move.amount")
            }
            if model.shortfall != nil {
              Text("Covers the projected gap").hType(.subheadline).foregroundStyle(HColor.textSecondary)
            }
          }
          .frame(maxWidth: .infinity)

          Text("Take from").hType(.overline).foregroundStyle(HColor.textSecondary)
          let sources = self.sources
          let chosen = chosenSource
          ListCard {
            ForEach(showAllSources ? sources : Array(sources.prefix(4))) { s in
              Button { source = .some(s.id) } label: {
                HStack(spacing: 12) {
                  Image(systemName: chosen?.id == s.id ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(chosen?.id == s.id ? HColor.actionAccent : HColor.iconTertiary)
                    .accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 0) {
                    Text(s.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
                    PhraseText(s.detail, hidden: model.hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
                  }
                  Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(chosen?.id == s.id ? .isSelected : [])
              .accessibilityIdentifier("move.from.\(s.id ?? "rta")")
            }
          }
          if sources.count > 4, !showAllSources {
            Button("Show all") { showAllSources = true }
              .buttonStyle(.pill(.secondary, size: .small))
              .accessibilityIdentifier("move.showAll")
          }
          if sources.isEmpty {
            EmptyNote(systemImage: "tray", message: "Nothing has money to spare this month.")
          }

          if let amount, let to = destination, let from = chosen {
            preview(amount: amount, to: to, from: from)
          }
        }
        .padding(HSpacing.insetPage)
      }
      .background(HColor.surfaceSecondary)
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 6) {
          Button(amount.map { "Move AED \(MoneyFormat.string($0))" } ?? "Enter an amount") {
            if let amount, let to = destination { _ = model.move(.aed(amount), from: chosenSource?.id, to: to) }
          }
          .buttonStyle(.pill(.primary, fill: true))
          .disabled(amount == nil || amount == 0 || destination == nil || chosenSource == nil)
          .accessibilityIdentifier("move.save")
          Text("You can undo this from the toast.").hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 8)
      }
      .navigationTitle(model.row == nil ? "Assign" : "Move money")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { SheetCloseButton(identifier: "move.close") { dismiss() } }
      .onAppear {
        if destination == nil { destination = model.row?.id }
        if draft.isEmpty {
          let start = model.shortfall?.minor ?? (model.row == nil ? max(0, model.plan.readyToAssign.minor) : 100_00)
          draft = MoneyFormat.draft(start)
        }
      }
    }
  }

  private func preview(amount: Int64, to: CategoryID, from: MoveSource) -> some View {
    let toRow = model.plan.row(to)
    return VStack(alignment: .leading, spacing: 8) {
      if let toRow {
        previewLine(toRow.name, toRow.budget.minor, toRow.budget.minor + amount)
      }
      if let id = from.id, let fromRow = model.plan.row(id) {
        previewLine(fromRow.name, fromRow.budget.minor, fromRow.budget.minor - amount)
      } else {
        previewLine("Ready to assign", model.plan.readyToAssign.minor, model.plan.readyToAssign.minor - amount)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .listCard()
    .accessibilityIdentifier("move.preview")
  }

  private func previewLine(_ name: String, _ before: Int64, _ after: Int64) -> some View {
    HStack {
      Text(name).hType(.callout).foregroundStyle(HColor.textPrimary)
      Spacer()
      PhraseText(MoneyPhrase([.amount(.aed(before), .compact), .text(" → ")]), hidden: model.hidden)
        .hType(.callout).foregroundStyle(HColor.textSecondary)
      MoneyText(.aed(after), figure: .compact, style: .compact, hidden: model.hidden,
                color: after < 0 ? HColor.statusErrorForeground : HColor.textPrimary, sign: after < 0 ? .debt : .none)
    }
    .accessibilityElement(children: .combine)
  }
}
