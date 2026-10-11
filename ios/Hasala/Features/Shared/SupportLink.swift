import HasalaDesign
import SwiftUI

/// "Trouble signing in? Email support@hasala.app": a mail link in place of an account
/// action this build doesn't offer (password reset, recovery, new words, a passkey, a
/// new email address, freezing). A person reads the mail; nothing is sent from the app.
struct SupportLink: View {
  var lead: String
  var identifier: String

  var body: some View {
    Link(destination: BuildSurface.supportMail) {
      VStack(spacing: 2) {
        Text(lead).foregroundStyle(HColor.textSecondary)
        Text("Email \(BuildSurface.supportEmail)").foregroundStyle(HColor.textLink)
      }
      .hType(.subheadline)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isLink)
    .accessibilityIdentifier(identifier)
  }
}
