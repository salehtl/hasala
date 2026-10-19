import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

@MainActor
@Observable
final class ProjectsListModel {
  private let app: AppModel
  @ObservationIgnored private var memo = Memo<Int, ProjectsList>()

  init(app: AppModel) { self.app = app }

  var list: ProjectsList {
    memo.value(for: app.store.revision) { PlanEngine.projects(app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }

  func newProject() { app.editProject(nil) }
  func open(_ id: ProjectID) { app.openProject(id) }
}

struct ProjectsListView: View {
  @Bindable var app: AppModel
  @State private var model: ProjectsListModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: ProjectsListModel(app: app))
  }

  private var inPlan: Bool { app.router.plan.contains(.projects) }

  var body: some View {
    PlanDetailScreen(app: app, title: "Projects", wash: .hue(.peach), hostsToast: inPlan) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Money set aside for one thing, like a trip or a move. It stays out of your monthly plan unless you count it.")
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("New project") { model.newProject() }
          .buttonStyle(.pill(.onGrouped, fill: true, leadingIcon: .add))
          .accessibilityIdentifier("projects.new")
      }
      .padding(.horizontal, HSpacing.insetPage)

      let list = model.list
      if list.isEmpty {
        EmptyStateCard(icon: .project, tone: .neutral, title: "No projects yet",
                       message: "Make one to track a trip, a move or a gift against its own budget.")
          .padding(.horizontal, HSpacing.insetPage)
      }
      if !list.active.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          CountedTitle(title: "Active", count: list.active.count)
          ForEach(list.active) { p in
            Button { model.open(p.id) } label: { ProjectCard(project: p, hidden: model.hidden, reveal: 1) }
              .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous)))
              .accessibilityIdentifier("projects.project.\(p.id)")
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
      }
      if !list.completed.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          CountedTitle(title: "Completed", count: list.completed.count)
          PlanListCard {
            ForEach(list.completed) { p in
              Button { model.open(p.id) } label: {
                HListRow(leading: .disc(.peach, p.glyph.icon), title: p.name, supporting: .phrase(Self.completedLine(p)),
                         trailing: .amount(p.spent), hidden: model.hidden)
              }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("projects.project.\(p.id)")
            }
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
      }
    }
  }

  static func completedLine(_ p: PlanProjectModel) -> MoneyPhrase {
    let when = p.completedOn.map { "Finished \($0.dayMonth)" } ?? "Finished"
    guard let budget = p.budget else { return MoneyPhrase(stringLiteral: "\(when) · no budget") }
    return MoneyPhrase([.text("\(when) · "), .amount(budget, .compact, hidden: 3), .text(" budget")])
  }
}

#if HASALA_MOCKS
  #Preview("Projects") {
    let app = AppModel(store: InMemoryLedger())
    NavigationStack { ProjectsListView(app: app) }
  }
#endif
