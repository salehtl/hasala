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

  /// The app's own Info.plist carries every key (spec 06 §4.2) and the export
  /// compliance answer (spec 06 §6.2).
  @Test func theBundleIsComplete() throws {
    let info = try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    #expect(info.environment == "qa")
    #expect(info.apiBaseURL.host() == "api.hasala.app")
    #expect(info.marketingVersion == "0.1.0")
    #expect(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)
    #expect(Bundle.main.bundleIdentifier == "app.hasala.ios")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Hasala")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") == nil)
    #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") == nil)
    #expect(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil)
  }
}
