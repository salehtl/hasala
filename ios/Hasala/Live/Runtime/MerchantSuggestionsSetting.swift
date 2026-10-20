import Foundation

nonisolated enum MerchantSuggestionsSetting {
  static let key = "app.hasala.prefs.merchantSuggestions.enabled"
  static let autoSortKey = "app.hasala.prefs.merchantSuggestions.autoSort"

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: key)
  }

  static func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: key)
    if !on { defaults.set(false, forKey: autoSortKey) }
  }

  static func isAutoSortEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    isEnabled(defaults) && defaults.bool(forKey: autoSortKey)
  }

  static func setAutoSortEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on && isEnabled(defaults), forKey: autoSortKey)
  }

  static func forget(_ defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key)
    defaults.removeObject(forKey: autoSortKey)
  }

  static let isEnabledReader: @Sendable () -> Bool = { isEnabled() }
  static let isAutoSortEnabledReader: @Sendable () -> Bool = { isAutoSortEnabled() }
}
