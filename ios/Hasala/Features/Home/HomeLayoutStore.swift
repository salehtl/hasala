import Foundation
import HasalaModels

@MainActor
final class HomeLayoutStore {
  static let keyPrefix = "app.hasala.prefs.home.layout."

  private let defaults: UserDefaults
  let account: String

  init(defaults: UserDefaults = .standard, account: String) {
    self.defaults = defaults
    self.account = account
  }

  var key: String { Self.keyPrefix + account }

  func load() -> HomeLayout? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(HomeLayout.self, from: data)
  }

  func save(_ layout: HomeLayout) {
    guard let data = try? JSONEncoder().encode(layout) else { return }
    defaults.set(data, forKey: key)
  }

  func forget() {
    defaults.removeObject(forKey: key)
  }

  static func forgetAll(_ defaults: UserDefaults = .standard) {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
      defaults.removeObject(forKey: key)
    }
  }
}
