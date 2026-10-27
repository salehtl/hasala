import OSLog
import UIKit

/// The UIKit half the SwiftUI app needs (spec 04 §2.3): the APNs token callbacks and
/// silent pushes. A silent push (`content-available`, sent when a peer uploads) is one
/// `WorkCoordinator` run of at most 25 s; its outcome is what iOS is told.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    OnScreen.shared.follow(application.applicationState)
    #if HASALA_MOCKS
      // A mock scenario or a launched screen: the live graph never starts (no Keychain
      // purge, no network).
      if ScreenLaunch.isMockLaunch(ProcessInfo.processInfo.arguments) { return true }
    #endif
    let boot = AppGraph.live()
    if Self.startsAtLaunch(application.applicationState) { boot.start() }
    return true
  }

  static func startsAtLaunch(_ state: UIApplication.State) -> Bool { state != .background }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { await PushRegistrar.shared.didRegister(token: deviceToken) }
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    // No token (the simulator, or APNs unreachable): foreground and background refresh
    // still catch up.
    let code = (error as NSError).code
    Logger(subsystem: "app.hasala.ios", category: "push").notice("APNs registration failed, code \(code, privacy: .public)")
  }

  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
    -> UIBackgroundFetchResult
  {
    await Self.silentPush(BackgroundEntry.live()) { rt, budget in
      let out = await rt.coordinator.run(.silentPush, budget: budget)
      if out.failed { return .failed }
      return out.newData ? .newData : .noData
    }
  }

  static func silentPush<Runtime>(
    _ entry: BackgroundEntry<Runtime>?, run: (Runtime, Duration) async -> UIBackgroundFetchResult
  ) async -> UIBackgroundFetchResult {
    let start = ContinuousClock.now
    guard let rt = await entry?.runtime() else { return .noData }
    let budget = Self.remainingBudget(Self.silentPushBudget, from: start, now: .now)
    guard budget > .zero else { return .noData }
    return await run(rt, budget)
  }

  static let silentPushBudget: Duration = .seconds(25)

  static func remainingBudget(_ total: Duration, from start: ContinuousClock.Instant, now: ContinuousClock.Instant)
    -> Duration
  {
    max(.zero, total - start.duration(to: now))
  }
}
