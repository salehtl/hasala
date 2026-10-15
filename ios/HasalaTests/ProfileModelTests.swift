import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// The profile sheet's view model and cards over the Maya ledger.
@MainActor
@Suite("Profile model")
struct ProfileModelTests {
  /// The Profile card offers what mail needs on its provider's screen; Sign-in &
  /// security's row shows that page's own status. (The card's words are
  /// `MailboxesSummary`'s, tested with the mailboxes.)
  @Test func theProfileCardsSayWhatIsTrue() {
    #expect(ProfileSheet.action(.connect) == "Connect your email")
    #expect(ProfileSheet.action(.signInAgain(mailboxID: "gmail-1", provider: .gmail)) == "Sign in again")
    #expect(ProfileSheet.provider(.connect, [.gmail, .outlook]) == .gmail)
    #expect(ProfileSheet.provider(.connect, []) == nil)
    #expect(ProfileSheet.provider(.signInAgain(mailboxID: "outlook-1", provider: .outlook), [.gmail]) == .outlook)
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
