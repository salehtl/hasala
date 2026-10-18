import HasalaDesign
import SwiftUI

/// "Trouble signing in? Email support@hasala.app": a mail link in place of an account
/// action this build doesn't offer (password reset, recovery, new words, a passkey, a
/// new email address, freezing). A person reads the mail; nothing is sent from the app.
///
/// A mail link does nothing on an iPhone without a mail account, so the support page
/// (hasala.app/support, which also gives the address) follows it, unless the screen
/// already links to that page (`web: false`).
struct SupportLink: View {
  var lead: String
  var identifier: String
  var web = true

  var body: some View {
    VStack(spacing: 0) {
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
      if web {
        Link(destination: BuildSurface.supportPage) {
          Text("Or visit hasala.app/support")
            .hType(.subheadline)
            .foregroundStyle(HColor.textLink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("\(identifier).web")
      }
    }
    .dockLink()
  }
}
