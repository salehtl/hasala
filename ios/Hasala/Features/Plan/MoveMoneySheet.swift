import HasalaDesign
import HasalaModels
import SwiftUI

/// Move money (Paper "Plan · Move money (sheet)", 54Y-0), and Assign from Plan when no
/// category is chosen yet: a grey large sheet with several steps on it. To, how much ("Covers
/// the projected gap"), where it comes from, the budgets before and after, "Move AED 318.00"
/// and "You can undo this from the toast." The money moves at once and the toast offers Undo.
///
/// The sources keep 03a §6.13's order and rules (`BudgetSheetViewModel.sources`): the first
/// four, then "Show all". An amount a source doesn't have is refused on the sheet, before
/// anything is sent.
struct MoveMoneySheet: View {
  let model: any BudgetSheetModel
  @State private var destination: CategoryID?
  @State private var source: CategoryID??
  @State private var draft = ""
  @State private var showAllSources = false
  @State private var choosingDestination = false
  @FocusState private var typing: Bool
  @Environment(\.dismiss) private var dismiss

  init(model: any BudgetSheetModel) {
    self.model = model
    // To and the amount are there from the first frame: the shortfall when the pace runs
    // past the budget, all of Ready to assign for Assign, else 100.00.
    _destination = State(initialValue: model.row?.id)
    let start = model.shortfall?.minor ?? (model.row == nil ? max(0, model.plan.readyToAssign.minor) : 100_00)
    _draft = State(initialValue: PlanAmountField.text(for: start, style: .exact))
  }

  private var amount: Int64? { MoneyFormat.parseMinor(draft) }
  /// Never the destination: choosing Shopping as "To" takes it off "Take from".
  private var sources: [MoveSource] { model.sources(to: destination) }
  private var chosenSource: MoveSource? {
    let all = sources
    return all.first { $0.id == (source ?? nil) } ?? all.first
  }
  /// Assign (from Plan, no category yet) lets the person choose where the money goes.
  private var assigning: Bool { model.row == nil }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: HSpacing.sheetGap) {
          PlanSheetHeader(title: assigning ? "Assign" : "Move money", closeID: "move.close") { dismiss() }
          VStack(spacing: 16) {
            toBlock
            amountBlock
            fromBlock
            if let amount, amount > 0, let to = destination, let from = chosenSource {
              preview(amount: amount, to: to, from: from)
            }
            commit
          }
        }
        // The grabber sits 8 from the top; the header 18 under it (page 14 §06).
        .padding(.top, 31)
        .padding(.horizontal, HSpacing.sheetPadding)
        .padding(.bottom, 40)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(HColor.sheetSurfaceLarge)
      .toolbar(.hidden, for: .navigationBar)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { typing = false }
        }
      }
      .navigationDestination(isPresented: $choosingDestination) {
        DestinationPickerPage(destinations: model.destinations, selected: destination) { id in
          destination = id
          choosingDestination = false
        }
      }
    }
    .planLargeSheet()
  }

  // MARK: To

  /// "TO" over the white card: the category's disc and name, and how it is going ("● On
  /// course for 2,518 of 2,200"). Assigning, the card chooses the category.
  private var toBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      PlanOverline("To")
      if assigning {
        Button { choosingDestination = true } label: { toCard(chevron: true) }
          .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous),
                                   scales: false))
          .accessibilityIdentifier("move.to")
      } else {
        toCard(chevron: false).accessibilityIdentifier("move.to")
      }
    }
  }

  private func toCard(chevron: Bool) -> some View {
    let option = model.destinations.first { $0.id == destination }
    let row = destination.flatMap { model.plan.row($0) }
    return HStack(spacing: HSpacing.listRowGap) {
      if let option {
        CategoryDisc(hue: option.hue, glyph: option.glyph)
      } else {
        Circle().fill(HColor.surfaceSecondary).frame(width: 40, height: 40)
          .overlay { HIconView(.tag, size: 20, color: HColor.iconSecondary) }
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(option?.name ?? "Choose a category").hType(.rowTitle)
          .foregroundStyle(option == nil ? HColor.textLink : HColor.listRowTitle)
        if let row { PlanFactsLine(parts: toFacts(row), hidden: model.hidden) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if chevron { HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron) }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    .listCard()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(toSpoken(option: option, row: row))
  }

  /// "To, Groceries, On course for AED 2,518 of 2,200", with "Amount hidden" for hidden figures.
  private func toSpoken(option: CategoryOption?, row: PlanRowModel?) -> String {
    guard let option else { return "To, choose a category" }
    guard let row else { return "To, \(option.name)" }
    let facts = toFacts(row, spoken: true).map { part in
      switch part {
      case .text(let p): p.spoken(hidden: model.hidden)
      case .status(let words, _): words
      }
    }.joined(separator: ", ")
    return "To, \(option.name), \(facts)"
  }

  /// One fact about the destination: where its pace ends when that is past the budget,
  /// over budget, or spent of plan.
  private func toFacts(_ row: PlanRowModel, spoken: Bool = false) -> [PlanDetailPart] {
    let budget = row.budget
    if row.verdict == .overBudget {
      return [.status("Over budget", .error),
              .text(MoneyPhrase([.amount(row.spent, hidden: 3), .text(" of "), .amount(budget, .compact, hidden: 3)]))]
    }
    if row.id == model.row?.id, let projected = model.projected, projected.minor > budget.minor {
      let words = MoneyPhrase([.text("On course for "), .amount(projected, .compact, hidden: 3), .text(" of "),
                               .amount(budget, .compact, hidden: 3)])
      return [.status(spoken ? words.spoken(hidden: model.hidden) : words.rendered(hidden: model.hidden), .warning)]
    }
    return [.text(MoneyPhrase([.amount(row.spent, hidden: 3), .text(" of "), .amount(budget, .compact, hidden: 3)]))]
  }

  // MARK: How much

  /// The amount, centred, and what it does: "Covers the projected gap".
  private var amountBlock: some View {
    VStack(spacing: 2) {
      PlanAmountField(text: $draft, identifier: "move.amount", label: "Amount", focus: $typing)
      if let refusal {
        InlineStatus(tone: .error, text: refusal, size: .regular)
          .accessibilityIdentifier("move.refusal")
      } else if let gap = model.shortfall, destination == model.row?.id {
        let covers = (amount ?? 0) >= gap.minor
        PhraseText(covers ? "Covers the projected gap"
                     : MoneyPhrase([.text("The projected gap is AED "), .amount(gap, hidden: 3)]),
                   hidden: model.hidden)
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var refusal: String? {
    guard let amount, amount > 0, let from = chosenSource else { return nil }
    return model.refusal(moving: .aed(amount), from: from.id)
  }

  // MARK: From where

  /// "TAKE FROM" over the white card of choices: the first four, and "Show all 6" on the
  /// overline's line while more wait (it takes no room of its own, so the commit stays in
  /// view as Paper draws it).
  private var fromBlock: some View {
    let sources = self.sources
    let chosen = chosenSource
    return VStack(alignment: .leading, spacing: 8) {
      ReflowingRow(alignment: .firstTextBaseline) {
        PlanOverline("Take from")
      } trailing: {
        if sources.count > 4, !showAllSources {
          // A 44 target that lays out as tall as the overline: the padding is inside the
          // button (its own frame is the target) and taken back outside it.
          Button { showAllSources = true } label: {
            Text("Show all \(sources.count)")
              .hType(.footnote.weight(.semibold))
              .foregroundStyle(HColor.textLink)
              .padding(.vertical, 13)
              .padding(.horizontal, 4)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(.vertical, -13)
          .accessibilityIdentifier("move.showAll")
        }
      }
      if sources.isEmpty {
        Text("Nothing has money to spare this month.").hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .listCard()
      } else {
        PlanListCard {
          ForEach(showAllSources ? sources : Array(sources.prefix(4))) { s in
            Button { source = .some(s.id) } label: {
              SourceRow(source: s, selected: chosen?.id == s.id, hidden: model.hidden)
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("move.from.\(s.id ?? "rta")")
          }
        }
      }
    }
  }

  // MARK: Before and after

  /// "Groceries 2,200 → 2,518" and "Ready to assign 1,000 → 682": the two budgets the move
  /// changes, whole where they are whole.
  private func preview(amount: Int64, to: CategoryID, from: MoveSource) -> some View {
    let toRow = model.plan.row(to)
    var lines: [(String, Int64, Int64)] = []
    if let toRow { lines.append((toRow.name, toRow.budget.minor, toRow.budget.minor + amount)) }
    if let id = from.id, let fromRow = model.plan.row(id) {
      lines.append((fromRow.name, fromRow.budget.minor, fromRow.budget.minor - amount))
    } else {
      lines.append(("Ready to assign", model.plan.readyToAssign.minor, model.plan.readyToAssign.minor - amount))
    }
    return HListCard {
      ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
        if i > 0 { HDivider(inset: .text16) }
        BeforeAfterRow(name: line.0, before: line.1, after: line.2, hidden: model.hidden)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("move.preview")
  }

  // MARK: Commit

  private var commit: some View {
    VStack(spacing: 10) {
      Button(amount.map { "Move AED \(MoneyFormat.string($0))" } ?? "Enter an amount") {
        guard let amount, let to = destination else { return }
        typing = false
        _ = model.move(.aed(amount), from: chosenSource?.id, to: to)
      }
      .buttonStyle(.pill(.primary, fill: true))
      .disabled(amount == nil || amount == 0 || destination == nil || chosenSource == nil || refusal != nil)
      .accessibilityIdentifier("move.save")
      Text("You can undo this from the toast.").hType(.footnote).foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
    }
    .padding(.top, 4)
  }
}

/// "Groceries ……… 2,200 → 2,518": the name 16/22 500, the old figure 500 secondary, the arrow,
/// the new figure 700. At least 50 tall. Reads "Groceries, from AED 2,200 to AED 2,518".
private struct BeforeAfterRow: View {
  let name: String
  let before: Int64
  let after: Int64
  let hidden: Bool

  var body: some View {
    ReflowingRow(spacing: 12) {
      Text(name).hType(.callout.weight(.medium)).foregroundStyle(HColor.textPrimary)
    } trailing: {
      HStack(spacing: 6) {
        MoneyText(.aed(before), figure: HFigure.row.weight(.medium), style: .compact, hidden: hidden, hiddenGlyphs: 3,
                  color: HColor.textSecondary)
        PlanGlyph(kind: .arrowRight, size: 14, color: HColor.textSecondary, stroke: 2.2)
        MoneyText(.aed(abs(after)), figure: .row, style: .compact, hidden: hidden, hiddenGlyphs: 3,
                  color: after < 0 ? HColor.statusErrorForeground : HColor.textPrimary, sign: after < 0 ? .debt : .none)
      }
      .fixedSize()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(minHeight: 50)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityAddTraits(.isStaticText)
  }

  private var spoken: String {
    func amount(_ m: Int64) -> String {
      hidden ? "amount hidden" : (m < 0 ? "minus " : "") + "AED \(MoneyFormat.string(m, style: .compact))"
    }
    return "\(name), from \(amount(before)) to \(amount(after))"
  }
}
