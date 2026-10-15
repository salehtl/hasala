import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// The profile sheet's view model and cards over the Maya ledger.
@MainActor
@Suite("Profile model")
struct ProfileModelTests {
  /// The Profile card says what Gmail needs before its status; Sign-in & security's row
  /// shows that page's own status.
  @Test func theProfileCardsSayWhatIsTrue() {
    #expect(ProfileSheet.title(.working, nil) == "Bank alerts are working")
    #expect(ProfileSheet.title(.working, .connect) == "Gmail isn't connected")
    #expect(ProfileSheet.title(.reconnect, nil) == "Gmail needs reconnecting")
    #expect(ProfileSheet.hue(.working, .reconnect) == .rose)
    let passkey = MockAccountService.securityState(for: .passkey)
    #expect(ProfileSheet.securityStatus(passkey).text == "Protected")
    #expect(ProfileSheet.securityStatus(passkey).tone == .success)
    var passwordOnly = passkey
    passwordOnly.passkeys = []
    #expect(ProfileSheet.securityStatus(passwordOnly).text == "Password only")
    #expect(ProfileSheet.securityStatus(passwordOnly).tone == .warning)
    passwordOnly.frozen = FreezeInfo(by: .operator, when: nil)
    #expect(ProfileSheet.securityStatus(passwordOnly).text == "Frozen")
  }

  @Test func profileSettingsAndRules() {
    let app = AppModel(store: InMemoryLedger())
    let profile = ProfileViewModel(app: app)
    profile.setFaceIDLock(false)
    #expect(!profile.snapshot.prefs.faceIDLock)
    profile.setNotifications(.everything)
    #expect(profile.snapshot.prefs.notifications == .everything)
    #expect(profile.rules.first?.pattern == "\"carrefour\"")
    profile.setRule("r-zuma", enabled: false)
    #expect(profile.rules.first { $0.id == "r-zuma" }?.enabled == false)
    #expect(profile.exportRows.count == app.store.state.txns.count)
  }
}
