import UIKit

/// The UIKit half the SwiftUI app needs (spec 04 §2.3): the APNs token callbacks and
/// silent pushes. A silent push (`content-available`, sent when a peer uploads) is one
/// `WorkCoordinator` run of at most 25 s; its outcome is what iOS is told.
final class AppDelegate: NSObject, UIApplicationDelegate {
  /// The live graph starts with the process, not with the window: a launch for a silent
  /// push or a background task has an account to run before any scene connects.
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    #if HASALA_MOCKS
      // A mock scenario or a launched screen: the live graph never starts (no Keychain
      // purge, no network).
      if ScreenLaunch.isMockLaunch(ProcessInfo.processInfo.arguments) { return true }
    #endif
    AppGraph.live().start()
    return true
  }

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
    let start = ContinuousClock.now
    guard let coordinator = await AppGraph.boot?.openedRuntime()?.coordinator else { return .noData }
    let budget = Self.remainingBudget(Self.silentPushBudget, from: start, now: .now)
    guard budget > .zero else { return .noData }
    let out = await coordinator.run(.silentPush, budget: budget)
    if out.failed { return .failed }
    return out.newData ? .newData : .noData
  }

  static let silentPushBudget: Duration = .seconds(25)

  static func remainingBudget(_ total: Duration, from start: ContinuousClock.Instant, now: ContinuousClock.Instant)
    -> Duration
  {
    max(.zero, total - start.duration(to: now))
  }
}
