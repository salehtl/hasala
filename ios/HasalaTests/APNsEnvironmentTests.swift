import Foundation
import Testing

@testable import Hasala

/// Spec 06 §11.3's vectors. The fixtures in `Fixtures/apns/` are synthetic: shaped like a
/// real profile (a PKCS#7 envelope with the property list in the clear), but with no
/// certificates, devices or names; only the team id and bundle id, which are public. They
/// end in `.mobileprovision.fixture` because the repository ignores `*.mobileprovision`, so
/// a real profile is never committed by accident.
@Suite("APNs environment")
struct APNsEnvironmentTests {
  private final class Marker {}

  private func fixture(_ name: String) throws -> URL {
    let bundle = Bundle(for: Marker.self)
    let url = bundle.url(forResource: "\(name).mobileprovision", withExtension: "fixture")
      ?? bundle.url(forResource: "\(name).mobileprovision", withExtension: "fixture", subdirectory: "Fixtures/apns")
    return try #require(url, "Fixtures/apns/\(name).mobileprovision.fixture is not in the test bundle")
  }

  @Test func noProfileIsProduction() {
    // The App Store and TestFlight strip embedded.mobileprovision.
    #expect(APNsProfile.resolve(profileAt: nil) == .resolved("production"))
    let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).mobileprovision")
    #expect(APNsProfile.resolve(profileAt: missing) == .resolved("production"))
  }

  @Test func aDevelopmentProfileIsSandbox() throws {
    #expect(APNsProfile.resolve(profileAt: try fixture("dev")) == .resolved("sandbox"))
  }

  @Test func anAdHocProfileIsProduction() throws {
    #expect(APNsProfile.resolve(profileAt: try fixture("adhoc")) == .resolved("production"))
  }

  @Test(arguments: ["noaps", "garbage", "truncated"])
  func anythingElseIsUnknown(_ name: String) throws {
    #expect(APNsProfile.resolve(profileAt: try fixture(name)) == .unknown)
  }

  @Test func anUnreadableFileIsUnknown() throws {
    // A directory where the profile should be: it exists, but it can't be read as data.
    let dir = FileManager.default.temporaryDirectory.appending(path: "apns-\(UUID().uuidString).mobileprovision")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(APNsProfile.resolve(profileAt: dir) == .unknown)
  }

  @Test func onlyTheTwoKnownValuesResolve() {
    func profile(_ aps: String) -> Data {
      Data("""
        \u{30}\u{82}<?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>aps-environment</key><string>\(aps)</string>
        </dict></dict></plist>\u{00}\u{01}
        """.utf8)
    }
    #expect(APNsProfile.resolve(profile: profile("development")) == .resolved("sandbox"))
    #expect(APNsProfile.resolve(profile: profile("production")) == .resolved("production"))
    #expect(APNsProfile.resolve(profile: profile("Production")) == .unknown)
    #expect(APNsProfile.resolve(profile: profile("")) == .unknown)
    // A plist without Entitlements, and an empty file.
    #expect(APNsProfile.resolve(profile: Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)) == .unknown)
    #expect(APNsProfile.resolve(profile: Data()) == .unknown)
  }

  @Test func thePlistIsCutAtTheFirstClosingTag() throws {
    let data = Data("junk<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>tail</plist>".utf8)
    let plist = try #require(APNsProfile.embeddedPlist(data))
    #expect(String(decoding: plist, as: UTF8.self) == "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>")
    #expect(APNsProfile.embeddedPlist(Data("<plist></plist>".utf8)) == nil)
  }

  /// The simulator's tokens are not used for QA (spec 06 §11.1): no registration there.
  @Test func theSimulatorNeverRegisters() {
    #if targetEnvironment(simulator)
      #expect(resolveAPNsEnvironment() == .unknown)
    #endif
  }
}
