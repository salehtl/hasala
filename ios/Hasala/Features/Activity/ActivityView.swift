import SwiftUI

/// Activity · Overview (Paper board). Not built yet: the tab, header ("+" is
/// Activity's extra header action) and title only.
struct ActivityView: View {
  let app: AppModel

  var body: some View {
    TabPlaceholder(
      app: app, title: "Activity", subtitle: "October 2026", systemImage: "clock.arrow.circlepath",
      message: "Your transactions, what's coming up and the review queue arrive with sync.",
      extra: .add, identifier: "activity.placeholder"
    )
  }
}
