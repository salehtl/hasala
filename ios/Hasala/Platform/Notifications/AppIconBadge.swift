import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor
final class AppIconBadge {
  typealias Setter = @MainActor (Int) async -> Bool

  nonisolated static let permissionAnswered = Notification.Name("app.hasala.ios.notificationPermissionAnswered")

  private let app: AppModel
  private let set: Setter
  private let center: NotificationCenter
  private var last: Int?
  private var running = true
  private var observers: [NSObjectProtocol] = []

  init(app: AppModel, center: NotificationCenter = .default, set: @escaping Setter = AppIconBadge.system) {
    self.app = app
    self.center = center
    self.set = set
    for name in [UIApplication.didBecomeActiveNotification, Self.permissionAnswered] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setAgain() }
      })
    }
    observe()
  }

  func publish() async {
    guard running else { return }
    let count = app.reviewCount
    guard count != last else { return }
    last = count
    if await !set(count), last == count { last = nil }
  }

  func stop() {
    running = false
    observers.forEach(center.removeObserver)
    observers = []
  }

  static func clear() {
    UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)
  }

  static func system(_ count: Int) async -> Bool {
    do {
      try await UNUserNotificationCenter.current().setBadgeCount(count)
      return true
    } catch {
      return false
    }
  }

  private func setAgain() {
    last = nil
    Task { await publish() }
  }

  private func observe() {
    guard running else { return }
    withObservationTracking {
      _ = app.reviewCount
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    Task { await publish() }
  }
}
