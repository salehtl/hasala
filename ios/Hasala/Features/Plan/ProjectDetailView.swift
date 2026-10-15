import HasalaDesign
import HasalaModels
import SwiftUI

/// A project (Paper "Plan · Japan trip (project)"), pushed from Plan and Profile.
///
/// The foundation's version (plan B7.3): the project's card from Plan, on today's parts.
// TODO(spec 12 §10): the peach wash and hero, progress, dates, "Count in monthly plan", By
// category and Transactions.
struct ProjectDetailView: View {
  @Bindable var app: AppModel
  let project: ProjectID
  @State private var plan: PlanViewModel

  init(app: AppModel, project: ProjectID) {
    self.app = app
    self.project = project
    _plan = State(initialValue: PlanViewModel(app: app))
  }

  private var row: PlanProjectModel? { plan.snapshot.projects.first { $0.id == project } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let p = row {
          VStack(alignment: .leading, spacing: 10) {
            Text(p.dates).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              MoneyText(p.left, figure: .large, hidden: plan.hidden, color: HColor.textPrimary)
              PhraseText(MoneyPhrase([.text("left of "), .amount(p.budget, .compact)]), hidden: plan.hidden)
                .hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
            }
            ProgressLine(p.progress, fill: HColor.actionAccent, track: HColor.progressTrackOnHue)
            if !p.countInPlan {
              Label("Not counted in your monthly plan", systemImage: "info.circle")
                .hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
            }
          }
          .padding(16)
          .background(Hue.peach.gradient, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
          .accessibilityElement(children: .combine)
        } else {
          EmptyNote(systemImage: "flag", message: "This project is no longer here.")
        }
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle(row?.name ?? "Project")
    .navigationBarTitleDisplayMode(.inline)
  }
}
