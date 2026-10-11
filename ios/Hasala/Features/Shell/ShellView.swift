import HasalaDesign
import SwiftUI

/// Gate A0's Release screen (spec 06 §15.2): the wordmark and the build footer.
/// It proves signing, the icon and the version wiring; it reads and stores nothing.
struct ShellView: View {
  let build: BuildInfo

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Image("HasalaWordmark")
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 260)
        .accessibilityLabel("Hasala")
      Text("Know what's left, and keep it to yourself.")
        .hType(.body)
        .foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
      Spacer()
      Text(build.footer)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .accessibilityIdentifier("shell.footer")
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(HColor.surfaceSecondary)
  }
}
