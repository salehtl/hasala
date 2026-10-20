import Foundation
import HasalaCloud

nonisolated enum MerchantSuggestionsSetting {
  static let key = "app.hasala.prefs.merchantSuggestions.enabled"
  static let autoSortKey = "app.hasala.prefs.merchantSuggestions.autoSort"
  static let refusedVersionKey = "app.hasala.prefs.merchantSuggestions.refusedVersion"
  static let firstImportStartedKey = "app.hasala.prefs.merchantSuggestions.firstImport.startedMs"
  static let firstImportRequestsKey = "app.hasala.prefs.merchantSuggestions.firstImport.requests"

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: key)
  }

  static func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: key)
    if !on {
      defaults.set(false, forKey: autoSortKey)
      endFirstImport(defaults)
    }
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
    endFirstImport(defaults)
  }

  static func turnOnForFirstImport(nowMs: Int64, _ defaults: UserDefaults = .standard) {
    setEnabled(true, defaults)
    setAutoSortEnabled(true, defaults)
    guard firstImport(defaults) == nil else { return }
    defaults.set(Double(nowMs), forKey: firstImportStartedKey)
    defaults.set(0, forKey: firstImportRequestsKey)
  }

  static func firstImport(_ defaults: UserDefaults = .standard) -> (startedMs: Int64, requests: Int)? {
    guard isEnabled(defaults), let started = defaults.object(forKey: firstImportStartedKey) as? Double else { return nil }
    return (Int64(started), max(0, defaults.integer(forKey: firstImportRequestsKey)))
  }

  static func recordFirstImport(requests: Int, _ defaults: UserDefaults = .standard) {
    guard defaults.object(forKey: firstImportStartedKey) != nil else { return }
    defaults.set(requests, forKey: firstImportRequestsKey)
  }

  static func endFirstImport(_ defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: firstImportStartedKey)
    defaults.removeObject(forKey: firstImportRequestsKey)
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
