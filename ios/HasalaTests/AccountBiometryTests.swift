import HasalaDesign
import LocalAuthentication
import Testing

@testable import Hasala

@Suite("Account biometry")
struct AccountBiometryTests {
  @Test func theLaunchArgumentPicksTheBiometry() {
    #expect(HBiometry.device(arguments: ["-HasalaBiometry", "touchID"]) == .touchID)
    #expect(HBiometry.device(arguments: ["-HasalaBiometry", "none"]) == .none)
    #expect(HBiometry.device(arguments: []) == .faceID)
  }

  @Test func theSystemTypeMapsAcross() {
    #expect(HBiometry(LABiometryType.faceID) == .faceID)
    #expect(HBiometry(LABiometryType.touchID) == .touchID)
    #expect(HBiometry(LABiometryType.none) == .none)
  }

  @Test func withoutBiometryTheWordingNamesThePasskey() {
    #expect(HBiometry.none.noun == "your passkey")
    #expect(HBiometry.touchID.noun == "Touch ID")
  }
}
