import Foundation

/// Which APNs environment this build's device tokens belong to, as the server's
/// `PUT /push/apns` expects it (spec 06 §11).
///
/// Not main-actor isolated, so the push registrar can resolve it from any context.
nonisolated enum APNsEnvironmentResolution: Sendable, Equatable {
  /// `"production"` or `"sandbox"`, the wire value sent with the token.
  case resolved(String)
  /// The environment can't be told from this build. Never register a token in this
  /// state; foreground refresh and background catch-up keep working without push.
  case unknown
}

/// This build's APNs environment, read from its embedded provisioning profile (spec 06
/// §11.3). See `APNsProfile.resolve(profileAt:)` for the rules.
///
/// The simulator answers `.unknown`: its tokens are not used for QA (spec 06 §11.1; wakes
/// there are tested with `xcrun simctl push`, which needs no registered token), and an
/// unsigned simulator build has no profile, which would otherwise read as `production`.
nonisolated func resolveAPNsEnvironment() -> APNsEnvironmentResolution {
  #if targetEnvironment(simulator)
    return .unknown
  #else
    return APNsProfile.resolve(profileAt: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"))
  #endif
}

/// Reads `aps-environment` out of a provisioning profile (spec 06 §11.3). A profile is a
/// CMS envelope whose payload, an XML property list, sits in the clear between the first
/// `<?xml` and the first `</plist>`; nothing here verifies the signature, because the
/// answer only picks which gateway a token is registered for.
nonisolated enum APNsProfile {
  /// The wire values of `PUT /push/apns` (`02` §7 route 31).
  static let production = "production"
  static let sandbox = "sandbox"

  /// - No file at `url` (or no URL): the App Store and TestFlight strip the profile, so
  ///   `production`.
  /// - A file that can't be read: `.unknown`.
  /// - Otherwise as `resolve(profile:)`.
  static func resolve(profileAt url: URL?) -> APNsEnvironmentResolution {
    guard let url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return .resolved(production)
    }
    guard let data = try? Data(contentsOf: url) else { return .unknown }
    return resolve(profile: data)
  }

  /// `aps-environment` `development` → `sandbox`, `production` → `production`; anything
  /// else (no plist, a plist that doesn't parse, no `Entitlements`, no key, another
  /// value) → `.unknown`.
  static func resolve(profile data: Data) -> APNsEnvironmentResolution {
    guard let plist = embeddedPlist(data),
      let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
      let entitlements = root["Entitlements"] as? [String: Any],
      let environment = entitlements["aps-environment"] as? String
    else { return .unknown }
    switch environment {
    case "development": return .resolved(sandbox)
    case "production": return .resolved(production)
    default: return .unknown
    }
  }

  /// The bytes from the first `<?xml` to the end of the first `</plist>` after it.
  static func embeddedPlist(_ data: Data) -> Data? {
    guard let start = data.firstRange(of: Data("<?xml".utf8)),
      let end = data[start.lowerBound...].firstRange(of: Data("</plist>".utf8))
    else { return nil }
    return Data(data[start.lowerBound..<end.upperBound])
  }
}
