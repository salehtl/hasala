import HasalaDesign
import HasalaModels
import SwiftUI

struct AppLockView: View {
  let lock: AppLockController

  var body: some View {
    NavigationStack {
      HeroAccountScreen(
        hero: HeroDisc(icon: lock.biometry.icon, hue: .sky),
        title: "Hasala is locked",
        subtitle: "Your money stays hidden until you unlock."
      ) {
        EmptyView()
      } footer: {
        if lock.failed {
          HStack(spacing: 8) {
            Circle().fill(HColor.statusWarningForeground).frame(width: 7, height: 7)
            Text(Self.failedLine)
              .hType(.subheadline)
              .foregroundStyle(HColor.statusWarningForeground)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity)
          .padding(.bottom, 8)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("lock.failed")
          .announcesError(Self.failedLine)
        }
        Button(lock.biometry.unlockTitle) { Task { await lock.unlock() } }
          .buttonStyle(.pill(.primary, fill: true, loading: lock.busy, leadingIcon: lock.biometry.icon))
          .disabled(lock.busy)
          .accessibilityIdentifier("lock.unlock")
      }
    }
  }

  static let failedLine = "That didn't work. Try again."
}
