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
        if lock.failed {
          NoteRow(icon: .info, text: "That didn't work. Try again.")
            .accessibilityIdentifier("lock.failed")
        }
      } footer: {
        Button(lock.biometry.unlockTitle) { Task { await lock.unlock() } }
          .buttonStyle(.pill(.primary, fill: true, loading: lock.busy, leadingIcon: lock.biometry.icon))
          .disabled(lock.busy)
          .accessibilityIdentifier("lock.unlock")
      }
    }
  }
}
