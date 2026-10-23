import Foundation
import HasalaCloud

nonisolated enum MerchantSuggestionsSetting {
  static let key = "app.hasala.prefs.merchantSuggestions.enabled"
  static let autoSortKey = "app.hasala.prefs.merchantSuggestions.autoSort"
  static let reviewAskAnsweredKey = "app.hasala.prefs.merchantSuggestions.reviewAskAnswered"
  static let reviewAskMigratedKey = "app.hasala.prefs.merchantSuggestions.reviewAskMigrated"
  static let refusedVersionKey = "app.hasala.prefs.merchantSuggestions.refusedVersion"
  static let turnedOn = Notification.Name("app.hasala.merchantSuggestions.turnedOn")
  static let turnedOff = Notification.Name("app.hasala.merchantSuggestions.turnedOff")

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: key)
  }

  static func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: key)
    defaults.set(true, forKey: reviewAskAnsweredKey)
    if !on { defaults.set(false, forKey: autoSortKey) }
    NotificationCenter.default.post(name: on ? turnedOn : turnedOff, object: defaults)
  }

  static func isAutoSortEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    isEnabled(defaults) && defaults.bool(forKey: autoSortKey)
  }

  static func setAutoSortEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on && isEnabled(defaults), forKey: autoSortKey)
  }

  static func reviewAskAnswered(_ defaults: UserDefaults = .standard) -> Bool {
    isEnabled(defaults) || defaults.bool(forKey: reviewAskAnsweredKey)
  }

  static func answerReviewAsk(_ defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: reviewAskAnsweredKey)
  }

  static func migrateReviewAsk(setupFinished: Bool, _ defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: reviewAskMigratedKey) else { return }
    defaults.set(true, forKey: reviewAskMigratedKey)
    if setupFinished { answerReviewAsk(defaults) }
  }

  static func forget(_ defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key)
    defaults.removeObject(forKey: autoSortKey)
    defaults.removeObject(forKey: reviewAskAnsweredKey)
    for retired in retiredKeys { defaults.removeObject(forKey: retired) }
  }

  static let retiredKeys = [
    "app.hasala.prefs.merchantSuggestions.backlog.requested",
    "app.hasala.prefs.merchantSuggestions.firstImport.startedMs",
    "app.hasala.prefs.merchantSuggestions.firstImport.requests",
    "app.hasala.prefs.cloudSort.runOffer",
    "app.hasala.prefs.cloudSort.dismissedRun",
  ]

  static func turnOnBoth(_ defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: key)
    defaults.set(true, forKey: reviewAskAnsweredKey)
    defaults.set(true, forKey: autoSortKey)
    NotificationCenter.default.post(name: turnedOn, object: defaults)
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
