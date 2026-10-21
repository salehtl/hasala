import HasalaDesign
import SwiftUI

struct GravatarSection: View {
  private let preference = GravatarPreference.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Privacy")
      ProfileListCard(inset: .icon52) {
        SettingSwitchRow(icon: .eye, title: "Profile picture from Gravatar",
                         isOn: Binding(get: { preference.isOn }, set: { preference.setOn($0) }))
          .accessibilityIdentifier("profile.gravatar")
      }
      Text("Hasala asks Gravatar for your picture with a code made from your email address. Off, it asks nothing and shows your initials.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("profile.gravatar.note")
    }
  }
}
