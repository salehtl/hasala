// Unit tests for HasalaModel. The model itself only runs on a device with Apple
// Intelligence; these pin what holds everywhere: the factory answers, and an
// unavailable model keeps the tier off (rows stay in review).
import CoreCategorize
import Foundation
import Testing

@testable import HasalaModel

@Suite("HasalaModel")
struct HasalaModelTests {
  @Test("the unavailable stand-in turns the tier off")
  func unavailable() async {
    let m = UnavailableCategoryModel()
    #expect(m.availability() != .available)
    let r = await ModelTier.run(subjects: ["zuma"], model: m, allowed: ModelTier.allowed(TaxonomyV1.builtins), context: .foreground, now: { 0 })
    #expect(r.suggestions.isEmpty && r.unknown.isEmpty)
  }

  @Test("the factory answers an availability without throwing")
  func factory() {
    let m = HasalaModelFactory.make()
    let a = m.availability()
    #expect([.available, .notEligible, .notEnabled, .notReady, .unsupportedLanguage].contains(a))
    #expect(!m.modelTag.isEmpty)
  }

  @Test("the model tag follows the OS version (03c §8.6.6)")
  func tag() {
    let v = OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 2)
    #expect(HasalaModelFactory.osModelTag(v) == "apple-fm/27.1")
    #expect(HasalaModelFactory.osModelTag().hasPrefix("apple-fm/"))
  }
}
