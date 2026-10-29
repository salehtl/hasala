import Foundation
import HasalaModels

nonisolated enum ReviewOrderSetting {
  static let key = "app.hasala.prefs.review.order"

  static func load(_ defaults: UserDefaults?) -> ReviewOrder {
    defaults?.string(forKey: key).flatMap(ReviewOrder.init(rawValue:)) ?? .newestFirst
  }

  static func save(_ order: ReviewOrder, _ defaults: UserDefaults?) {
    defaults?.set(order.rawValue, forKey: key)
  }
}
