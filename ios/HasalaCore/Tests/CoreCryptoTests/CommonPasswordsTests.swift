// The bundled common-password list (spec 04 §4.6, §6.1.2) as the app loads it.
import CoreResources
import Testing

@testable import CoreCrypto

@Suite("Bundled common passwords")
struct CommonPasswordsTests {
  static let list = PasswordPolicy.Blocklist(text: CoreResources.commonPasswords())

  @Test func theListIsBundled() {
    #expect(Self.list.count > 100)
  }

  @Test func everyEntryIsASCIILowercased() {
    for line in CoreResources.commonPasswords().split(separator: "\n") {
      #expect(line == line.lowercased(), "\(line)")
      #expect(line.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }, "\(line)")
    }
  }

  @Test(arguments: ["Password2026!!!", "HasalaBudgeting1", "qwertyuiopas", "123456789012"])
  func refusesTheATC21Examples(_ pw: String) {
    #expect(PasswordPolicy.check(pw, blocklist: Self.list) == .tooCommon)
  }

  @Test func acceptsAPassphrase() {
    #expect(PasswordPolicy.check("copper lantern quietly 42", blocklist: Self.list) == nil)
  }
}
