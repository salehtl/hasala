import HasalaDesign
import SwiftUI

/// Your profile (Paper "Profile · Your profile"). Not built yet: the sheet scaffold and the build
/// footer, which the A0 smoke test reads on device.
struct ProfileSheet: View {
  let app: AppModel
  @Environment(\.dismiss) private var dismiss
  /// Present once the account gate runs (Debug today; Release when the live account
  /// service lands).
  @Environment(AccountSession.self) private var session: AccountSession?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          AvatarDisc(initial: app.snapshot.header.avatarInitial, size: 72)
          if let session {
            NavigationLink {
              SecurityView(session: session)
            } label: {
              HStack(spacing: 14) {
                Image(systemName: "lock.shield")
                  .font(.system(size: 17, weight: .medium))
                  .foregroundStyle(HColor.actionAccent)
                  .frame(width: 40, height: 40)
                  .background(HColor.actionAccentSubtle, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                  Text("Sign-in & security").hType(.headline).foregroundStyle(HColor.textPrimary)
                  Text("Passkeys, password, devices, recovery phrase").hType(.footnote)
                    .foregroundStyle(HColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(HColor.listRowChevron)
              }
              .padding(16)
              .listCard()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.security")
          }
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
