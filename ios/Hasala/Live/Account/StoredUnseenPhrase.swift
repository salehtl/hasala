import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class StoredUnseenPhrase: UnseenPhraseNoting {
  static let sinceKey = "app.hasala.prefs.phrase.unseenSince"
  static let remindedKey = "app.hasala.prefs.phrase.reminded"
  static let reminderID = "app.hasala.phrase.reminder"
  static let reminderDelay: TimeInterval = 24 * 60 * 60

  struct Scheduler {
    var allowed: @MainActor () async -> Bool
    var schedule: @MainActor (_ id: String, _ fireAt: Date) async -> Bool
    var cancel: @MainActor (_ id: String) -> Void
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let scheduler: Scheduler
  @ObservationIgnored private let now: () -> Date
  private var changes = 0

  var unseen: Bool {
    _ = changes
    return defaults.object(forKey: Self.sinceKey) != nil
  }

  init(defaults: UserDefaults = .standard, scheduler: Scheduler = .system, now: @escaping () -> Date = { .now }) {
    self.defaults = defaults
    self.scheduler = scheduler
    self.now = now
  }

  var since: Date? {
    guard defaults.object(forKey: Self.sinceKey) != nil else { return nil }
    return Date(timeIntervalSince1970: defaults.double(forKey: Self.sinceKey))
  }

  func noteUnseen(at date: Date) {
    defaults.set(date.timeIntervalSince1970, forKey: Self.sinceKey)
    defaults.removeObject(forKey: Self.remindedKey)
    changes += 1
  }

  func noteSeen() {
    let had = unseen || defaults.object(forKey: Self.remindedKey) != nil
    defaults.removeObject(forKey: Self.sinceKey)
    defaults.removeObject(forKey: Self.remindedKey)
    changes += 1
    if had { scheduler.cancel(Self.reminderID) }
  }

  func adopt(serverUnseenSince: Date?) async {
    if let serverUnseenSince {
      if !unseen { noteUnseen(at: serverUnseenSince) }
    } else if unseen {
      noteSeen()
    }
  }

  func remindIfAllowed() async {
    guard unseen, let since, !defaults.bool(forKey: Self.remindedKey) else { return }
    let fireAt = since.addingTimeInterval(Self.reminderDelay)
    guard fireAt > now() else { return }
    guard await scheduler.allowed() else { return }
    guard unseen, !defaults.bool(forKey: Self.remindedKey) else { return }
    if await scheduler.schedule(Self.reminderID, fireAt) {
      defaults.set(true, forKey: Self.remindedKey)
    }
  }

  static func forget(_ defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: sinceKey)
    defaults.removeObject(forKey: remindedKey)
    Scheduler.system.cancel(reminderID)
  }
}

extension StoredUnseenPhrase.Scheduler {
  static var system: StoredUnseenPhrase.Scheduler {
    StoredUnseenPhrase.Scheduler(
      allowed: {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
      },
      schedule: { id, fireAt in
        let content = UNMutableNotificationContent()
        content.title = "Write down your 12 words"
        content.body = "Your spare key if you lose this iPhone and your passkey. Open Hasala to see them."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, fireAt.timeIntervalSinceNow), repeats: false)
        do {
          try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
          return true
        } catch {
          return false
        }
      },
      cancel: { id in
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
      })
  }
}
