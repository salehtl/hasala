import HasalaDesign
import SwiftUI
import UIKit

@MainActor
final class ShieldWindow {
  private var window: UIWindow?

  func install(in scene: UIWindowScene, lock: AppLockController) {
    guard window?.windowScene !== scene else { return }
    let shield = UIWindow(windowScene: scene)
    shield.windowLevel = .alert + 1
    shield.overrideUserInterfaceStyle = .light
    let host = UIHostingController(rootView: ShieldView(lock: lock))
    host.view.backgroundColor = .clear
    shield.rootViewController = host
    window = shield
    update(lock)
  }

  func update(_ lock: AppLockController) {
    guard let window else { return }
    if lock.isLocked {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    window.isHidden = !lock.showsShield
    window.accessibilityViewIsModal = lock.isLocked
    for other in window.windowScene?.windows ?? [] where other !== window {
      other.accessibilityElementsHidden = lock.isLocked
    }
  }
}

struct WindowSceneReader: UIViewRepresentable {
  var found: (UIWindowScene) -> Void

  func makeUIView(context: Context) -> Probe {
    let probe = Probe()
    probe.found = found
    return probe
  }

  func updateUIView(_ probe: Probe, context: Context) {
    probe.found = found
  }

  final class Probe: UIView {
    var found: ((UIWindowScene) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let scene = window?.windowScene { found?(scene) }
    }
  }
}

struct ShieldView: View {
  let lock: AppLockController

  var body: some View {
    Group {
      if lock.isLocked {
        AppLockView(lock: lock)
      } else {
        SnapshotCover()
      }
    }
    .tint(HColor.actionAccent)
    .hMotionPolicy()
  }
}
