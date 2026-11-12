import HasalaDesign
import Testing

@testable import Hasala

@MainActor
@Suite("Boot walls")
struct BootWallTests {
  static let erasing: [BootController.Wall] = [.otherAccount(email: nil), .foreignData, .unenrolled, .restoring, .openFailed]

  @Test func removingDataIsNeverTheSafeLookingAction() {
    for wall in Self.erasing {
      #expect(BootWallView.eraseKind == .destructiveQuiet, "\(wall)")
    }
  }

  @Test func everyEraseWallSaysUnuploadedChangesAreLost() {
    for wall in Self.erasing {
      #expect(BootWallView.note(for: wall)?.contains("Changes not uploaded yet are lost.") == true, "\(wall)")
    }
  }

  @Test func setUpAgainSaysWhatHappenedPlainly() {
    #expect(BootWallView.subtitle(for: .unenrolled)
      == "This iPhone lost its key to your account.")
    #expect(BootWallView.eraseTitle(for: .unenrolled) == "Remove data and sign in again")
    #expect(BootWallView.eraseTitle(for: .openFailed) == "Remove this iPhone's data")
  }

  @Test func updateWallSaysTheBuildIsOutOfDate() {
    #expect(BootWallView.subtitle(for: .updateRequired)
      == "This version is out of date. Update Hasala in TestFlight, then open it again.")
  }
}
