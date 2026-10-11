import Foundation

/// What this build is, read once from Info.plist (spec 06 §2.3). Nothing else reads
/// the `Hasala*` keys; every other module gets a `BuildInfo` value. Never touches the network.
public struct BuildInfo: Sendable, Equatable {
  /// `CFBundleShortVersionString`, e.g. `0.1.0`.
  public let marketingVersion: String
  /// `CFBundleVersion`, e.g. `261011.11530` (spec 06 §8); `1` in local builds.
  public let buildNumber: String
  /// `HasalaGitCommit`: 12 hex characters in archives, `unset` in local builds.
  public let gitCommit: String
  /// `HasalaEnvironment`: always `qa` for now (every deployment is QA).
  public let environment: String
  /// `HasalaAPIBaseURL`.
  public let apiBaseURL: URL
  /// `HasalaGoogleClientID`: a public client, no secret; `unset` before Gate A1.
  public let googleClientID: String
  /// `HasalaGoogleRedirectScheme`: the reversed client id; deliberately not registered (spec 06 DV-2).
  public let googleRedirectScheme: String
  /// `HasalaGmailPubSubTopic`; the server's value wins on a mismatch (spec 04 §7.2).
  public let gmailPubSubTopic: String

  public enum Problem: Error, Equatable {
    case missing(String)
    case malformed(String)
  }

  /// Parses an Info.plist dictionary; throws on a missing or malformed key.
  public init(infoDictionary info: [String: Any]) throws(Problem) {
    func string(_ key: String) throws(Problem) -> String {
      guard let v = info[key] as? String else { throw .missing(key) }
      let trimmed = v.trimmingCharacters(in: .whitespaces)
      // An unexpanded `$(VAR)` means the build setting was never defined.
      guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { throw .malformed(key) }
      return trimmed
    }
    marketingVersion = try string("CFBundleShortVersionString")
    buildNumber = try string("CFBundleVersion")
    gitCommit = try string("HasalaGitCommit")
    environment = try string("HasalaEnvironment")
    let base = try string("HasalaAPIBaseURL")
    guard let url = URL(string: base), url.scheme == "https", url.host() != nil else {
      throw .malformed("HasalaAPIBaseURL")
    }
    apiBaseURL = url
    googleClientID = try string("HasalaGoogleClientID")
    googleRedirectScheme = try string("HasalaGoogleRedirectScheme")
    gmailPubSubTopic = try string("HasalaGmailPubSubTopic")
  }

  /// This build's values. A missing or malformed key is a build defect, so it traps.
  public static let current: BuildInfo = {
    do {
      return try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    } catch {
      fatalError("Info.plist is missing a Hasala build key: \(error)")
    }
  }()

  /// "Hasala QA · 0.1.0 (261011.11530) · 1a2b3c4d5e6f" (spec 06 §15.2).
  public var footer: String {
    "Hasala \(environment.uppercased()) · \(marketingVersion) (\(buildNumber)) · \(gitCommit)"
  }
}
