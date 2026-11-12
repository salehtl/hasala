import HasalaDesign
import SwiftUI

struct GravatarSection: View {
  static let privacyURL = URL(string: "https://hasala.app/privacy")!

  private let preference = GravatarPreference.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Privacy")
      ProfileListCard(inset: .icon52) {
        SettingSwitchRow(icon: .eye, title: "Profile picture from Gravatar",
                         isOn: Binding(get: { preference.isOn }, set: { preference.setOn($0) }))
          .accessibilityIdentifier("profile.gravatar")
        Link(destination: Self.privacyURL) {
          SettingRow(icon: .privacy, title: "Privacy and data")
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityIdentifier("profile.privacy")
      }
      Text("Hasala asks Gravatar for your picture with a code made from your email. Off, it asks nothing and shows your initials.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("profile.gravatar.note")
    }
  }
}
