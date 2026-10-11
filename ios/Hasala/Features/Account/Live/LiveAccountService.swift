import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreSync
import Foundation

/// `AccountService` over CoreSync's ceremonies (spec 04 §6.2): signup (C1, C1-P),
/// sign-in (C2, C2-P, C2b, C2b-P), unlock (C2's PRF, C3) and sign-out run for real
/// against hasalad. The screens are the same ones the mocks drive.
///
/// Not bound yet (they throw `.notInThisBuild`, whose copy says so): forgot password
/// (C9), access recovery (C4), the approving iPhone, and the Sign-in & security changes
/// other than sign out — CoreSync has no ceremony for them yet. TODO(WS-14): bind each
/// as its CoreSync ceremony lands.
@MainActor
final class LiveAccountService: AccountService {
  let env: AccountEnvironment
  private(set) var profile: AccountProfile?
  /// The enrolled account once this iPhone holds keys (sync starts from it).
  private(set) var enrolled: EnrolledAccount?

  private var signup: Signup?
  private var keys: NewAccountKeys?
  private var registered: RegisteredPasskey?
  private var signIn: SignInResult?

  init(env: AccountEnvironment) {
    self.env = env
    if let b = try? env.secrets.binding() {
      profile = AccountProfile(displayName: b.display_name ?? "", email: b.email_norm, method: .passkey)
    }
  }

  private var binding: AccountBinding? { try? env.secrets.binding() }

  // MARK: Signup

  func beginSignup(code: InviteCode, linkKey: String?, email: String, displayName: String)
    async throws(AuthFailure) -> SignupTicket
  {
    do {
      let s = try await AccountCreation.beginSignup(
        env, inviteCode: code.value, email: email, displayName: displayName, inviteLinkKey: linkKey)
      signup = s
      inviteCode = code.value
      codeTries = 5
      keys?.wipe()
      keys = nil
      registered = nil
      return SignupTicket(id: s.id, emailProven: s.emailProven, email: s.emailNorm, displayName: s.displayName,
                          startedAt: .now)
    } catch {
      throw Self.map(error)
    }
  }

  /// The app's own count of wrong tries for the current code (spec 04 §6.1.4: the server
  /// answers every failure the same; the app picks the words).
  private var codeTries = 5

  func verifySignupEmail(_ ticket: SignupTicket, code: String) async throws(AuthFailure) {
    guard let s = signup, s.id == ticket.id else { throw .refused }
    do {
      try await AccountCreation.verifySignup(env, s, code: code)
      codeTries = 5
    } catch {
      if error.failureClass == .codeRejected {
        codeTries -= 1
        if codeTries <= 0 || ticket.isExpired(now: .now) { throw .codeExpired }
        throw .codeWrong(triesLeft: codeTries)
      }
      throw Self.map(error)
    }
  }

  /// The invite of the current signup, for "Resend code" (memory only; never logged).
  private var inviteCode: String?

  func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) -> SignupTicket {
    guard let code = inviteCode, let invite = InviteCode(code) else { throw .refused }
    // The link key is not sent again: a resend means the address is confirmed by code.
    return try await beginSignup(code: invite, linkKey: nil, email: ticket.email, displayName: ticket.displayName)
  }

  private func freshKeys() throws(AuthFailure) -> NewAccountKeys {
    if let keys { return keys }
    do {
      let k = try NewAccountKeys.generate(random: env.random)
      keys = k
      return k
    } catch {
      throw Self.map(error)
    }
  }

  func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure) {
    guard let s = signup, s.id == ticket.id else { throw .refused }
    let k = try freshKeys()
    do {
      registered = try await AccountCreation.registerPasskey(env, signup: s, keys: k)
    } catch {
      throw Self.map(error)
    }
  }

  func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase {
    let k = try freshKeys()
    do {
      return RecoveryPhrase(words: try k.words(), confirmPositions: try Phrase.confirmationPositions(random: env.random))
    } catch {
      throw .unsupported
    }
  }

  func finishAccount(_ ticket: SignupTicket, credential: NewCredential, phrase: RecoveryPhrase)
    async throws(AuthFailure) -> AccountProfile
  {
    guard let s = signup, s.id == ticket.id, let k = keys else { throw .refused }
    do {
      switch credential {
      case .passkey:
        guard let r = registered else { throw AuthFailure.refused }
        enrolled = try await AccountCreation.bootstrapPasskey(env, registered: r, keys: k)
        r.prf?.wipe()
      case .password(let pw):
        enrolled = try await AccountCreation.createWithPassword(env, signup: s, password: pw, keys: k)
      }
    } catch let e as AuthFailure {
      throw e
    } catch let e as CeremonyError {
      throw Self.map(e)
    } catch {
      throw .refused
    }
    keys = nil
    registered = nil
    signup = nil
    let p = AccountProfile(displayName: s.displayName, email: s.emailNorm, method: credential.method)
    profile = p
    return p
  }

  // MARK: Sign in

  private func outcome(_ r: SignInResult, passkeyCanUnlock: Bool) -> SignInOutcome {
    signIn = r
    if r.restricted { return .frozen }
    if !r.hasKeys { return .needsKeys }
    // A bound iPhone whose keys are here opens straight away.
    if let b = binding, b.user_id == r.grant.user_id,
      let u = b.userID, (try? env.secrets.epochKey(userID: u, epoch: b.key_epoch)) != nil
    {
      return .ready
    }
    return .needsUnlock(passkeyCanUnlock: passkeyCanUnlock)
  }

  func signInWithPasskey() async throws(AuthFailure) -> SignInOutcome {
    do {
      let r = try await AccountSignIn.withPasskey(env, bound: binding, wantPRF: true)
      profile = AccountProfile(displayName: binding?.display_name ?? "", email: binding?.email_norm ?? "",
                               method: .passkey)
      return outcome(r, passkeyCanUnlock: r.assertion?.prfFirst != nil)
    } catch {
      if error.failureClass == .rejected, binding == nil { throw .orphanedPasskey }
      throw Self.map(error)
    }
  }

  func signInWithPassword(email: String, password: String) async throws(AuthFailure) -> SignInOutcome {
    do {
      let r = try await AccountSignIn.withPassword(env, email: email, password: password, bound: binding)
      profile = AccountProfile(displayName: binding?.display_name ?? "", email: r.emailNorm ?? email,
                               method: .password)
      // TODO(WS-14): offer the passkey unlock when GET /keys/wraps lists a PRF wrap (K34).
      return outcome(r, passkeyCanUnlock: false)
    } catch {
      throw Self.map(error)
    }
  }

  func unlockWithPasskey() async throws(AuthFailure) {
    guard let r = signIn, let user = r.userID else { throw .refused }
    do {
      let assertion: CoreAuth.RawAssertion
      if let a = r.assertion, a.prfFirst != nil {
        assertion = a
      } else {
        // A password session: C2's passkey login with PRF replaces it.
        let again = try await AccountSignIn.withPasskey(env, bound: nil, wantPRF: true)
        signIn = again
        guard let a = again.assertion else { throw CeremonyError.noPRF }
        assertion = a
      }
      let body = try await Enrolment.unlockWithPRF(
        env, userID: user, credentialID: assertion.credentialID, prf: assertion.prfFirst)
      defer { body.wipe() }
      enrolled = try await Enrolment.enrolWriter(
        env, userID: user, body: body, emailNorm: signIn?.emailNorm, serverSalt: signIn?.serverSalt)
      assertion.prfFirst?.wipe()
      refreshProfile()
    } catch let e as CeremonyError {
      if case .noPRF = e { throw .noCredential }
      throw Self.map(e)
    } catch {
      throw .refused
    }
  }

  func unlockWithPhrase(_ words: [String]) async throws(AuthFailure) {
    guard let r = signIn, let user = r.userID else { throw .refused }
    do {
      let body = try await Enrolment.unlockWithPhrase(env, userID: user, typed: words.joined(separator: " "))
      defer { body.wipe() }
      enrolled = try await Enrolment.enrolWriter(
        env, userID: user, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
      refreshProfile()
    } catch {
      throw Self.map(error)
    }
  }

  private func refreshProfile() {
    guard let b = binding else { return }
    profile = AccountProfile(displayName: b.display_name ?? "", email: b.email_norm, method: profile?.method ?? .passkey)
  }

  // MARK: Not bound yet (CoreSync has no ceremony for these)

  func beginPasswordReset(email: String) async throws(AuthFailure) -> ResetTicket { throw .notInThisBuild }
  func verifyPasswordReset(_ ticket: ResetTicket, code: String) async throws(AuthFailure) -> ResetTicket {
    throw .notInThisBuild
  }
  func requestResetApproval(_ ticket: ResetTicket, newPassword: String) async throws(AuthFailure) -> ResetTicket {
    throw .notInThisBuild
  }
  func pollResetApproval(_ ticket: ResetTicket) async throws(AuthFailure) -> Bool { throw .notInThisBuild }
  func beginRecovery(words: [String]) async throws(AuthFailure) -> RecoveryTicket { throw .notInThisBuild }
  func verifyRecovery(_ ticket: RecoveryTicket, code: String) async throws(AuthFailure) { throw .notInThisBuild }
  func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure) {
    throw .notInThisBuild
  }
  func pendingResetRequest() async -> PendingReset? { nil }
  func approveReset(_ request: PendingReset, code: String) async throws(AuthFailure) { throw .notInThisBuild }
  func viewRecoveryPhrase() async throws(AuthFailure) -> [String] { throw .notInThisBuild }

  // MARK: Signed in

  /// What `GET /account` and the binding say. Passkey rows, devices and last sign-in
  /// need routes CoreSync doesn't read yet; the rows shown are this iPhone's own.
  func securityState() async throws(AuthFailure) -> SecurityState {
    guard let b = binding else { throw .refused }
    var hasPassword = profile?.method == .password
    var hasPasskey = profile?.method == .passkey
    if let token = try? env.secrets.session()?.token, let a = try? await env.client.account(bearer: token) {
      hasPassword = a.has_password ?? hasPassword
      hasPasskey = a.has_passkey ?? hasPasskey
    }
    return SecurityState(
      email: b.email_norm, emailVerified: true,
      passkeys: hasPasskey
        ? [PasskeyRow(id: "this", provider: "Passkey", detail: "Signs you in with Face ID", isThisCredential: true)] : [],
      passwordChanged: hasPassword ? "Set" : nil,
      devices: [DeviceRow(id: b.writer_id, title: "This iPhone", detail: "Active now", isThisDevice: true)],
      lastSignIn: "on this iPhone", phraseConfirmed: "Confirmed at signup", frozen: nil)
  }

  func perform(_ action: SecurityAction, password: String?) async throws(AuthFailure) {
    throw .notInThisBuild
  }

  func signOut() async {
    await AccountSignIn.signOut(env)
    signIn = nil
  }

  // MARK: Failures

  static func map(_ e: CeremonyError) -> AuthFailure {
    switch e {
    case .notThisAccountsPhrase: return .phraseMismatch
    case .badPhrase: return .badPhrase("Every word is real, but together they aren't a Hasala phrase. Two words may be swapped.")
    case .badInviteCode: return .notInvited
    case .noPRF: return .noCredential
    case .integrityAlarm, .challengeMismatch: return .integrity
    default: break
    }
    switch e.failureClass {
    case .cancelled: return .cancelled
    case .unsupported: return .unsupported
    case .noCredential: return .noCredential
    case .notInvited: return .notInvited
    case .badName: return .badName
    case .badEmail: return .badEmail
    case .rejected: return .refused
    case .wrongCredentials: return .wrongCredentials
    case .recoveryRefused, .resetRefused: return .refused
    case .emailInUse: return .emailInUse
    case .codeRejected: return .codeExpired
    case .lastAuthenticator: return .lastAuthenticator
    case .frozen: return .frozen
    case .stepUpFailed: return .stepUpFailed
    case .noDeviceKey: return .noDeviceKey
    case .rateLimited: return .rateLimited
    case .offline, .unavailable: return .offline
    case .integrity: return .integrity
    case .notApproved, .other: return .refused
    }
  }
}
