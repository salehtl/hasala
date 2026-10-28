import Foundation
import HasalaModels
import Observation

@MainActor
@Observable
final class NotificationReads {
  static let key = "prefs.bell.read.v1"

  @ObservationIgnored private let defaults: UserDefaults?
  @ObservationIgnored private lazy var salt: String = defaults.map { LocalAccountData.salt($0) } ?? ""
  private var reads: [String: Int]

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
    reads = Self.decode(defaults?.stringArray(forKey: Self.key) ?? [])
  }

  func isRead(_ item: NotificationItem) -> Bool {
    let (key, count) = entry(item)
    guard let seen = reads[key] else { return false }
    return count <= seen
  }

  func unread(_ items: [NotificationItem]) -> [NotificationItem] { items.filter { !isRead($0) } }

  func markAllRead(_ items: [NotificationItem]) {
    reads = Dictionary(items.map(entry), uniquingKeysWith: max)
    defaults?.set(reads.map { "\($0.key)|\($0.value)" }.sorted(), forKey: Self.key)
  }

  static func forget(_ defaults: UserDefaults) {
    defaults.removeObject(forKey: key)
  }

  private static func decode(_ stored: [String]) -> [String: Int] {
    var reads: [String: Int] = [:]
    for line in stored {
      let parts = line.split(separator: "|", maxSplits: 1)
      guard parts.count == 2, let n = Int(parts[1]) else { continue }
      reads[String(parts[0])] = n
    }
    return reads
  }

  private func entry(_ item: NotificationItem) -> (String, Int) {
    let shape = item.title.replacing(/\d+(,\d{3})*/, with: "#")
    let value = "\(item.id)|\(shape)"
    return (defaults == nil ? value : LocalAccountData.digest(value, salt: salt), item.count)
  }
}
