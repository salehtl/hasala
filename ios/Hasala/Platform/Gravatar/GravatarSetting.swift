import Foundation
import Observation

nonisolated enum GravatarSetting {
  static let key = "app.hasala.prefs.gravatar.enabled"

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key) as? Bool ?? true
  }

  static func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: key)
  }
}

@MainActor
@Observable
final class GravatarPreference {
  static let shared = GravatarPreference(loader: .shared)

  private(set) var isOn: Bool
  @ObservationIgnored private(set) var clearing: Task<Void, Never>?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let loader: GravatarLoader

  init(defaults: UserDefaults = .standard, loader: GravatarLoader) {
    self.defaults = defaults
    self.loader = loader
    isOn = GravatarSetting.isEnabled(defaults)
  }

  func setOn(_ on: Bool) {
    guard on != isOn else { return }
    GravatarSetting.setEnabled(on, defaults)
    isOn = on
    if !on { clearing = Task { [loader] in await loader.clear() } }
  }
}
