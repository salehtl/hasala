import Foundation
import LocalAuthentication
import UserNotifications

/// Notification permission through the system (spec 04 §9.3). "Show amounts and merchants"
/// is a device preference (§4.5, non-sensitive), off by default (PO-7): it is
/// `DevicePrefs.notificationDetail`, the one the Lock Screen widgets read.
@MainActor
final class SystemNotificationPermission: NotificationPermissionAsking {
  private static let legacyDetailsKey = "prefs.notifications.showDetails"
  private static let askedKey = "prefs.setup.notificationsAsked"
  private let prefs = DevicePrefsStore()

  var showsDetails: Bool {
    get { prefs.prefs.notificationDetail }
    set {
      prefs.update { $0.notificationDetail = newValue }
      UserDefaults.standard.removeObject(forKey: Self.legacyDetailsKey)
    }
  }

  var answered: Bool { UserDefaults.standard.bool(forKey: Self.askedKey) }

  func decline() {
    UserDefaults.standard.set(true, forKey: Self.askedKey)
  }

  func requestAuthorization() async -> Bool {
    UserDefaults.standard.set(true, forKey: Self.askedKey)
    do {
      let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
      NotificationCenter.default.post(name: AppIconBadge.permissionAnswered, object: nil)
      return granted
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
