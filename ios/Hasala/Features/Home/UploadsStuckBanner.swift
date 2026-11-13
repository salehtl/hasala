import HasalaDesign
import SwiftUI

struct UploadsStuckBanner: View {
  let notices: SyncNotices
  @State private var confirmingErase = false
  @Environment(\.openURL) private var openURL

  static let message = "Changes on this iPhone aren't uploading. Reading your bank alerts still works."
  static let emailTitle = "Email \(BuildSurface.supportEmail)"
  static let eraseTitle = "Remove this iPhone's data"

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(HColor.surfacePrimary)
        .frame(width: 24, height: 24)
        .overlay { HIconView(.upload, size: 14, color: HColor.statusWarningForeground, strokeWidth: 2.2) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text(Self.message)
          .hType(.subheadline)
          .foregroundStyle(HColor.statusWarningForeground)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("home.uploadsStuck.message")
        VStack(alignment: .leading, spacing: 6 - HInlineLinkStyle.minimumHitHeight + 20) {
          Button(Self.emailTitle) { openURL(BuildSurface.supportMail) }
            .buttonStyle(.inlineLink(color: HColor.statusWarningForeground))
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("home.uploadsStuck.email")
          if notices.eraseThisIPhone != nil {
            Button(Self.eraseTitle) { confirmingErase = true }
              .buttonStyle(.inlineLink(color: HColor.actionDestructive))
              .accessibilityIdentifier("home.uploadsStuck.erase")
          }
        }
        .padding(.vertical, (20 - HInlineLinkStyle.minimumHitHeight) / 2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(HColor.statusWarningSurface, in: RoundedRectangle(cornerRadius: HRadius.statTile, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home.uploadsStuck")
    .alert(BootWallView.eraseAlertTitle, isPresented: $confirmingErase) {
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) { Task { await notices.eraseThisIPhone?() } }
        .accessibilityIdentifier("home.uploadsStuck.erase.confirm")
    } message: {
      Text(BootWallView.eraseAlertMessage)
    }
  }
}
