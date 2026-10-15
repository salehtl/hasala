import HasalaModels
import SwiftUI

/// A category's month (Paper "Plan · Dining"), pushed from Plan's budget rows and the bell.
///
/// The foundation's version (plan B7.3): today's filtered month with the budget actions
/// (`CategoryActivityView`).
// TODO(spec 12 §7): the lilac hero, the pace bar with its fill sequence, the verdict, Day by
// day, This month and the rules that sort into it.
struct CategoryDetailView: View {
  @Bindable var app: AppModel
  let category: CategoryID
  /// Change budget and Move money in open their sheets through it.
  @State private var plan: PlanViewModel

  init(app: AppModel, category: CategoryID) {
    self.app = app
    self.category = category
    _plan = State(initialValue: PlanViewModel(app: app))
  }

  var body: some View { CategoryActivityView(app: app, category: category, plan: plan) }
}
