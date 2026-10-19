import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// The profile sheet's view model and cards over the Maya ledger.
@MainActor
@Suite("Profile model")
struct ProfileModelTests {
  /// The Bank alerts card says what `MailboxesSummary` says (the hero and the bell draw the
  /// same words): working in mint, a new sign-in or nothing connected otherwise.
  @Test func theStatusCardSaysWhatIsTrue() {
    let health = MayaLedger.state.mailbox
    let working = MailboxesSummary([MockMailbox.gmail], health: health, offer: nil)
    #expect(working.title == "Bank alerts are working")
    #expect(working.detail == "Last email 4 min ago\nEmirates NBD and DIB")
    #expect(working.hue == .mint)
    #expect(!working.needsYou)

    let signIn = MailboxesSummary([MockMailbox.needingSignIn(MockMailbox.gmail)], health: health,
                                  offer: .signInAgain(mailboxID: MockMailbox.gmail.id, provider: .gmail))
    #expect(signIn.title == "Sign in again")
    #expect(signIn.hue == .sand)
    #expect(signIn.needsYou)

    // Main's `theProfileCardsSayWhatIsTrue`: Outlook's sign-in again names Microsoft.
    let outlook = MailboxesSummary([MockMailbox.needingSignIn(MockMailbox.outlook)], health: health,
                                   offer: .signInAgain(mailboxID: MockMailbox.outlook.id, provider: .outlook))
    #expect(outlook.title == "Sign in again")
    #expect(outlook.detail == "Microsoft ended access to maya.k@example.com.")
    #expect(outlook.hue == .sand)

    let none = MailboxesSummary([], health: health, offer: .connect)
    #expect(none.title == "Your email isn't connected")
    #expect(none.needsYou)
  }

  /// Sign-in & security's row shows that page's own status.
  @Test func theSecurityRowShowsItsStatus() {
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

  /// The footer starts with the build (the tests read "Hasala QA · 0.2.0 (") and ends with
  /// Paper's promise, its hyphens unbreakable.
  @Test func theFooterLeadsWithTheBuild() throws {
    let build = try BuildInfo(infoDictionary: [
      "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "1", "HasalaGitCommit": "unset",
      "HasalaEnvironment": "qa", "HasalaAPIBaseURL": "https://api.example.com", "HasalaGoogleClientID": "unset",
      "HasalaGoogleRedirectScheme": "unset", "HasalaGmailPubSubTopic": "unset",
      "HasalaOutlookClientID": "unset", "HasalaOutlookRedirectScheme": "msauth.app.hasala.ios",
    ])
    let footer = ProfileSheet.footer(build)
    #expect(footer.hasPrefix("Hasala QA · 0.2.0 ("))
    #expect(footer.hasSuffix(" · End\u{2011}to\u{2011}end encrypted, never sold"))
  }

  @Test func profileSettingsAndRules() {
    let app = AppModel(store: InMemoryLedger())
    let profile = ProfileViewModel(app: app)
    profile.setFaceIDLock(false)
    #expect(!profile.snapshot.prefs.faceIDLock)
    profile.setNotifications(.everything)
    #expect(profile.snapshot.prefs.notifications == .everything)
    // Most used first; pausing one keeps its place and turns its switch off.
    #expect(profile.rules.first?.pattern == "\u{201C}carrefour\u{201D}")
    profile.setRule("r-zuma", enabled: false)
    #expect(profile.rules.first { $0.id == "r-zuma" }?.enabled == false)
    #expect(profile.rules.map(\.matches) == profile.rules.map(\.matches).sorted(by: >))
    // Export your data: every transaction, archived ones too, newest first.
    #expect(profile.exportRows.count == app.store.state.txns.count)
  }

  /// Sorting a new merchant with "Always use" writes a rule the list marks as learned today,
  /// with its match line in Paper's words.
  @Test func aRuleLearnedTodaySaysSo() throws {
    let app = AppModel(store: InMemoryLedger())
    let profile = ProfileViewModel(app: app)
    #expect(!profile.rules.contains { $0.learnedToday })
    #expect(app.perform(.categorize("lulu", "groceries", learnRule: true, project: nil)))
    let learned = try #require(profile.rules.first { $0.learnedToday })
    #expect(learned.pattern == "\u{201C}lulu hypermarket\u{201D}")
    #expect(learned.detail == "Contains · Groceries · 1 match")
    #expect(profile.snapshot.categoriesAndRules == "18 categories · 7 rules")
  }

  /// The money rows read the ledger: Bills counts what's tracked after a found bill is
  /// tracked; Hide amounts reaches the figures in the rows.
  @Test func theMoneyRowsFollowTheLedger() {
    let app = AppModel(store: InMemoryLedger())
    let profile = ProfileViewModel(app: app)
    #expect(profile.snapshot.bills == "9 tracked · 1 new found")
    #expect(profile.snapshot.newBills == 1)
    #expect(app.perform(.trackCandidate("apple-bill")))
    #expect(profile.snapshot.bills == "10 tracked")
    #expect(profile.snapshot.newBills == 0)
    app.toggleAmountsHidden()
    #expect(profile.hidden)
    #expect(profile.snapshot.projects.rendered(hidden: profile.hidden) == "1 active")
  }

  /// Bills' view model: one bill's page, and what stopping it does.
  @Test func aBillCanBeStoppedFromItsPage() throws {
    let app = AppModel(store: InMemoryLedger())
    let bills = BillsViewModel(app: app)
    let axa = try #require(bills.detail("axa"))
    #expect(axa.isLate)
    bills.markPaid("axa")
    #expect(bills.detail("axa")?.state == .upcoming)
    #expect(bills.detail("axa")?.history.dropFirst().first?.title == "Wed 7 Oct")
    bills.stopTracking("axa")
    #expect(bills.detail("axa") == nil)
    #expect(bills.snapshot.tracked == 8)
  }

  /// Needs a look's posters draw Paper's glyphs (1K9-0): the plain shield on AXA's, the wifi
  /// arcs on du's (a phone and internet bill); a utility that isn't one keeps the bolt.
  @Test func thePostersDrawTheirBoardsGlyphs() throws {
    let app = AppModel(store: InMemoryLedger())
    let looks = BillsViewModel(app: app).snapshot.needsALook
    let axa = try #require(looks.first { $0.id == "axa" })
    let du = try #require(looks.first { $0.id == "du" })
    #expect(BillsView.posterGlyph(axa) == .icon(.shield))
    #expect(BillsView.posterGlyph(du) == .wifi)
    var power = du
    power.billKind = "Electricity & water"
    #expect(BillsView.posterGlyph(power) == .icon(.utilities))
  }

  /// Signing out keeps this iPhone's data (S-26), so the alert never says "erased"; the
  /// profile and Sign-in & security say the same words.
  @Test func signingOutSaysTheDataStays() {
    #expect(AccountCopy.signOutMessage.contains("Hasala's data stays on this iPhone"))
    #expect(!AccountCopy.signOutMessage.contains("erased"))
  }

  /// Accounts' view model: net worth and its parts, hidden with Hide amounts.
  @Test func accountsAddUp() {
    let app = AppModel(store: InMemoryLedger())
    let accounts = AccountsViewModel(app: app)
    #expect(accounts.snapshot.netWorth == .aed(227_568_00))
    #expect(accounts.snapshot.everydayTotal == .aed(38_163_00))
    #expect(!accounts.hidden)
    app.toggleAmountsHidden()
    #expect(accounts.hidden)
  }
}
