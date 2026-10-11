import HasalaDesign
import SwiftUI

/// Your profile (Paper "Profile · Your profile"). Not built yet: the sheet scaffold and the build
/// footer, which the A0 smoke test reads on device.
struct ProfileSheet: View {
  let app: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          AvatarDisc(initial: app.snapshot.header.avatarInitial, size: 72)
          PlaceholderCard(systemImage: "person.crop.circle", title: "Your profile",
                          message: "Bank alerts, Sign-in & security and Settings arrive in a later build.")
          Text(BuildInfo.current.footer)
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("profile.buildFooter")
        }
        .padding(HSpacing.sheetPadding)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Your profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close) { dismiss() }
            .accessibilityIdentifier("profile.close")
        }
      }
    }
  }
}
