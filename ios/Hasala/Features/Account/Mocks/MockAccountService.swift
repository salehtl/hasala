#if HASALA_MOCKS
  import CoreCrypto
  import Foundation

  /// The in-memory account service for Debug scenarios, previews and UI tests (spec 04
  /// §15.3: "auth calls answered by an in-memory AuthService mock, never by
  /// CoreSoftAuth"). It keeps the rules the server enforces that the screens depend on:
  /// one uniform wrong-password answer, five tries per email code, the last
  /// authenticator, step-ups that need the right password.
  ///
  /// Fixed values (synthetic): email codes are `123456`; the existing account is
  /// `maya@example.com` with the password `copper lantern quietly 42`; the phrase is
  /// `MockAccountService.phraseWords`.
  @MainActor
  final class MockAccountService: AccountService {
    static let emailCode = "123456"
    static let existingEmail = "maya@example.com"
    static let existingPassword = "copper lantern quietly 42"
    /// A valid phrase from fixed entropy 01…10 (synthetic).
    static let phraseWords: [String] = (try? Phrase.words(entropy: Data((1...16).map { UInt8($0) }))) ?? []
    /// Paper's "Word 3, 7, 9, 12".
    static let confirmPositions = [2, 6, 8, 11]
    /// Invite codes that start with this are "not found".
    static let unknownInvitePrefix = "ZZZZ"

    enum Account: Equatable {
      case none
      case passkey
      case passwordOnly
    }

    /// Simulated latency per call.
    var delay: Duration = .milliseconds(250)
    /// What the existing account has (the sign-in scenarios).
    var existing: Account
    /// What a successful sign-in leads to.
    var signInOutcome: SignInOutcome = .ready
    private(set) var profile: AccountProfile?
    private var security: SecurityState
    private var password: String?
    private var codeTries = 5
    private var resetPolls = 0

    init(existing: Account = .none, signInOutcome: SignInOutcome = .ready, signedIn: Bool = false) {
      self.existing = existing
      self.signInOutcome = signInOutcome
      security = Self.securityState(for: existing)
      password = existing == .none ? nil : Self.existingPassword
      if signedIn, existing != .none {
        profile = AccountProfile(displayName: "Maya Rahman", email: Self.existingEmail,
                                 method: existing == .passkey ? .passkey : .password)
      }
    }

    static func securityState(for account: Account) -> SecurityState {
      let thisPhone = DeviceRow(id: "ios-this", title: "This iPhone", detail: "iPhone · Active now", isThisDevice: true)
      let other = DeviceRow(id: "ios-other", title: "iPhone", detail: "Added 2 Oct", isThisDevice: false)
      switch account {
      case .passkey, .none:
        return SecurityState(
          email: existingEmail, emailVerified: true,
          passkeys: [PasskeyRow(id: "pk-1", provider: "iCloud Keychain", detail: "Added 11 Sep · Used today",
                                isThisCredential: true)],
          passwordChanged: nil, devices: [thisPhone, other], lastSignIn: "today at 09:12, here",
          phraseConfirmed: "Confirmed 11 Sep", frozen: nil)
      case .passwordOnly:
        return SecurityState(
          email: existingEmail, emailVerified: true, passkeys: [], passwordChanged: "Changed 11 Sep",
          devices: [thisPhone], lastSignIn: "today at 09:12, here", phraseConfirmed: "Confirmed 11 Sep", frozen: nil)
      }
    }

    private func pause() async {
      try? await Task.sleep(for: delay)
    }

    // MARK: Signup

    func beginSignup(code: InviteCode, linkKey: String?, email: String, displayName: String)
      async throws(AuthFailure) -> SignupTicket
    {
      await pause()
      if code.value.hasPrefix(Self.unknownInvitePrefix) { throw .notInvited }
      guard let norm = AccountFields.email(email) else { throw .badEmail }
      guard let name = AccountFields.displayName(displayName) else { throw .badName }
      codeTries = 5
      return SignupTicket(id: "signup-1", emailProven: linkKey != nil, email: norm, displayName: name,
                          startedAt: .now)
    }

    func verifySignupEmail(_ ticket: SignupTicket, code: String) async throws(AuthFailure) {
      await pause()
      guard codeTries > 0 else { throw .codeExpired }
      if code == Self.emailCode {
        if ticket.email == Self.existingEmail, existing != .none { throw .emailInUse }
        return
      }
      codeTries -= 1
      throw codeTries == 0 ? .codeExpired : .codeWrong(triesLeft: codeTries)
    }

    func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) {
      await pause()
      codeTries = 5
    }

    func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure) {
      await pause()
    }

    func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase {
      RecoveryPhrase(words: Self.phraseWords, confirmPositions: Self.confirmPositions)
    }

    func finishAccount(_ ticket: SignupTicket, credential: NewCredential, phrase: RecoveryPhrase)
      async throws(AuthFailure) -> AccountProfile
    {
      await pause()
      let p = AccountProfile(displayName: ticket.displayName, email: ticket.email, method: credential.method)
      profile = p
      existing = credential.method == .passkey ? .passkey : .passwordOnly
      security = Self.securityState(for: existing)
      security.email = ticket.email
      security.devices = [security.devices[0]]
      if case .password(let pw) = credential { password = pw }
      return p
    }

    // MARK: Sign in

    func signInWithPasskey() async throws(AuthFailure) -> SignInOutcome {
      await pause()
      guard existing == .passkey else { throw existing == .none ? .orphanedPasskey : .noCredential }
      profile = AccountProfile(displayName: "Maya Rahman", email: Self.existingEmail, method: .passkey)
      return signInOutcome
    }

    func signInWithPassword(email: String, password pw: String) async throws(AuthFailure) -> SignInOutcome {
      await pause()
      guard existing != .none, AccountFields.email(email) == Self.existingEmail, pw == password else {
        throw .wrongCredentials
      }
      profile = AccountProfile(displayName: "Maya Rahman", email: Self.existingEmail,
                               method: existing == .passkey ? .passkey : .password)
      if case .needsUnlock = signInOutcome {
        return .needsUnlock(passkeyCanUnlock: existing == .passkey)
      }
      return signInOutcome
    }

    func unlockWithPasskey() async throws(AuthFailure) {
      await pause()
      guard existing == .passkey else { throw .noCredential }
    }

    func unlockWithPhrase(_ words: [String]) async throws(AuthFailure) {
      await pause()
      guard words == Self.phraseWords else { throw .phraseMismatch }
    }

    // MARK: Forgot password

    func beginPasswordReset(email: String) async throws(AuthFailure) -> ResetTicket {
      await pause()
      guard let norm = AccountFields.email(email) else { throw .badEmail }
      codeTries = 5
      resetPolls = 0
      return ResetTicket(id: "reset-1", email: norm)
    }

    func verifyPasswordReset(_ ticket: ResetTicket, code: String) async throws(AuthFailure) -> ResetTicket {
      await pause()
      guard code == Self.emailCode else {
        codeTries -= 1
        throw codeTries <= 0 ? .codeExpired : .codeWrong(triesLeft: codeTries)
      }
      var t = ticket
      t.approvers = existing != .none && ticket.email == Self.existingEmail
      return t
    }

    func requestResetApproval(_ ticket: ResetTicket, newPassword: String) async throws(AuthFailure) -> ResetTicket {
      await pause()
      var t = ticket
      // A synthetic ephemeral key: the code shown is the real 80-bit form of it.
      t.resetCode = (try? ResetCode.text(ephemeralPublicKey: Data(repeating: 7, count: 32))) ?? "ABCDEFGHIJKLMNOP"
      password = newPassword
      return t
    }

    func pollResetApproval(_ ticket: ResetTicket) async throws(AuthFailure) -> Bool {
      await pause()
      resetPolls += 1
      if resetPolls >= 2 {
        profile = AccountProfile(displayName: "Maya Rahman", email: ticket.email,
                                 method: existing == .passkey ? .passkey : .password)
        return true
      }
      return false
    }

    // MARK: Recovery

    func beginRecovery(words: [String]) async throws(AuthFailure) -> RecoveryTicket {
      await pause()
      guard words == Self.phraseWords else { throw .noAccountForPhrase }
      codeTries = 5
      return RecoveryTicket(id: "recover-1", emailHint: "m\u{2022}\u{2022}\u{2022}@e\u{2022}\u{2022}\u{2022}.com")
    }

    func verifyRecovery(_ ticket: RecoveryTicket, code: String) async throws(AuthFailure) {
      await pause()
      guard code == Self.emailCode else {
        codeTries -= 1
        throw codeTries <= 0 ? .codeExpired : .codeWrong(triesLeft: codeTries)
      }
    }

    func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure) {
      await pause()
      if case .password(let pw) = credential {
        password = pw
        if existing == .none { existing = .passwordOnly }
      } else {
        existing = .passkey
      }
      profile = AccountProfile(displayName: "Maya Rahman", email: Self.existingEmail, method: credential.method)
    }

    // MARK: Signed in

    func securityState() async throws(AuthFailure) -> SecurityState {
      await pause()
      return security
    }

    func perform(_ action: SecurityAction, password given: String?) async throws(AuthFailure) {
      await pause()
      if security.frozen != nil, action != .unfreeze, action != .deleteAccount { throw .frozen }
      // The step-up: a passkey account asserts (always succeeds here); a password-only
      // account proves the password with this iPhone's key.
      if !security.hasPasskey {
        guard let given, given == password else { throw .stepUpFailed }
      }
      switch action {
      case .addPasskey:
        security.passkeys.append(PasskeyRow(id: "pk-\(security.passkeys.count + 1)", provider: "iCloud Keychain",
                                            detail: "Added today · Used today", isThisCredential: true))
        existing = .passkey
      case .removePasskey(let id):
        if security.passkeys.count == 1, !security.hasPassword { throw .lastAuthenticator }
        security.passkeys.removeAll { $0.id == id }
        if security.passkeys.isEmpty { existing = .passwordOnly }
      case .setPassword(let new), .changePassword(let new):
        password = new
        security.passwordChanged = "Changed today"
      case .removePassword:
        guard security.hasPasskey else { throw .lastAuthenticator }
        password = nil
        security.passwordChanged = nil
      case .removeDevice(let id):
        security.devices.removeAll { $0.id == id && !$0.isThisDevice }
      case .signOutEverywhere:
        security.devices = security.devices.filter(\.isThisDevice)
      case .freeze:
        security.frozen = FreezeInfo(by: .holder, when: "today")
      case .unfreeze:
        security.frozen = nil
      case .deleteAccount:
        profile = nil
        existing = .none
        security = Self.securityState(for: .none)
      }
    }

    func viewRecoveryPhrase() async throws(AuthFailure) -> [String] {
      await pause()
      guard security.hasPasskey else { throw .stepUpFailed }
      return Self.phraseWords
    }

    func signOut() async {
      await pause()
      profile = nil
    }

    /// Scenario hook: start frozen.
    func freezeForScenario(by: FreezeInfo.By) {
      security.frozen = FreezeInfo(by: by, when: "Sat 11 Oct at 21:20")
    }

    var frozenInfo: FreezeInfo? { security.frozen }
  }
#endif
