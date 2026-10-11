import Foundation
import LocalAuthentication
import UserNotifications

/// Notification permission through the system (spec 04 §9.3). "Show amounts and merchants"
/// is a device preference (§4.5, non-sensitive), off by default (PO-7).
@MainActor
final class SystemNotificationPermission: NotificationPermissionAsking {
  private static let detailsKey = "prefs.notifications.showDetails"
  private static let askedKey = "prefs.setup.notificationsAsked"

  var showsDetails: Bool {
    get { UserDefaults.standard.bool(forKey: Self.detailsKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.detailsKey) }
  }

  func requestAuthorization() async -> Bool {
    UserDefaults.standard.set(true, forKey: Self.askedKey)
    do {
      return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    } catch {
      return false
    }
  }
}

/// Onboarding step 0 (spec 04 §6.6): a device passcode is required for both sign-in
/// methods, because data protection and the approval key need it.
enum DevicePasscode {
  static func isSet() -> Bool {
    var error: NSError?
    return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
  }
}
