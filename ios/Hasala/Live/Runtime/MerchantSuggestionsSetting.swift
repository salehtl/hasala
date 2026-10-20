import Foundation
import HasalaCloud

nonisolated enum MerchantSuggestionsSetting {
  static let key = "app.hasala.prefs.merchantSuggestions.enabled"
  static let autoSortKey = "app.hasala.prefs.merchantSuggestions.autoSort"
  static let refusedVersionKey = "app.hasala.prefs.merchantSuggestions.refusedVersion"

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

  static func appVersion(marketing: String, build: String) -> String {
    "\(marketing) (\(build))"
  }

  static func isRefused(version: String, _ defaults: UserDefaults = .standard) -> Bool {
    defaults.string(forKey: refusedVersionKey) == version
  }

  static func recordRefusal(version: String, _ defaults: UserDefaults = .standard) {
    defaults.set(version, forKey: refusedVersionKey)
  }

  static func refusal(version: String, suiteName: String? = nil) -> CloudRefusalRecord {
    let defaults: @Sendable () -> UserDefaults = { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    return CloudRefusalRecord(
      isRecorded: { isRefused(version: version, defaults()) }, record: { recordRefusal(version: version, defaults()) })
  }

  static let isEnabledReader: @Sendable () -> Bool = { isEnabled() }
  static let isAutoSortEnabledReader: @Sendable () -> Bool = { isAutoSortEnabled() }
}
