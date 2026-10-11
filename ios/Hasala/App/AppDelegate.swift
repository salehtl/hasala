import UIKit

/// The UIKit half the SwiftUI app needs (spec 04 §2.3): the APNs token callbacks and
/// silent pushes. A silent push (`content-available`, sent when a peer uploads) is one
/// `WorkCoordinator` run of at most 25 s; its outcome is what iOS is told.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { await PushRegistrar.shared.didRegister(token: deviceToken) }
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    // No token (the simulator, or APNs unreachable): foreground and background refresh
    // still catch up.
  }

  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
    -> UIBackgroundFetchResult
  {
    guard let coordinator = AppGraph.boot?.runtime?.coordinator else { return .noData }
    let out = await coordinator.run(.silentPush, budget: .seconds(25))
    if out.failed { return .failed }
    return out.newData ? .newData : .noData
  }
}
