import HasalaDesign
import HasalaModels
import SwiftUI

@MainActor
@Observable
final class ProjectAddModel {
  private let app: AppModel
  let project: ProjectID
  var filter = ProjectCandidateFilter()
  var from: Date
  var to: Date
  var selected: Set<TxnID> = []
  static let shownLimit = 200

  init(app: AppModel, project: ProjectID) {
    self.app = app
    self.project = project
    let today = ProjectDates.date(app.store.now.date)
    from = app.store.state.project(project)?.starts.map(ProjectDates.date) ?? today
    to = today
  }

  var name: String { app.store.state.project(project)?.name ?? "the project" }
  var hidden: Bool { app.amountsHidden }
  var exists: Bool { app.store.state.project(project) != nil }

  var candidates: [MiniTxnRow] { PlanEngine.projectCandidates(project, app.store.state, filter: filter) }
  var narrowed: Bool { filter.narrowed }
  var shown: [MiniTxnRow] { narrowed ? candidates : [] }

  var categories: [CategoryOption] { app.store.state.budgetCategoryOptions }

  func categoryName(_ id: CategoryID?) -> String {
    id.flatMap { app.store.state.category($0)?.name } ?? "Any category"
  }

  func toggle(_ id: TxnID) {
    if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
  }

  func selectAll(_ rows: [MiniTxnRow]) { selected.formUnion(rows.map(\.id)) }

  func add(_ rows: [MiniTxnRow]) {
    let ids = rows.map(\.id).filter(selected.contains)
    guard !ids.isEmpty, app.perform(.assignProject(ids, project)) else { return }
    selected = []
    app.leaveAddToProject(project)
  }
}

struct ProjectAddTransactionsView: View {
  @Bindable var app: AppModel
  @State private var model: ProjectAddModel
  @FocusState private var searching: Bool

  init(app: AppModel, project: ProjectID) {
    self.app = app
    _model = State(initialValue: ProjectAddModel(app: app, project: project))
  }

  var body: some View {
    let matches = model.shown
    let rows = Array(matches.prefix(ProjectAddModel.shownLimit))
    let chosen = rows.filter { model.selected.contains($0.id) }
    PlanDetailScreen(app: app, title: "Add transactions", wash: .hue(.peach)) {
      filters
        .padding(.horizontal, HSpacing.insetPage)
      VStack(alignment: .leading, spacing: 12) {
        ReflowingRow(alignment: .firstTextBaseline) {
          CountedTitle(title: "Not in this project", count: model.narrowed ? matches.count : model.candidates.count)
        } trailing: {
          if model.narrowed, !rows.isEmpty, chosen.count < rows.count {
            Button { model.selectAll(rows) } label: {
              Text("Select all")
                .hType(.subheadline.weight(.medium))
                .foregroundStyle(HColor.textLink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("projectAdd.selectAll")
          }
        }
        if !model.narrowed {
          Text("Narrow by date, merchant or category first.")
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("projectAdd.narrowFirst")
        } else if rows.isEmpty {
          Text("No transactions match. Try another date or merchant.")
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          if matches.count > rows.count {
            Text("Showing \(MoneyFormat.count(rows.count)) of \(MoneyFormat.count(matches.count)). Narrow the search to see the rest.")
              .hType(.subheadline).foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("projectAdd.showing")
          }
          PlanListCard {
            ForEach(rows) { row in
              Button { model.toggle(row.id) } label: {
                HStack(spacing: 12) {
                  TransactionRow(row, hidden: model.hidden)
                  HIconView(model.selected.contains(row.id) ? .check : .add, size: 18,
                            color: model.selected.contains(row.id) ? HColor.textLink : HColor.listRowChevron)
                    .frame(width: 24)
                    .padding(.trailing, 16)
                    .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(HRowPressStyle())
              .accessibilityAddTraits(model.selected.contains(row.id) ? [.isSelected] : [])
              .accessibilityIdentifier("projectAdd.txn.\(row.id)")
            }
          }
        }
        Button(chosen.isEmpty ? "Choose transactions to add" : "Add \(chosen.count) to \(model.name)") {
          model.add(rows)
        }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(chosen.isEmpty)
        .accessibilityIdentifier("projectAdd.add")
        Text("Their spending counts against \(model.name), not your monthly budgets, unless the project is counted in the plan.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, HSpacing.insetPage)
    }
  }

  private var filters: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        HIconView(.magnifier, size: 18, color: HColor.textSecondary).accessibilityHidden(true)
        TextField("Merchant contains", text: $model.filter.merchant, axis: .vertical)
          .hType(.body)
          .foregroundStyle(HColor.fieldText)
          .lineLimit(1...3)
          .autocorrectionDisabled()
          .submitLabel(.search)
          .focused($searching)
          .onChange(of: model.filter.merchant) { _, new in
            guard new.contains("\n") else { return }
            model.filter.merchant = new.replacingOccurrences(of: "\n", with: "")
            searching = false
          }
          .accessibilityIdentifier("projectAdd.merchant")
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 48)
      .background(HColor.surfacePrimary, in: Capsule())
      FlowLayout(spacing: 8) {
        ChoiceChip(model.filter.from.map { "From \($0.dayMonth)" } ?? "Any start", selected: model.filter.from != nil) {
          model.filter.from = model.filter.from == nil ? ProjectDates.local(model.from) : nil
        }
        .accessibilityIdentifier("projectAdd.from")
        ChoiceChip(model.filter.to.map { "To \($0.dayMonth)" } ?? "Any end", selected: model.filter.to != nil) {
          model.filter.to = model.filter.to == nil ? ProjectDates.local(model.to) : nil
        }
        .accessibilityIdentifier("projectAdd.to")
        Menu {
          Button("Any category") { model.filter.category = nil }
          ForEach(model.categories) { c in Button(c.name) { model.filter.category = c.id } }
        } label: {
          let picked = model.filter.category != nil
          Text(model.categoryName(model.filter.category))
            .hType(.smallButton)
            .foregroundStyle(picked ? HColor.chipTextSelected : HColor.chipText)
            .padding(.horizontal, HSpacing.chipInset)
            .frame(minHeight: HSpacing.chipHeight)
            .background(picked ? HColor.chipSurfaceSelected : HColor.chipSurface, in: Capsule())
            .contentShape(Capsule().inset(by: -2))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Category, \(model.categoryName(model.filter.category))")
        .accessibilityAddTraits(model.filter.category != nil ? .isSelected : [])
        .accessibilityIdentifier("projectAdd.category")
      }
      if model.filter.from != nil {
        DatePicker("From", selection: $model.from, displayedComponents: .date)
          .environment(\.timeZone, ProjectDates.calendar.timeZone)
          .hType(.body)
          .onChange(of: model.from) { _, d in model.filter.from = ProjectDates.local(d) }
      }
      if model.filter.to != nil {
        DatePicker("To", selection: $model.to, displayedComponents: .date)
          .environment(\.timeZone, ProjectDates.calendar.timeZone)
          .hType(.body)
          .onChange(of: model.to) { _, d in model.filter.to = ProjectDates.local(d) }
      }
    }
  }
}
