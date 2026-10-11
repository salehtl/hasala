import SwiftUI

/// Plan · October (Paper board). Not built yet: the tab, header and title only.
struct PlanView: View {
  let app: AppModel

  var body: some View {
    TabPlaceholder(
      app: app, title: "Plan", subtitle: "October 2026", systemImage: "chart.pie",
      message: "Ready to assign, your buckets and budgets arrive with the plan engine.",
      extra: .none, identifier: "plan.placeholder"
    )
  }
}
