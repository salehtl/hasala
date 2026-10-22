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
  func start(_ starter: ProjectStarter) { app.newProject(starter) }
  func open(_ id: ProjectID) { app.openProject(id) }
}

struct ProjectsListView: View {
  @Bindable var app: AppModel
  var tabRoot = false
  @State private var model: ProjectsListModel

  init(app: AppModel, tabRoot: Bool = false) {
    self.app = app
    self.tabRoot = tabRoot
    _model = State(initialValue: ProjectsListModel(app: app))
  }

  var body: some View {
    if tabRoot {
      TabScreen(app: app, title: "Projects", wash: .hue(.peach)) { content }
    } else {
      PlanDetailScreen(app: app, title: "Projects", wash: .hue(.peach)) { content }
    }
  }

  @ViewBuilder private var content: some View {
    let list = model.list
    if list.isEmpty {
      ProjectsEmptyState(newProject: { model.newProject() }, start: { model.start($0) })
        .padding(.horizontal, HSpacing.insetPage)
    } else {
      VStack(alignment: .leading, spacing: 16) {
        Text("Money set aside for one thing, like a trip or a move. It stays out of your monthly plan unless you count it.")
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("New project") { model.newProject() }
          .buttonStyle(.pill(.onGrouped, fill: true, leadingIcon: .add))
          .accessibilityIdentifier("projects.new")
      }
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

  static func completedLine(_ p: PlanProjectModel) -> MoneyPhrase {
    let when = p.completedOn.map { "Finished \($0.dayMonth)" } ?? "Finished"
    guard let budget = p.budget else { return MoneyPhrase(stringLiteral: "\(when) · no budget") }
    return MoneyPhrase([.text("\(when) · "), .amount(budget, .compact, hidden: 3), .text(" budget")])
  }
}

struct ProjectsEmptyState: View {
  let newProject: () -> Void
  let start: (ProjectStarter) -> Void

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 16) {
        HueDisc(hue: .peach, glyph: .flag, size: 80, iconSize: 36)
        VStack(spacing: 8) {
          Text("Set money aside for one thing")
            .hType(.title2)
            .foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          Text("A trip, a move, Eid gifts. Give it a budget, add its payments, and see what's left. It stays out of your monthly budgets.")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }
      Button("New project", action: newProject)
        .buttonStyle(.pill(.primary, fill: true, leadingIcon: .add))
        .accessibilityIdentifier("projects.new")
      VStack(spacing: 12) {
        Text("Or start from").hType(.footnote).foregroundStyle(HColor.textSecondary)
        FlowLayout(spacing: 8) {
          ForEach(ProjectStarter.quickStarts, id: \.self) { starter in
            Button { start(starter) } label: {
              HStack(spacing: 6) {
                HIconView(starter.glyph.icon, size: 16, color: Hue.peach.ink)
                  .accessibilityHidden(true)
                Text(starter.name).hType(.smallButton).foregroundStyle(HColor.chipText)
              }
              .padding(.horizontal, HSpacing.chipInset)
              .frame(minHeight: HSpacing.chipHeight)
              .background(HColor.chipSurface, in: Capsule())
              .contentShape(Capsule().inset(by: -2))
            }
            .buttonStyle(HPressStyle(in: Capsule()))
            .accessibilityLabel("Start from \(starter.name)")
            .accessibilityIdentifier("projects.start.\(starter.glyph.rawValue)")
          }
        }
      }
    }
    .padding(.top, 12)
    .frame(maxWidth: .infinity)
  }
}

#if HASALA_MOCKS
  #Preview("Projects") {
    let app = AppModel(store: InMemoryLedger())
    NavigationStack { ProjectsListView(app: app) }
  }
#endif
