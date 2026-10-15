import HasalaDesign
import SwiftUI

/// Accounts · Net worth (Paper 1W6-0), pushed from Home's net worth widget and Profile ›
/// Accounts. Both are Debug only until it is built (`BuildSurface`).
///
/// The foundation's version (plan B7.3): a placeholder.
// TODO(spec 13 B1): the net worth hero, the last 12 months, Everyday money and Tracking.
struct AccountsView: View {
  @Bindable var app: AppModel

  init(app: AppModel) {
    self.app = app
  }

  var body: some View {
    ScrollView {
      PlaceholderCard(systemImage: "building.columns", title: "Accounts",
                      message: "Net worth, your accounts and check-ins. This screen comes in a later build.")
        .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Accounts")
    .navigationBarTitleDisplayMode(.inline)
  }
}
