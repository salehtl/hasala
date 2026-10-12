import Foundation
import Testing

@testable import Hasala

@MainActor
@Suite("BuildInfo")
struct BuildInfoTests {
  private let good: [String: Any] = [
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "261011.11530",
    "HasalaGitCommit": "0123456789ab",
    "HasalaEnvironment": "qa",
    "HasalaAPIBaseURL": "https://api.hasala.app",
    "HasalaGoogleClientID": "unset",
    "HasalaGoogleRedirectScheme": "unset",
    "HasalaGmailPubSubTopic": "projects/example-project/topics/example-topic",
  ]

  @Test func parsesAndFormatsTheFooter() throws {
    let info = try BuildInfo(infoDictionary: good)
    #expect(info.apiBaseURL.absoluteString == "https://api.hasala.app")
    #expect(info.footer == "Hasala QA · 0.1.0 (261011.11530) · 0123456789ab")
  }

  @Test func aMissingKeyIsAnError() {
    var d = good
    d["HasalaEnvironment"] = nil
    #expect(throws: BuildInfo.Problem.missing("HasalaEnvironment")) { try BuildInfo(infoDictionary: d) }
  }

  @Test func anUnexpandedSettingIsAnError() {
    var d = good
    d["HasalaGitCommit"] = "$(HASALA_GIT_COMMIT)"
    #expect(throws: BuildInfo.Problem.malformed("HasalaGitCommit")) { try BuildInfo(infoDictionary: d) }
  }

  @Test func theAPIMustBeHTTPS() {
    var d = good
    d["HasalaAPIBaseURL"] = "http://api.hasala.app"
    #expect(throws: BuildInfo.Problem.malformed("HasalaAPIBaseURL")) { try BuildInfo(infoDictionary: d) }
  }

  #if DEBUG
    /// Debug runs may point at a local server through the launch environment.
    @Test func theDebugOverrideAcceptsHTTPAndHTTPS() throws {
      #expect(try BuildInfo.debugAPIBaseURLOverride([:]) == nil)
      #expect(try BuildInfo.debugAPIBaseURLOverride(["HASALA_API_BASE_URL": "  "]) == nil)
      let local = try BuildInfo.debugAPIBaseURLOverride(["HASALA_API_BASE_URL": "http://localhost:8080"])
      #expect(local?.absoluteString == "http://localhost:8080")
      let tls = try BuildInfo.debugAPIBaseURLOverride(["HASALA_API_BASE_URL": "https://api.hasala.app"])
      #expect(tls?.host() == "api.hasala.app")
    }

    @Test func theDebugOverrideRejectsAnythingElse() {
      for bad in ["localhost:8080", "ftp://example.com", "http://", "not a url"] {
        #expect(throws: BuildInfo.Problem.malformed("HASALA_API_BASE_URL")) {
          try BuildInfo.debugAPIBaseURLOverride(["HASALA_API_BASE_URL": bad])
        }
      }
    }
  #endif

  /// Without an override the Info.plist value is used.
  @Test func theAPIBaseURLDefaultsToTheBundle() {
    if ProcessInfo.processInfo.environment["HASALA_API_BASE_URL"] == nil {
      #expect(BuildInfo.apiBaseURL() == BuildInfo.current.apiBaseURL)
    }
  }

  /// `BuildInfo` is not main-actor isolated: background work can read it.
  @Test nonisolated func isReadableOffTheMainActor() async {
    let footer = await Task.detached { BuildInfo.current.footer }.value
    #expect(footer.hasPrefix("Hasala QA · 0.2.0 ("))
  }

  /// The app's own Info.plist carries every key (spec 06 §4.2) and the export
  /// compliance answer (spec 06 §6.2).
  @Test func theBundleIsComplete() throws {
    let info = try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    #expect(info.environment == "qa")
    #expect(info.apiBaseURL.host() == "api.hasala.app")
    #expect(info.marketingVersion == "0.2.0")
    #expect(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)
    #expect(Bundle.main.bundleIdentifier == "app.hasala.ios")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Hasala")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") == nil)
    #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") == nil)
    #expect(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil)
  }

  /// The Google iOS client is filled in, its redirect scheme is the reversed client id
  /// (Gmail's redirect URI is `<scheme>:/oauth2redirect`), and the Pub/Sub topic is not in
  /// the build: the server's `GET /meta` names it.
  @Test func theBundleCarriesTheGoogleClient() throws {
    let info = try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    let suffix = ".apps.googleusercontent.com"
    #expect(info.googleClientID.hasSuffix(suffix))
    let id = info.googleClientID.dropLast(suffix.count)
    #expect(!id.isEmpty)
    #expect(info.googleRedirectScheme == "com.googleusercontent.apps.\(id)")
    #expect(info.gmailPubSubTopic == "unset")
  }
}
