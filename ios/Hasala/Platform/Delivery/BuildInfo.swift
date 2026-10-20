import Foundation

/// What this build is, read once from Info.plist (spec 06 §2.3). Nothing else reads
/// the `Hasala*` keys; every other module gets a `BuildInfo` value. Never touches the network.
/// Not main-actor isolated (the app target's default), so background code can read `.current`.
nonisolated public struct BuildInfo: Sendable, Equatable {
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
  /// `HasalaOutlookClientID`: the Entra app's client id (a public client, no secret); `unset`
  /// until the owner registers the app, and then "Outlook" is not offered.
  public let outlookClientID: String
  /// `HasalaOutlookRedirectScheme`: `msauth.app.hasala.ios`; deliberately not registered in
  /// CFBundleURLTypes (inspect-ipa.sh I4), like Google's.
  public let outlookRedirectScheme: String
  public let assistBaseURL: URL?

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
    outlookClientID = try string("HasalaOutlookClientID")
    outlookRedirectScheme = try string("HasalaOutlookRedirectScheme")
    assistBaseURL = Self.assistURL(info["HasalaAssistBaseURL"])
  }

  public static func assistURL(_ value: Any?) -> URL? {
    guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, !raw.hasPrefix("$("),
      let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty
    else { return nil }
    return url
  }

  public static func assistBaseURL() -> URL? {
    current.assistBaseURL
  }

  /// This build's values. A missing or malformed key is a build defect, so it traps.
  public static let current: BuildInfo = {
    do {
      return try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    } catch {
      fatalError("Info.plist is missing a Hasala build key: \(error)")
    }
  }()

  /// The API origin this run talks to; the composition root asks here, not `current`.
  ///
  /// - Release: `HasalaAPIBaseURL` from Info.plist, which `current` has already required
  ///   to be https. The launch environment is never read.
  /// - Debug: the launch environment variable `HASALA_API_BASE_URL` wins when set, so a
  ///   simulator run can reach a local server (http allowed). A malformed value traps
  ///   rather than silently falling back to the QA API.
  public static func apiBaseURL() -> URL {
    #if DEBUG
      do {
        if let url = try debugAPIBaseURLOverride(ProcessInfo.processInfo.environment) {
          return url
        }
      } catch {
        fatalError("HASALA_API_BASE_URL must be an http(s) URL with a host")
      }
    #endif
    return current.apiBaseURL
  }

  #if DEBUG
    /// The Debug-only override from a launch environment: nil when `HASALA_API_BASE_URL`
    /// is unset or blank; throws `.malformed` unless it is an http or https URL with a host.
    static func debugAPIBaseURLOverride(_ environment: [String: String]) throws(Problem) -> URL? {
      let key = "HASALA_API_BASE_URL"
      guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
        return nil
      }
      guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty
      else { throw .malformed(key) }
      return url
    }
  #endif

  /// "Hasala QA · 0.1.0 (261011.11530) · 1a2b3c4d5e6f" (spec 06 §15.2).
  public var footer: String {
    "Hasala \(environment.uppercased()) · \(marketingVersion) (\(buildNumber)) · \(gitCommit)"
  }
}
