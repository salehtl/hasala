import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreSync
import Foundation

/// `AccountService` over CoreSync's ceremonies (spec 04 §6.2): signup (C1, C1-P), the
/// interrupted C1, sign-in (C2, C2-P, C2b, C2b-P), unlock (C2's PRF, C3), sign-out, and
/// on Sign-in & security: delete account (#41), sign out everywhere (#16), freeze (#65),
/// unfreeze (#66) and view your words (#67). The screens are the ones the mocks drive.
///
/// Not bound yet (they throw `.notInThisBuild`, whose copy says so): forgot password
/// (C9), access recovery (C4), the approving iPhone, and the passkey, password and
/// device changes on Sign-in & security — CoreSync has no ceremony for them yet.
/// TODO(WS-14): bind each as its CoreSync ceremony lands.
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
        if codeTries <= 0 || ticket.codeExpired(now: .now) { throw .codeExpired }
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

  private func outcome(_ r: SignInResult, passkeyCanUnlock: Bool) async -> SignInOutcome {
    signIn = r
    if r.restricted { return .frozen(await frozenBy(token: r.grant.session_token)) }
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
      return await outcome(r, passkeyCanUnlock: r.assertion?.prfFirst != nil)
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
      return await outcome(r, passkeyCanUnlock: false)
    } catch {
      throw Self.map(error)
    }
  }

  /// The account this iPhone is signed in to: the sign-in of this run, or after a
  /// relaunch the Keychain's session item (spec 04 §6.5: the session survives a kill).
  private var signedInUser: UserID? {
    if let u = signIn?.userID { return u }
    guard let s = try? env.secrets.session(), !s.pending_logout else { return nil }
    return UserID(s.user_id)
  }

  func unlockWithPasskey() async throws(AuthFailure) {
    do {
      let assertion: CoreAuth.RawAssertion
      if let a = signIn?.assertion, a.prfFirst != nil {
        assertion = a
      } else {
        // A password session, or a relaunch (the assertion is gone): C2's passkey login
        // with PRF replaces the session.
        let again = try await AccountSignIn.withPasskey(env, bound: nil, wantPRF: true)
        signIn = again
        guard let a = again.assertion else { throw CeremonyError.noPRF }
        assertion = a
      }
      guard let user = signIn?.userID else { throw AuthFailure.refused }
      let body = try await Enrolment.unlockWithPRF(
        env, userID: user, credentialID: assertion.credentialID, prf: assertion.prfFirst)
      defer { body.wipe() }
      enrolled = try await Enrolment.enrolWriter(
        env, userID: user, body: body, emailNorm: signIn?.emailNorm, serverSalt: signIn?.serverSalt)
      assertion.prfFirst?.wipe()
      refreshProfile()
    } catch let e as AuthFailure {
      throw e
    } catch let e as CeremonyError {
      if case .noPRF = e { throw .noCredential }
      throw Self.map(e)
    } catch {
      throw .refused
    }
  }

  func unlockWithPhrase(_ words: [String]) async throws(AuthFailure) {
    guard let user = signedInUser else { throw .refused }
    do {
      let body = try await Enrolment.unlockWithPhrase(env, userID: user, typed: words.joined(separator: " "))
      defer { body.wipe() }
      // After a relaunch the address and salt are read from `GET /account` (nil here).
      enrolled = try await Enrolment.enrolWriter(
        env, userID: user, body: body, emailNorm: signIn?.emailNorm, serverSalt: signIn?.serverSalt)
      refreshProfile()
    } catch {
      throw Self.map(error)
    }
  }

  // MARK: Relaunch with a session (spec 04 §6.5)

  /// A session and no usable keys on this iPhone after a relaunch: `Boot` alone can't
  /// tell a sign-in killed before unlock from a C1 killed before its bootstrap, so the
  /// server's `has_keys` decides (and its PRF wraps whether Face ID can unlock).
  func resumeSignedIn() async throws(AuthFailure) -> SignInOutcome {
    guard let s = try? env.secrets.session(), !s.pending_logout else { throw .refused }
    let a: LiveAccountFields
    do {
      a = try await env.client.api.call(.get, "/api/v1/account", bearer: s.token, as: LiveAccountFields.self)
    } catch {
      throw Self.map(CeremonyError.api(error))
    }
    profile = AccountProfile(
      displayName: a.display_name ?? binding?.display_name ?? "", email: a.email ?? binding?.email_norm ?? "",
      method: a.has_passkey == true ? .passkey : .password)
    if a.frozen == true || a.restricted == true { return .frozen(a.frozen_by == "operator" ? .operator : .holder) }
    guard a.has_keys == true else { return .needsKeys }
    let wraps = (try? await env.client.keyWraps(bearer: s.token).wraps.count) ?? 0
    return .needsUnlock(passkeyCanUnlock: wraps > 0)
  }

  /// C1 interrupted: the confirmed NEW phrase is published behind step-up
  /// `keys.bootstrap` (one Face ID prompt).
  func finishInterruptedSetup(phrase: RecoveryPhrase) async throws(AuthFailure) -> AccountProfile {
    guard let k = keys else { throw .refused }
    do {
      enrolled = try await AccountCreation.bootstrapInterrupted(env, keys: k)
    } catch {
      throw Self.map(error)
    }
    keys = nil
    let b = binding
    let p = AccountProfile(displayName: b?.display_name ?? profile?.displayName ?? "",
                           email: b?.email_norm ?? profile?.email ?? "", method: .passkey)
    profile = p
    return p
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
  func verifyRecovery(_ ticket: RecoveryTicket, code: String, kind: SignInMethod) async throws(AuthFailure) {
    throw .notInThisBuild
  }
  func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure) {
    throw .notInThisBuild
  }
  func pendingResetRequest() async -> PendingReset? { nil }
  func approveReset(_ request: PendingReset, code: String) async throws(AuthFailure) { throw .notInThisBuild }

  // MARK: Signed in

  /// What `GET /account` and the binding say. Passkey rows, devices and last sign-in
  /// need routes CoreSync doesn't read yet; the rows shown are this iPhone's own.
  func securityState() async throws(AuthFailure) -> SecurityState {
    guard let b = binding else { throw .refused }
    var hasPassword = profile?.method == .password
    var hasPasskey = profile?.method == .passkey
    var frozen: FreezeInfo?
    if let token = try? env.secrets.session()?.token,
      let a = try? await env.client.api.call(.get, "/api/v1/account", bearer: token, as: LiveAccountFields.self)
    {
      hasPassword = a.has_password ?? hasPassword
      hasPasskey = a.has_passkey ?? hasPasskey
      if a.frozen == true { frozen = FreezeInfo(by: a.frozen_by == "operator" ? .operator : .holder, when: nil) }
    }
    return SecurityState(
      email: b.email_norm, emailVerified: true,
      passkeys: hasPasskey
        ? [PasskeyRow(id: "this", provider: "Passkey", detail: "Signs you in with Face ID", isThisCredential: true)] : [],
      passwordChanged: hasPassword ? "Set" : nil,
      devices: [DeviceRow(id: b.writer_id, title: "This iPhone", detail: "Active now", isThisDevice: true)],
      lastSignIn: "on this iPhone", phraseConfirmed: "Confirmed at signup", frozen: frozen)
  }

  /// Who froze the account, from `GET /account` (allowed on a restricted session).
  private func frozenBy(token: String) async -> FreezeInfo.By {
    let a = try? await env.client.api.call(.get, "/api/v1/account", bearer: token, as: LiveAccountFields.self)
    return a?.frozen_by == "operator" ? .operator : .holder
  }

  func perform(_ action: SecurityAction, password: String?) async throws(AuthFailure) {
    guard let b = binding else { throw .refused }
    let factor: StepUpHelper.Factor = password.map { .device(password: $0) } ?? .passkey
    do {
      switch action {
      case .deleteAccount:
        // TODO(WS-12): the holder's Gmail stop and token revoke come first (§4.7 row 4).
        let ctx = try Enrolment.context(env, binding: b)
        try await AccountManagement.deleteAccount(env, ctx: ctx, factor: factor, binding: b)
        try? env.secrets.deleteSession()
        clearSignedIn()
      case .signOutEverywhere:
        // #16 revokes every session, this one too (`02` §9.3); keys and writers stay.
        try await guarded(.sessionLogoutAll, "/api/v1/auth/logout-all", factor: factor, binding: b, action: action)
        try? env.secrets.deleteSession()
        signIn = nil
      case .freeze:
        try await guarded(.accountFreeze, "/api/v1/account/freeze/now", factor: factor, binding: b, action: action)
      case .unfreeze:
        try await guarded(.accountUnfreeze, "/api/v1/account/unfreeze", factor: factor, binding: b, action: action)
      case .addPasskey, .removePasskey, .setPassword, .changePassword, .removePassword, .removeDevice:
        throw AuthFailure.notInThisBuild
      }
    } catch let e as AuthFailure {
      throw e
    } catch let e as CeremonyError {
      throw Self.map(e)
    } catch {
      throw .refused
    }
  }

  /// A step-up guarded `POST {"step_up"}` with an empty answer (#16, #65, #66).
  private func guarded(_ params: StepUpParams, _ path: String, factor: StepUpHelper.Factor, binding: AccountBinding,
                       action: SecurityAction) async throws(CeremonyError)
  {
    let proof = try await StepUpHelper.prove(env, params: params, factor: factor, binding: binding,
                                             reason: action.explainer)
    proof.prf?.wipe()
    let token = try bearer()
    do {
      let _: Empty = try await env.client.api.call(.post, path, json: StepUpBody(step_up: proof.stepUp), bearer: token)
    } catch {
      throw .api(error)
    }
  }

  /// `phrase.view` (#67): the passkey's PRF output opens its wrap, whose AMK opens the
  /// phrase box. Passkey accounts with a PRF wrap only (S-41).
  func viewRecoveryPhrase() async throws(AuthFailure) -> [String] {
    guard let b = binding, let user = b.userID else { throw .refused }
    do {
      let proof = try await StepUpHelper.prove(
        env, params: .phraseView, factor: .passkey, binding: b, reason: "Confirm it's you to see your 12 words")
      defer { proof.prf?.wipe() }
      guard let credentialID = proof.credentialID, proof.prf != nil else { throw CeremonyError.noPRF }
      let token = try bearer()
      let answer: PhraseViewAnswer
      do {
        answer = try await env.client.api.call(
          .post, "/api/v1/keys/phrase/view", json: StepUpBody(step_up: proof.stepUp), bearer: token)
      } catch {
        throw CeremonyError.api(error)
      }
      let keys: KeysResponse
      do { keys = try await env.client.keys(bearer: token) } catch { throw CeremonyError.api(error) }
      let body = try await Enrolment.unlockWithPRF(env, userID: user, credentialID: credentialID, prf: proof.prf)
      defer { body.wipe() }
      guard let box = try? Base64.decode(answer.phrase_box), let rk = try? Base64.decode(keys.recovery_pubkey) else {
        throw CeremonyError.badResponse("phrase box")
      }
      let entropy: SecureBytes
      do {
        entropy = try PhraseBox.open(box, amk: body.amk, userID: user, recoveryPublicKey: rk)
      } catch {
        throw CeremonyError.integrityAlarm("phrase box")
      }
      defer { entropy.wipe() }
      do { return try Phrase.words(entropy: entropy) } catch { throw CeremonyError.crypto("words") }
    } catch let e as AuthFailure {
      throw e
    } catch let e as CeremonyError {
      if case .noPRF = e { throw .notInThisBuild }
      throw Self.map(e)
    } catch {
      throw .refused
    }
  }

  private func bearer() throws(CeremonyError) -> String {
    guard let s = try? env.secrets.session(), !s.pending_logout else {
      throw .api(.refused(APIFailure(status: 401, code: "unauthorized")))
    }
    return s.token
  }

  private func clearSignedIn() {
    signIn = nil
    enrolled = nil
    profile = nil
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

/// The fields of `GET /account` (#40) the app reads, including the freeze's author,
/// which CoreAuth's `AccountInfo` doesn't carry.
nonisolated struct LiveAccountFields: Decodable, Sendable {
  var has_keys: Bool?
  var email: String?
  var display_name: String?
  var has_password: Bool?
  var has_passkey: Bool?
  var frozen: Bool?
  var frozen_by: String?
  var restricted: Bool?
}

/// `{"step_up"}`, the body of #16, #65, #66 and #67.
nonisolated struct StepUpBody: Encodable, Sendable {
  var step_up: StepUpJSON
}

/// #67's answer.
nonisolated struct PhraseViewAnswer: Decodable, Sendable {
  var phrase_box: String
}
