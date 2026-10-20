import CoreAuth
import CoreCrypto
import CoreMailbox
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import Hasala

/// The shipped view models over `LiveAccountService` and the real CoreSync ceremonies,
/// against `MiniHasalad` below (spec 04 §15.1). The relaunch cases are what review L1/L2
/// found missing: a new-iPhone sign-in killed before unlock must come back to Unlock,
/// and the unlock must work from the Keychain's session alone.
///
/// CoreSync's own FakeServer can't be linked here (linking CoreTestSupport makes Xcode
/// build HasalaCore's products dynamically, which loses the HasalaICU system library),
/// so `MiniHasalad` is a small in-app fake of `02` §7's password routes: it keeps what
/// the client sends and answers in `02`'s shapes, and checks no signatures (CoreSync's
/// FakeServer suites check those).
@MainActor
@Suite("Live account flows")
struct LiveAccountFlowTests {
  static let invite = "ABCDEFGHIJKLMNOPQRSTUVWX"
  static let password = "copper lantern quietly 42"

  struct Phone {
    let env: AccountEnvironment
    var binding: AccountBinding? { try? env.secrets.binding() }

    init(_ server: MiniHasalad, store: MemorySecretStore = MemorySecretStore(), passkeys: (any PasskeyProvider)? = nil) {
      env = AccountEnvironment(
        client: AuthClient(transport: server), secrets: Secrets(store: store, apiHost: "api.hasala.app"),
        approvalKeys: SoftDAK(), passkeys: passkeys, clock: SystemClock(), random: SystemRandom(),
        apiBase: "https://api.hasala.app", accountsDirectory: nil)
    }

    /// The same Keychain after the app was killed and launched again.
    func relaunched() -> LiveAccountService { LiveAccountService(env: env) }
  }

  func services(_ account: AccountService) -> AccountServices {
    let mailbox = MockMailbox(offersSampleData: false)
    mailbox.step = .milliseconds(1)
    return AccountServices(account: account, mailbox: mailbox, setup: MockSetupAuthoring(),
                           notifications: MockNotificationPermission())
  }

  /// Signup with a password (C1-P) through `SignupModel`; returns the confirmed words.
  func signUp(_ phone: Phone, _ server: MiniHasalad) async throws -> [String] {
    let m = SignupModel(account: phone.relaunched())
    m.inviteText = Self.invite
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    #expect(m.path.last == .verifyEmail)
    m.code = try #require(server.lastCode)
    await m.submitCode()
    #expect(m.path.last == .method)
    m.method = .password
    await m.continueWithMethod()
    m.newPassword = Self.password
    m.confirmPassword = Self.password
    m.submitPassword()
    let words = try #require(m.phrase?.words)
    m.phraseRevealed = true
    #expect(m.phraseSeen)
    await m.finish()
    #expect(m.failure == nil)
    #expect(m.path.last == .accountReady)
    return words
  }

  /// A password sign-in (C2-P, C2b-P) through `SignInModel`; returns its outcome.
  func signIn(_ phone: Phone) async -> SignInOutcome? {
    var outcome: SignInOutcome?
    let m = SignInModel(account: phone.relaunched()) { outcome = $0 }
    m.email = "maya@example.com"
    m.password = Self.password
    await m.signInWithPassword()
    return outcome
  }

  @Test func aSignInKilledBeforeUnlockComesBackToUnlock() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server)
    let words = try await signUp(a, server)
    #expect(a.binding != nil)

    // A new iPhone signs in: data sealed there.
    let b = Phone(server)
    var outcome: SignInOutcome?
    let signIn = SignInModel(account: b.relaunched()) { outcome = $0 }
    signIn.email = "maya@example.com"
    signIn.password = Self.password
    await signIn.signInWithPassword()
    #expect(outcome == .needsUnlock(passkeyCanUnlock: false))

    // Killed before unlock. Boot alone can't tell this from an interrupted signup…
    #expect(Boot.decide(Boot.gather(b.env)) == .onboardingKeys)
    let (phase, wall) = BootController.initialPhase(Boot.decide(Boot.gather(b.env)), finished: false)
    #expect(phase == .checking && wall == nil)
    // …the server's has_keys can.
    let account = b.relaunched()
    let session = AccountSession(services: services(account), phase: .checking)
    await session.resume()
    #expect(session.phase == .needsUnlock(passkeyCanUnlock: false))
    #expect(account.profile?.email == "maya@example.com")

    // The words unlock from the Keychain's session alone (no sign-in in this run).
    var opened = false
    let unlock = UnlockModel(account: account, passkeyCanUnlock: false) { opened = true }
    unlock.phraseText = words.joined(separator: " ")
    await unlock.unlockWithWords()
    #expect(unlock.failure == nil)
    #expect(unlock.unlocked)
    unlock.openApp()
    #expect(opened)
    #expect(b.binding?.user_id == a.binding?.user_id)
    #expect(b.binding?.writer_id != a.binding?.writer_id)
    #expect(Boot.decide(Boot.gather(b.env)) == .restoring)  // in-memory store: bound, never the keys step
  }

  @Test func anotherAccountsWordsDontUnlockAfterARelaunch() async throws {
    let server = MiniHasalad(invite: Self.invite)
    _ = try await signUp(Phone(server), server)
    let b = Phone(server)
    let signIn = SignInModel(account: b.relaunched()) { _ in }
    signIn.email = "maya@example.com"
    signIn.password = Self.password
    await signIn.signInWithPassword()
    let unlock = UnlockModel(account: b.relaunched(), passkeyCanUnlock: false) {}
    unlock.phraseText = MockAccountService.phraseWords.joined(separator: " ")
    await unlock.unlockWithWords()
    #expect(unlock.failure == .phraseMismatch)
    #expect(!unlock.unlocked)
  }

  /// A sign-in to a frozen account, and a relaunch after it, show who froze it and when.
  @Test func aFrozenAccountAfterARelaunchShowsWhoFrozeIt() async throws {
    let server = MiniHasalad(invite: Self.invite)
    _ = try await signUp(Phone(server), server)
    server.freezeAll(byOperator: true)
    let b = Phone(server)
    let info = FreezeInfo(by: .operator, when: "on Sun 11 Oct at 21:20")
    #expect(await signIn(b) == .frozen(info))
    let session = AccountSession(services: services(b.relaunched()), phase: .checking)
    await session.resume()
    #expect(session.phase == .frozen(info))
  }

  /// The app never sends #66 for an operator freeze (spec 04 §6.11): `frozen_by` is read
  /// first, and no step-up is asked for.
  @Test func anOperatorFreezeIsNeverSentToUnfreeze() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server)
    _ = try await signUp(a, server)
    server.freezeAll(byOperator: true)
    // The freeze revoked this iPhone's session: signed in again, it reads the freeze.
    #expect(await a.relaunched().freezeInfo() == nil)
    #expect(await signIn(a) == .frozen(FreezeInfo(by: .operator, when: "on Sun 11 Oct at 21:20")))
    let account = a.relaunched()
    #expect(await account.freezeInfo() == FreezeInfo(by: .operator, when: "on Sun 11 Oct at 21:20"))
    await #expect(throws: AuthFailure.frozenByOperator) {
      try await account.perform(.unfreeze, password: Self.password)
    }
    #expect(server.unfreezeCalls == 0)
    #expect(server.lastStepUpAction != "account.unfreeze")
  }

  /// A holder's freeze unfreezes; an operator freeze that lands between the read and #66
  /// revokes the session (as on hasalad), so this iPhone signs in again and the wall it
  /// then shows is the operator's.
  @Test func aHolderUnfreezesAndALateOperatorFreezeShowsOnTheWall() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server)
    _ = try await signUp(a, server)
    server.freezeAll(byOperator: false)
    let account = a.relaunched()
    #expect(await account.freezeInfo() == FreezeInfo(by: .holder, when: "on Sun 11 Oct at 21:20"))

    server.operatorFreezesBeforeUnfreeze = true
    let stale = AccountSession(services: services(account), phase: .frozen(FreezeInfo(by: .holder, when: nil)))
    await #expect(throws: AuthFailure.sessionEnded) { try await stale.unfreeze(password: Self.password) }
    #expect(server.unfreezeCalls == 1)
    #expect(stale.phase == .signedOut)
    #expect(try a.env.secrets.session() == nil)
    #expect(a.binding != nil)  // the data and keys stay
    let operatorFreeze = FreezeInfo(by: .operator, when: "on Sun 11 Oct at 21:20")
    let outcome = try #require(await signIn(a))
    #expect(outcome == .frozen(operatorFreeze))
    stale.signedIn(outcome)
    #expect(stale.phase == .frozen(operatorFreeze))

    server.operatorFreezesBeforeUnfreeze = false
    server.freezeAll(byOperator: false)
    let session = AccountSession(services: services(account), phase: .frozen(FreezeInfo(by: .holder, when: nil)))
    try await session.unfreeze(password: Self.password)
    #expect(session.phase == .ready)
    #expect(server.unfreezeCalls == 2)
    #expect(server.lastStepUpAction == "account.unfreeze")
    #expect(await account.freezeInfo() == nil)
  }

  @Test func offlineAtLaunchWaitsWithRetry() async throws {
    let server = MiniHasalad(invite: Self.invite)
    _ = try await signUp(Phone(server), server)
    let b = Phone(server)
    let signIn = SignInModel(account: b.relaunched()) { _ in }
    signIn.email = "maya@example.com"
    signIn.password = Self.password
    await signIn.signInWithPassword()
    server.offline = true
    let session = AccountSession(services: services(b.relaunched()), phase: .checking)
    await session.resume()
    #expect(session.phase == .checking)
    #expect(session.resumeFailure == .offline)
    server.offline = false
    await session.resume()
    #expect(session.phase == .needsUnlock(passkeyCanUnlock: false))
  }

  @Test func deleteAccountRunsOnTheLiveService() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server)
    _ = try await signUp(a, server)
    let account = a.relaunched()
    let session = AccountSession(services: services(account), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    #expect(m.state?.hasPassword == true)
    await m.request(.deleteAccount)
    #expect(m.confirming == .perform(.deleteAccount))
    m.confirmPassword = Self.password
    await m.confirm()
    #expect(m.failure == nil)
    #expect(session.phase == .signedOut)
    #expect(server.deletedAccounts == 1)
    #expect(server.lastStepUpAction == "account.delete")
    #expect(a.binding == nil)
    #expect(try a.env.secrets.session() == nil)
  }

  @Test func aPasswordAccountAddsAPasskeyFromSecurity() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server, passkeys: StubPasskeys())
    _ = try await signUp(a, server)
    let account = a.relaunched()
    let session = AccountSession(services: services(account), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    #expect(m.state?.hasPasskey == false)
    await m.request(.addPasskey)
    #expect(m.confirming == .perform(.addPasskey))
    #expect(m.confirmFactor == .password)
    m.confirmPassword = Self.password
    await m.confirm()
    #expect(m.failure == nil)
    #expect(m.confirming == nil)
    #expect(server.lastStepUpAction == "passkey.add")
    #expect(server.passkeysAdded == 1)
    #expect(server.wrapsStored == 0)
    #expect(await account.usesPasskey())
    await m.load()
    #expect(m.state?.hasPasskey == true)
  }

  @Test func welcomeBackWrapsTheNewPasskeyWithTheWords() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let words = try await signUp(Phone(server), server)
    let b = Phone(server, passkeys: StubPasskeys())
    let account = b.relaunched()
    #expect(try await account.signInWithPassword(email: "maya@example.com", password: Self.password)
      == .needsUnlock(passkeyCanUnlock: false))
    var opened = false
    let m = UnlockModel(account: account, passkeyCanUnlock: false) { opened = true }
    m.phraseText = words.joined(separator: " ")
    await m.unlockWithWords()
    #expect(m.unlocked)
    #expect(m.offersPasskey)
    m.addingPasskey = true
    m.confirmPassword = Self.password
    await m.addPasskey()
    #expect(m.failure == nil)
    #expect(!m.offersPasskey)
    #expect(server.lastStepUpAction == "passkey.add")
    #expect(server.passkeysAdded == 1)
    #expect(server.wrapsStored == 1)
    m.openApp()
    #expect(opened)
  }

  @Test func theWordsBodyGoesWhenWelcomeBackEnds() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let words = try await signUp(Phone(server), server)
    let b = Phone(server, passkeys: StubPasskeys())
    let account = b.relaunched()
    _ = try await account.signInWithPassword(email: "maya@example.com", password: Self.password)
    let m = UnlockModel(account: account, passkeyCanUnlock: false) {}
    m.phraseText = words.joined(separator: " ")
    await m.unlockWithWords()
    #expect(m.offersPasskey)
    m.openApp()
    try await account.perform(.addPasskey, password: Self.password)
    #expect(server.passkeysAdded == 1)
    #expect(server.wrapsStored == 0)
  }

  @Test func aWrongPasswordAddsNoPasskey() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server, passkeys: StubPasskeys())
    _ = try await signUp(a, server)
    let account = a.relaunched()
    await #expect(throws: AuthFailure.stepUpFailed) {
      try await account.perform(.addPasskey, password: "not my password at all")
    }
    #expect(server.passkeysAdded == 0)
    #expect(!(await account.usesPasskey()))
  }

  @Test func signOutEverywhereSignsThisIPhoneOutToo() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server)
    _ = try await signUp(a, server)
    let session = AccountSession(services: services(a.relaunched()), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    await m.request(.signOutEverywhere)
    m.confirmPassword = Self.password
    await m.confirm()
    #expect(m.failure == nil)
    #expect(server.lastStepUpAction == "session.logout_all")
    #expect(session.phase == .signedOut)
    #expect(try a.env.secrets.session() == nil)
    #expect(a.binding != nil)  // keys and writer stay (`02` §9.3)
  }

  nonisolated final class StepUpLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ line: String) { lock.withLock { _lines.append(line) } }
  }

  func mailboxStepUp(_ phone: Phone, passkey: Bool, explained: Bool, log: StepUpLog) -> LiveStepUp {
    LiveStepUp(
      env: phone.env, usesPasskey: { passkey },
      askPassword: { log.add("password: \($0)"); return nil },
      explain: { log.add("explain: \($0)"); return explained })
  }

  @Test func aPasskeyAccountIsToldWhyBeforeTheMailboxStepUp() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server)
    _ = try await signUp(a, server)
    let log = StepUpLog()
    await #expect(throws: MailboxStepUpError.unavailable) {
      try await mailboxStepUp(a, passkey: true, explained: true, log: log)
        .proof(kind: "mailbox.link", payloadHash: Data(repeating: 7, count: 32))
    }
    #expect(log.lines == ["explain: Confirm it's you to connect this mailbox to Hasala"])
    #expect(server.lastStepUpAction == "mailbox.link")
  }

  @Test func aPasskeyAccountThatSaysNoIsNeverAsked() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server)
    _ = try await signUp(a, server)
    let before = server.lastStepUpAction
    let log = StepUpLog()
    await #expect(throws: MailboxStepUpError.cancelled) {
      try await mailboxStepUp(a, passkey: true, explained: false, log: log)
        .proof(kind: "mailbox.unlink", payloadHash: nil)
    }
    #expect(log.lines == ["explain: Confirm it's you to disconnect this mailbox"])
    #expect(server.lastStepUpAction == before)
  }

  @Test func aPasswordAccountIsAskedForItsPasswordWithTheReason() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let a = Phone(server)
    _ = try await signUp(a, server)
    let log = StepUpLog()
    await #expect(throws: MailboxStepUpError.cancelled) {
      try await mailboxStepUp(a, passkey: false, explained: true, log: log)
        .proof(kind: "mailbox.link", payloadHash: Data(repeating: 7, count: 32))
    }
    #expect(log.lines == ["password: Confirm it's you to connect this mailbox to Hasala"])
    #expect(server.lastStepUpAction == "mailbox.link")
  }
}

// MARK: - The in-app fake

/// A software approval key (the Secure Enclave isn't in the simulator): P-256 with the
/// SE key's byte formats.
nonisolated final class SoftDAK: ApprovalKeySigner, Sendable {
  private let keys = Mutex<[String: P256.Signing.PrivateKey]>([:])

  func create(userID: UserID, writerID: WriterID) async throws(ApprovalKeyError) -> Data {
    let k = P256.Signing.PrivateKey()
    keys.withLock { $0[writerID.string] = k }
    return k.publicKey.x963Representation
  }

  func publicKeyX963(userID: UserID, writerID: WriterID) throws(ApprovalKeyError) -> Data {
    guard let k = keys.withLock({ $0[writerID.string] }) else { throw .missing }
    return k.publicKey.x963Representation
  }

  func sign(_ message: Data, userID: UserID, writerID: WriterID, reason: String) async throws(ApprovalKeyError) -> Data {
    guard let k = keys.withLock({ $0[writerID.string] }), let sig = try? k.signature(for: message) else {
      throw .missing
    }
    return sig.rawRepresentation
  }
}

/// `02` §7's password-account routes in memory, in `02`'s JSON shapes.
nonisolated final class StubPasskeys: PasskeyProvider, @unchecked Sendable {
  func register(_ options: CreationOptions, prfSalt: Data?) async throws(PasskeyError) -> RawRegistration {
    let id = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let clientData = Data(#"{"type":"webauthn.create","challenge":"\#(Base64.encodeURL(options.challenge))"}"#.utf8)
    return RawRegistration(
      credentialID: id, rawClientDataJSON: clientData, rawAttestationObject: Data([0xa0]),
      prfFirst: prfSalt.map { _ in SecureBytes(copying: Data((0..<32).map { _ in UInt8.random(in: 0...255) })) })
  }

  func assert(challenge: Data, allowCredentialIDs: [Data], prfSalt: Data?) async throws(PasskeyError) -> RawAssertion {
    throw .noCredential
  }
}

nonisolated final class MiniHasalad: Transport, @unchecked Sendable {
  struct User {
    var id: String
    var email: String
    var name: String
    var verifierHash: Data
    var keys: [String: Any]
    var writers: [[String: Any]] = []
    var frozenBy: String?
    var freezeTriggerAt: String?
    var deleted = false
    var passkeys: [String] = []
    var wraps: [[String: Any]] = []
  }

  struct State {
    var invite: String
    var signups: [String: (user: String, email: String, name: String, nonce: Data, code: String)] = [:]
    var users: [String: User] = [:]
    var sessions: [String: (user: String, writer: String?, revoked: Bool)] = [:]
    var logins: [String: (email: String, nonce: Data)] = [:]
    var writerNonces: Set<Data> = []
    var lastCode: String?
    var offline = false
    var deleted = 0
    var lastStepUpAction: String?
    var addCeremonies: [String: String] = [:]
    var reviewAccounts = false
    /// #66 calls, refused ones included.
    var unfreezeCalls = 0
    /// The operator freezes the account just before #66 runs (a stale `frozen_by`), which
    /// revokes the session #66 was sent with.
    var operatorFreezesBeforeUnfreeze = false
  }

  private let lock = NSLock()
  private var _state: State

  init(invite: String) { _state = State(invite: invite) }

  /// Every read and write of the state runs under the lock.
  private var state: Locked { Locked(owner: self) }

  struct Locked {
    let owner: MiniHasalad
    func withLock<T>(_ body: (inout State) -> T) -> T {
      owner.lock.lock()
      defer { owner.lock.unlock() }
      return body(&owner._state)
    }
  }

  var lastCode: String? { state.withLock { $0.lastCode } }
  var deletedAccounts: Int { state.withLock { $0.deleted } }
  var lastStepUpAction: String? { state.withLock { $0.lastStepUpAction } }
  var passkeysAdded: Int { state.withLock { $0.users.values.reduce(0) { $0 + $1.passkeys.count } } }
  var wrapsStored: Int { state.withLock { $0.users.values.reduce(0) { $0 + $1.wraps.count } } }
  var unfreezeCalls: Int { state.withLock { $0.unfreezeCalls } }
  var operatorFreezesBeforeUnfreeze: Bool {
    get { state.withLock { $0.operatorFreezesBeforeUnfreeze } }
    set { state.withLock { $0.operatorFreezesBeforeUnfreeze = newValue } }
  }
  var offline: Bool {
    get { state.withLock { $0.offline } }
    set { state.withLock { $0.offline = newValue } }
  }

  /// Every account answers `review_account: true` on #40 (an App Review invite).
  var reviewAccounts: Bool {
    get { state.withLock { $0.reviewAccounts } }
    set { state.withLock { $0.reviewAccounts = newValue } }
  }

  /// Freezes every account, triggered at 21:20 on Sun 11 Oct 2026 in the app's clock. As
  /// on hasalad, the operator's freeze revokes every session (`OperatorFreeze`); the
  /// holder's stands for "Freeze my account" on this iPhone (#65), which keeps them here.
  func freezeAll(byOperator: Bool) {
    state.withLock { s in
      for k in s.users.keys {
        s.users[k]?.frozenBy = byOperator ? "operator" : "holder"
        s.users[k]?.freezeTriggerAt = "2026-10-11T17:20:05.123456Z"
      }
      if byOperator { for t in s.sessions.keys { s.sessions[t]?.revoked = true } }
    }
  }

  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    if offline { throw .offline(.notConnectedToInternet) }
    let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    return state.withLock { s in handle(&s, "\(request.method.rawValue) \(request.path)", body, request.bearer) }
  }

  private func handle(_ s: inout State, _ route: String, _ b: [String: Any], _ bearer: String?) -> APIResponse {
    switch route {
    case "GET /api/v1/meta": return ok(["log_generation": 1, "min_ios_build": 0])
    case "POST /api/v1/auth/signup/begin":
      guard (b["invite_code"] as? String) == s.invite, let email = b["email"] as? String else {
        return error(403, "not_invited")
      }
      let id = token(), n = bytes(32), user = UUID().uuidString.lowercased()
      s.signups[id] = (user, email, b["display_name"] as? String ?? "", n, "123456")
      s.lastCode = "123456"
      return ok([
        "signup_id": id, "user_id": user, "email_proven": false, "salt": Base64.encode(salt(email)),
        "nonce": Base64.encode(n), "expires_at": "2026-10-12T00:30:00Z",
      ])
    case "POST /api/v1/auth/signup/verify":
      guard let id = b["signup_id"] as? String, s.signups[id]?.code == b["code"] as? String else {
        return error(403, "code_rejected")
      }
      return APIResponse(status: 204)
    case "POST /api/v1/auth/password/register":
      guard let id = b["signup_id"] as? String, let c = s.signups.removeValue(forKey: id),
        let v = (b["verifier"] as? String).flatMap({ try? Base64.decode($0) }), let boot = b["bootstrap"] as? [String: Any],
        let w = boot["writer"] as? [String: Any], let wid = w["writer_id"] as? String
      else { return error(400, "bad_request") }
      var u = User(
        id: c.user, email: c.email, name: c.name, verifierHash: Data(SHA256.hash(data: v)),
        keys: [
          "format_version": 1, "amk_commitment": boot["amk_commitment"] ?? "", "authority_pubkey": boot["authority_pubkey"] ?? "",
          "recovery_pubkey": boot["recovery_pubkey"] ?? "", "recovery_wrap": boot["recovery_wrap"] ?? "", "current_epoch": 1,
        ])
      u.writers.append(writerRow(wid, w["pubkey"], w["dak_pubkey"], boot["nonce"], boot["registration_sig"], id: 1))
      s.users[c.user] = u
      let t = token()
      s.sessions[t] = (c.user, wid, false)
      return grant(t, u, writer: wid, status: 201)
    case "POST /api/v1/auth/password/login/begin":
      guard let email = (b["email"] as? String).flatMap({ try? EmailNorm.normalize($0) }) else { return error(400, "bad_email") }
      let id = token(), n = bytes(32)
      s.logins[id] = (email, n)
      return ok(["ceremony_id": id, "salt": Base64.encode(salt(email)), "nonce": Base64.encode(n)])
    case "POST /api/v1/auth/password/login/finish":
      guard let id = b["ceremony_id"] as? String, let c = s.logins.removeValue(forKey: id),
        let v = (b["verifier"] as? String).flatMap({ try? Base64.decode($0) }),
        let u = s.users.values.first(where: { $0.email == c.email && !$0.deleted }),
        u.verifierHash == Data(SHA256.hash(data: v))
      else { return error(403, "password_rejected") }
      let writer = (b["device"] as? [String: Any])?["writer_id"] as? String
      let t = token()
      s.sessions[t] = (u.id, writer, false)
      return grant(t, u, writer: writer)
    case "POST /api/v1/auth/recover/begin":
      // #7 for words whose recovery key no account here has (this fake keeps none).
      return error(404, "not_found")
    default: break
    }
    guard let bearer, let sess = s.sessions[bearer], !sess.revoked else { return error(401, "unauthorized") }
    guard var u = s.users[sess.user], !u.deleted else { return error(410, "account_deleted") }
    // A frozen account reaches only `02` §9.8's list.
    let whileFrozen = [
      "GET /api/v1/account", "POST /api/v1/auth/logout", "POST /api/v1/auth/step-up/begin",
      "POST /api/v1/account/unfreeze",
    ]
    if u.frozenBy != nil, !whileFrozen.contains(route) {
      return error(403, "account_frozen")
    }
    switch route {
    case "GET /api/v1/auth/session":
      return ok(["user_id": u.id, "writer_id": opt(sess.writer), "restricted": u.frozenBy != nil])
    case "GET /api/v1/account":
      return ok([
        "user_id": u.id, "status": "active", "has_keys": true, "email": u.email, "display_name": u.name,
        "has_password": true, "password_salt": Base64.encode(salt(u.email)), "has_passkey": !u.passkeys.isEmpty,
        "frozen": u.frozenBy != nil, "frozen_by": opt(u.frozenBy), "freeze_trigger_at": opt(u.freezeTriggerAt),
        "restricted": u.frozenBy != nil,
        "review_account": s.reviewAccounts,
      ])
    case "GET /api/v1/keys": return ok(u.keys)
    case "GET /api/v1/keys/wraps": return ok(["wraps": u.wraps])
    case "POST /api/v1/writers/challenge":
      let n = bytes(32)
      s.writerNonces.insert(n)
      return ok(["nonce": Base64.encode(n)])
    case "POST /api/v1/writers/register":
      guard let wid = b["writer_id"] as? String, let n = (b["nonce"] as? String).flatMap({ try? Base64.decode($0) }),
        s.writerNonces.remove(n) != nil
      else { return error(400, "bad_signature") }
      u.writers.append(writerRow(wid, b["pubkey"], b["dak_pubkey"], b["nonce"], b["sig"], id: u.writers.count + 1))
      s.users[u.id] = u
      s.sessions[bearer]?.writer = wid
      return ok(["writer_id": wid], status: 201)
    case "GET /api/v1/key-history":
      return ok(["entries": u.writers.map { $0.filter { $0.key != "current" } }])
    case "GET /api/v1/writers":
      return ok([
        "writers": u.writers.map {
          [
            "writer_id": $0["writer_id"] ?? "", "alg": "ed25519", "pubkey": $0["pubkey"] ?? "",
            "dak_pubkey": $0["dak_pubkey"] ?? "", "current": ($0["writer_id"] as? String) == sess.writer,
          ]
        }
      ])
    case "POST /api/v1/auth/step-up/begin":
      guard let action = b["action"] as? String, let ph = (b["params_hash"] as? String).flatMap({ try? Hex.decode($0) })
      else { return error(400, "bad_request") }
      let n = bytes(32)
      guard let c = try? StepUp.challenge(nonce: n, action: action, paramsHash: ph) else { return error(400, "bad_request") }
      s.lastStepUpAction = action
      return ok(["nonce": Base64.encodeURL(n), "challenge": Base64.encodeURL(c)])
    case "POST /api/v1/auth/passkey/add/begin":
      guard let su = b["step_up"] as? [String: Any], let proof = su["proof"] as? [String: Any],
        s.lastStepUpAction == "passkey.add", sess.writer != nil
      else { return error(403, "step_up_required") }
      if proof["kind"] as? String == "device" {
        guard let v = (proof["verifier"] as? String).flatMap({ try? Base64.decode($0) }),
          Data(SHA256.hash(data: v)) == u.verifierHash
        else { return error(403, "step_up_failed") }
      }
      let id = token()
      s.addCeremonies[id] = u.id
      return ok([
        "ceremony_id": id,
        "options": [
          "publicKey": [
            "challenge": Base64.encodeURL(bytes(32)), "rp": ["id": "hasala.app", "name": "Hasala"],
            "user": ["id": Base64.encodeURL(bytes(32)), "name": "Hasala", "displayName": "Hasala"],
            "excludeCredentials": u.passkeys.map { ["type": "public-key", "id": $0] },
          ]
        ],
      ])
    case "POST /api/v1/auth/passkey/add/finish":
      guard let id = b["ceremony_id"] as? String, s.addCeremonies.removeValue(forKey: id) == u.id,
        let credential = b["credential"] as? [String: Any], let rawID = credential["rawId"] as? String,
        b["dwk_sig"] is String
      else { return error(403, "passkey_rejected") }
      s.users[u.id]?.passkeys.append(rawID)
      if let w = b["prf_wrap"] as? [String: Any] { s.users[u.id]?.wraps.append(w) }
      return ok(["credential_id": rawID], status: 201)
    case "POST /api/v1/auth/logout":
      s.sessions[bearer]?.revoked = true
      return APIResponse(status: 204)
    case "POST /api/v1/auth/logout-all":
      guard b["step_up"] != nil else { return error(403, "step_up_required") }
      for (t, x) in s.sessions where x.user == u.id { s.sessions[t]?.revoked = true }
      return APIResponse(status: 204)
    case "POST /api/v1/account/unfreeze":
      // #66: refused while the operator froze the account (nothing consumed).
      guard b["step_up"] != nil else { return error(403, "step_up_required") }
      s.unfreezeCalls += 1
      if s.operatorFreezesBeforeUnfreeze {
        // The operator's freeze revoked this session before #66 arrived.
        s.users[u.id]?.frozenBy = "operator"
        for (t, x) in s.sessions where x.user == u.id { s.sessions[t]?.revoked = true }
        return error(401, "unauthorized")
      }
      guard let by = s.users[u.id]?.frozenBy else { return error(400, "bad_request") }
      if by == "operator" { return error(403, "account_frozen") }
      s.users[u.id]?.frozenBy = nil
      s.users[u.id]?.freezeTriggerAt = nil
      return APIResponse(status: 204)
    case "DELETE /api/v1/account":
      guard b["step_up"] != nil, b["sig"] != nil else { return error(400, "bad_request") }
      s.users[u.id]?.deleted = true
      s.deleted += 1
      return APIResponse(status: 204)
    default:
      return error(404, "not_found")
    }
  }

  private func writerRow(_ id: String, _ pub: Any?, _ dak: Any?, _ nonce: Any?, _ sig: Any?, id n: Int) -> [String: Any] {
    [
      "id": String(n), "writer_id": id, "alg": "ed25519", "pubkey": pub ?? "", "dak_pubkey": dak ?? "",
      "event": "registered", "authorized_by": "authority", "nonce": nonce ?? "", "signature": sig ?? "",
    ]
  }

  private func grant(_ t: String, _ u: User, writer: String?, status: Int = 200) -> APIResponse {
    ok([
      "session_token": t, "user_id": u.id, "expires_at": "2027-01-09T00:00:00Z", "writer_id": opt(writer),
      "has_keys": true, "restricted": u.frozenBy != nil,
    ], status: status)
  }

  private func salt(_ email: String) -> Data { Data(SHA256.hash(data: Data("s_srv|\(email)".utf8))) }
  private func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
  private func token() -> String { Base64.encodeURL(bytes(32)) }

  private func ok(_ v: [String: Any], status: Int = 200) -> APIResponse {
    let data = (try? JSONSerialization.data(withJSONObject: v)) ?? Data()
    return APIResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
  }

  /// JSON null for a missing value.
  private func opt(_ v: String?) -> Any { v ?? NSNull() }

  private func error(_ status: Int, _ code: String) -> APIResponse {
    APIResponse(status: status, body: Data(#"{"error":"\#(code)","detail":""}"#.utf8))
  }
}
