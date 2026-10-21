import Foundation
import HasalaCloud

nonisolated enum MerchantSuggestionsSetting {
  static let key = "app.hasala.prefs.merchantSuggestions.enabled"
  static let autoSortKey = "app.hasala.prefs.merchantSuggestions.autoSort"
  static let reviewAskAnsweredKey = "app.hasala.prefs.merchantSuggestions.reviewAskAnswered"
  static let refusedVersionKey = "app.hasala.prefs.merchantSuggestions.refusedVersion"
  static let firstImportStartedKey = "app.hasala.prefs.merchantSuggestions.firstImport.startedMs"
  static let firstImportRequestsKey = "app.hasala.prefs.merchantSuggestions.firstImport.requests"
  static let runRequestKey = "app.hasala.prefs.merchantSuggestions.backlog.requested"
  static let turnedOff = Notification.Name("app.hasala.merchantSuggestions.turnedOff")

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: key)
  }

  static func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: key)
    defaults.set(true, forKey: reviewAskAnsweredKey)
    if !on {
      defaults.set(false, forKey: autoSortKey)
      forgetRunRequest(defaults)
      NotificationCenter.default.post(name: turnedOff, object: nil)
    }
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

  static func forget(_ defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key)
    defaults.removeObject(forKey: autoSortKey)
    defaults.removeObject(forKey: reviewAskAnsweredKey)
    forgetRunRequest(defaults)
  }

  static func turnOnForFirstImport(_ defaults: UserDefaults = .standard) {
    setEnabled(true, defaults)
    setAutoSortEnabled(true, defaults)
    defaults.set(true, forKey: runRequestKey)
  }

  static func hasRunRequest(_ defaults: UserDefaults = .standard) -> Bool {
    isEnabled(defaults) && defaults.bool(forKey: runRequestKey)
  }

  @discardableResult
  static func takeRunRequest(_ defaults: UserDefaults = .standard) -> Bool {
    let requested = hasRunRequest(defaults)
    forgetRunRequest(defaults)
    return requested
  }

  static func forgetRunRequest(_ defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: runRequestKey)
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
