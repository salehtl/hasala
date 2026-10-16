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
    /// Invite codes that start with this are "not found".
    static let unknownInvitePrefix = "ZZZZ"

    enum Account: Equatable {
      case none
      case passkey
      case passwordOnly
    }

    /// The account actions the mock offers: every one, unless a scenario narrows it.
    var capabilities: AccountCapabilities = .all
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

    /// Paper's Sign-in & security boards (HB9, HNJ), synthetic: this iPhone and Maya's iPad;
    /// a passkey account also has a passkey from another Apple Account ("Work iPad").
    static func securityState(for account: Account) -> SecurityState {
      let thisPhone = DeviceRow(id: "ios-this", title: "This iPhone", detail: "iPhone 16 Pro · Dubai · Active now",
                                isThisDevice: true)
      let other = DeviceRow(id: "ios-other", title: "Maya\u{2019}s iPad", detail: "iPad Air · Dubai · 2 days ago",
                            isThisDevice: false, isTablet: true)
      switch account {
      case .passkey, .none:
        return SecurityState(
          email: existingEmail, emailVerified: true,
          passkeys: [
            PasskeyRow(id: "pk-1", provider: "iCloud Keychain", detail: "Added 11 Sep · Used today", isThisCredential: true),
            PasskeyRow(id: "pk-2", provider: "Work iPad", detail: "Other Apple Account · 2 Oct", isThisCredential: false),
          ],
          passwordChanged: nil, devices: [thisPhone, other], lastSignIn: "today at 09:12, here",
          phraseConfirmed: "Confirmed 11 Sep", frozen: nil)
      case .passwordOnly:
        return SecurityState(
          email: existingEmail, emailVerified: true, passkeys: [], passwordChanged: "Changed 3 Oct",
          devices: [thisPhone, other], lastSignIn: "today at 09:12, here", phraseConfirmed: "Confirmed 11 Sep",
          frozen: nil)
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

    func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) -> SignupTicket {
      await pause()
      codeTries = 5
      var t = ticket
      t.id += "+"
      t.startedAt = .now
      return t
    }

    func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure) {
      await pause()
    }

    func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase {
      RecoveryPhrase(words: Self.phraseWords)
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
      t.resetCode = Self.resetCode
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

    // MARK: Relaunch

    /// What `resumeSignedIn` answers (the `relaunch*` scenarios).
    var resumeOutcome: SignInOutcome = .needsUnlock(passkeyCanUnlock: false)

    func resumeSignedIn() async throws(AuthFailure) -> SignInOutcome {
      await pause()
      return resumeOutcome
    }

    func finishInterruptedSetup(phrase: RecoveryPhrase) async throws(AuthFailure) -> AccountProfile {
      await pause()
      existing = .passkey
      let p = AccountProfile(displayName: "Maya Rahman", email: Self.existingEmail, method: .passkey)
      profile = p
      return p
    }

    // MARK: Recovery

    func beginRecovery(words: [String]) async throws(AuthFailure) -> RecoveryTicket {
      await pause()
      guard words == Self.phraseWords else { throw .noAccountForPhrase }
      codeTries = 5
      return RecoveryTicket(id: "recover-1", emailHint: "m\u{2022}\u{2022}\u{2022}@e\u{2022}\u{2022}\u{2022}.com")
    }

    /// The kind the ceremony was verified with (`02` #48).
    private(set) var recoveryKind: SignInMethod?

    func verifyRecovery(_ ticket: RecoveryTicket, code: String, kind: SignInMethod) async throws(AuthFailure) {
      await pause()
      guard code == Self.emailCode else {
        codeTries -= 1
        throw codeTries <= 0 ? .codeExpired : .codeWrong(triesLeft: codeTries)
      }
      recoveryKind = kind
    }

    func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure) {
      await pause()
      // `recover/finish` refuses a kind other than the verified one (uniformly).
      guard recoveryKind == credential.method else { throw .refused }
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
      // As the live service: an operator freeze is refused before any step-up.
      if action == .unfreeze, security.frozen?.by == .operator { throw .frozenByOperator }
      try stepUp(password: given)
      if closesNextSystemSheet {
        // The system's Face ID or passkey sheet was closed after the step-up was asked for.
        closesNextSystemSheet = false
        throw .cancelled
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
        // Every session ends, this iPhone's too (`02` §9.3); devices keep their keys.
        profile = nil
      case .freeze:
        security.frozen = FreezeInfo(by: .holder, when: "today", inApp: true)
      case .unfreeze:
        security.frozen = nil
      case .deleteAccount:
        profile = nil
        existing = .none
        security = Self.securityState(for: .none)
      }
    }

    /// The step-up: a passkey account asserts (always succeeds here); a password-only
    /// account proves the password with this iPhone's key, which a sealed iPhone lacks.
    private func stepUp(password given: String?) throws(AuthFailure) {
      guard !security.hasPasskey else { return }
      if deviceKeyMissing { throw .noDeviceKey }
      guard let given, given == password else { throw .stepUpFailed }
    }

    /// Scenario hook: this iPhone has no key yet (its data is still sealed), so a password
    /// step-up can't be signed here (Paper IYT "This iPhone can't confirm yet").
    var deviceKeyMissing = false

    /// Test hook: the next change's system sheet (Face ID, or iOS's passkey sheet after a
    /// password step-up) is closed, so the change answers `.cancelled`.
    var closesNextSystemSheet = false

    // MARK: Change the email address

    private var emailChange: EmailChangeTicket?

    func beginEmailChange(password given: String?) async throws(AuthFailure) -> EmailChangeTicket {
      await pause()
      if security.frozen != nil { throw .frozen }
      try stepUp(password: given)
      let t = EmailChangeTicket(id: "email-1", currentEmail: security.email)
      emailChange = t
      return t
    }

    func sendEmailChangeCodes(_ ticket: EmailChangeTicket, to newEmail: String) async throws(AuthFailure)
      -> EmailChangeTicket
    {
      await pause()
      guard emailChange?.id == ticket.id else { throw .refused }
      guard let norm = AccountFields.email(newEmail), norm != ticket.currentEmail else { throw .badEmail }
      if norm == Self.takenEmail { throw .emailInUse }
      codeTries = 5
      var t = ticket
      t.newEmail = norm
      t.sentAt = .now
      emailChange = t
      return t
    }

    func finishEmailChange(_ ticket: EmailChangeTicket, currentCode: String, newCode: String) async throws(AuthFailure)
    {
      await pause()
      guard let t = emailChange, t.id == ticket.id, let new = t.newEmail else { throw .refused }
      guard codeTries > 0 else { throw .codeExpired }
      guard currentCode == Self.emailCode, newCode == Self.emailCode else {
        codeTries -= 1
        throw codeTries == 0 ? .codeExpired : .codeWrong(triesLeft: codeTries)
      }
      security.email = new
      if let p = profile { profile = AccountProfile(displayName: p.displayName, email: new, method: p.method) }
      emailChange = nil
    }

    /// An address that already has an account.
    static let takenEmail = "taken@example.com"

    func viewRecoveryPhrase() async throws(AuthFailure) -> [String] {
      await pause()
      guard security.hasPasskey else { throw .stepUpFailed }
      return Self.phraseWords
    }

    func signOut() async {
      await pause()
      profile = nil
    }

    /// A reset request waiting for approval (the `resetApproval` scenario).
    var pendingReset: PendingReset?
    private(set) var approvedResets: [String] = []
    /// The synthetic ephemeral key behind every mock reset code.
    static let resetKey = Data(repeating: 7, count: 32)
    static var resetCode: String { (try? ResetCode.text(ephemeralPublicKey: resetKey)) ?? "" }

    func pendingResetRequest() async -> PendingReset? {
      await pause()
      return pendingReset
    }

    func approveReset(_ request: PendingReset, code: String) async throws(AuthFailure) {
      await pause()
      guard pendingReset?.id == request.id, ResetCode.matches(code, ephemeralPublicKey: Self.resetKey) else {
        throw .codeMismatch
      }
      approvedResets.append(request.id)
      pendingReset = nil
    }

    /// Scenario hook: start frozen.
    func freezeForScenario(by: FreezeInfo.By) {
      security.frozen = FreezeInfo(by: by, when: "on Sun 11 Oct at 21:20")
    }

    var frozenInfo: FreezeInfo? { security.frozen }

    // MARK: Screen launches

    /// A Debug screen launch's step for a view that owns its model (`ScreenLaunch+SignIn`).
    var launchStep: SignInLaunchStep?

    /// The waiting step, once: the view that takes it drives its model.
    func takeLaunchStep() -> SignInLaunchStep? {
      defer { launchStep = nil }
      return launchStep
    }

    /// Takes the step if it is `step`.
    func takeLaunchStep(_ step: SignInLaunchStep) -> Bool {
      guard launchStep == step else { return false }
      launchStep = nil
      return true
    }
  }
#endif
