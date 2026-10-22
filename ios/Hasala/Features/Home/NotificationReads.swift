import Foundation
import HasalaModels
import Observation

@MainActor
@Observable
final class NotificationReads {
  static let key = "prefs.bell.read.v1"

  @ObservationIgnored private let defaults: UserDefaults?
  @ObservationIgnored private lazy var salt: String = defaults.map { LocalAccountData.salt($0) } ?? ""
  private var digests: Set<String>

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
    digests = Set(defaults?.stringArray(forKey: Self.key) ?? [])
  }

  func isRead(_ item: NotificationItem) -> Bool { digests.contains(digest(item)) }

  func unread(_ items: [NotificationItem]) -> [NotificationItem] { items.filter { !isRead($0) } }

  func markAllRead(_ items: [NotificationItem]) {
    digests = Set(items.map(digest))
    defaults?.set(digests.sorted(), forKey: Self.key)
  }

  static func forget(_ defaults: UserDefaults) {
    defaults.removeObject(forKey: key)
  }

  private func digest(_ item: NotificationItem) -> String {
    let value = "\(item.id)|\(item.title)"
    return defaults == nil ? value : LocalAccountData.digest(value, salt: salt)
  }
}
