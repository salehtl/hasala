import CoreAuth
import CoreMailbox
import CoreStore
import CoreSync
import CoreTime
import Foundation
import Testing

@testable import Hasala

/// The live service over CoreSync's real ceremonies, against `MiniHasalad` (the in-app
/// fake of `02` §7's password routes, see `LiveAccountFlowTests`), and its failure
/// mapping (spec 04 §6.1.5): each server refusal and ceremony failure lands on the copy
/// block the screens show.
///
/// CoreTestSupport's `FakeServer` can't be linked into this target: Xcode then builds
/// HasalaCore's products dynamically and drops the HasalaICU system library, so the
/// signature-checking scenarios (writer revocation, sync) stay in HasalaCore's own suites.
@MainActor
@Suite("Live account service")
struct LiveAccountServiceTests {
  static let invite = "ABCDEFGHIJKLMNOPQRSTUVWX"
  static let email = "maya@example.com"
  static let password = "copper lantern quietly 42"

  /// One iPhone: its own Keychain and approval key, the shared server.
  static func phone(_ server: MiniHasalad) -> AccountEnvironment {
    AccountEnvironment(
      client: AuthClient(transport: server), secrets: Secrets(store: MemorySecretStore(), apiHost: "api.hasala.app"),
      approvalKeys: SoftDAK(), passkeys: nil, clock: SystemClock(), random: SystemRandom(),
      apiBase: "https://api.hasala.app", accountsDirectory: nil)
  }

  /// C1-P through the service: invite, email code, the words, one `password/register`.
  static func signUp(_ server: MiniHasalad, _ env: AccountEnvironment) async throws -> (LiveAccountService, [String]) {
    let a = LiveAccountService(env: env)
    let ticket = try await a.beginSignup(
      code: try #require(InviteCode(invite)), linkKey: nil, email: email, displayName: "Maya Rahman")
    #expect(!ticket.emailProven)
    try await a.verifySignupEmail(ticket, code: try #require(server.lastCode))
    let phrase = try a.makeRecoveryPhrase()
    let profile = try await a.finishAccount(ticket, credential: .password(password), phrase: phrase)
    #expect(profile == AccountProfile(displayName: "Maya Rahman", email: email, method: .password))
    return (a, phrase.words)
  }

  @Test func theBetaOffersWhatItCarriesOut() {
    let a = LiveAccountService(env: Self.phone(MiniHasalad(invite: Self.invite)))
    #expect(a.capabilities == .beta)
    #expect(!a.capabilities.contains(.resetPassword) && !a.capabilities.contains(.recoverWithPassword))
    // Recovery to a new passkey: someone who lost theirs gets back in and can delete.
    #expect(a.capabilities.contains(.recoverAccess))
    #expect(a.capabilities.contains(.deleteAccount))
    // Sign-in & security has no "Remove this iPhone" row, so the beta doesn't claim it.
    #expect(!a.capabilities.contains(.removeThisIPhone))
  }

  /// Recovery's refusals land on their copy: words no account has (`recover/begin` 404),
  /// a ceremony this service didn't start, and a new password (not in this build) refused
  /// before anything is sent, so the emailed code isn't spent.
  @Test func recoveryRefusalsSayWhy() async throws {
    let a = LiveAccountService(env: Self.phone(MiniHasalad(invite: Self.invite)))
    await #expect(throws: AuthFailure.noAccountForPhrase) {
      _ = try await a.beginRecovery(words: MockAccountService.phraseWords)
    }
    await #expect(throws: AuthFailure.badPhrase("Every word is real, but together they aren't a Hasala phrase. Two words may be swapped.")) {
      _ = try await a.beginRecovery(words: Array(repeating: "abandon", count: 12))
    }
    let ticket = RecoveryTicket(id: "not-mine", emailHint: "")
    await #expect(throws: AuthFailure.refused) { try await a.verifyRecovery(ticket, code: "123456", kind: .passkey) }
    await #expect(throws: AuthFailure.refused) { try await a.finishRecovery(ticket, credential: .passkey) }
  }

  @Test func aPasswordAccountOnTwoIPhonesThenDeleted() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let envA = Self.phone(server)
    let (a, words) = try await Self.signUp(server, envA)
    let bindingA = try #require(try envA.secrets.binding())
    #expect(a.enrolled?.writerID.string == bindingA.writer_id)

    // GET /account carries the review flag the runtime reads (#40); a relaunch learns
    // the sign-in method from it.
    server.reviewAccounts = true
    let token = try #require(try envA.secrets.session()).token
    let info = try await envA.client.account(bearer: token)
    #expect(info.review_account == true)
    let relaunched = LiveAccountService(env: envA)
    relaunched.noteAccount(info)
    #expect(relaunched.profile == AccountProfile(displayName: "Maya Rahman", email: Self.email, method: .password))

    // C2-P on a new iPhone: signed in, data sealed; C3 with the words enrols it.
    let envB = Self.phone(server)
    let b = LiveAccountService(env: envB)
    #expect(try await b.signInWithPassword(email: Self.email, password: Self.password) == .needsUnlock(passkeyCanUnlock: false))
    await #expect(throws: AuthFailure.phraseMismatch) {
      try await b.unlockWithPhrase(MockAccountService.phraseWords)
    }
    try await b.unlockWithPhrase(words)
    let bindingB = try #require(try envB.secrets.binding())
    #expect(bindingB.user_id == bindingA.user_id && bindingB.writer_id != bindingA.writer_id)

    // "Remove this iPhone" needs the open account's engine; without one it refuses.
    await #expect(throws: AuthFailure.refused) {
      try await b.perform(.removeDevice(id: bindingB.writer_id), password: Self.password)
    }
    #expect(try envB.secrets.binding() != nil)

    // Delete on A: step-up account.delete (password + approval key), #41, then a wipe,
    // and the runtime is told this iPhone left.
    var left = 0
    a.hooks = LiveAccountHooks(left: { left += 1 })
    try await a.perform(.deleteAccount, password: Self.password)
    #expect(server.lastStepUpAction == "account.delete")
    #expect(server.deletedAccounts == 1)
    #expect(try envA.secrets.binding() == nil)
    #expect(try envA.secrets.session() == nil)
    #expect(left == 1)
  }

  /// gmail-sync: the deleted account's Gmail grant is ended at Google (users.stop, then the
  /// revoke) BEFORE this iPhone leaves the account for Welcome, from the token read before
  /// the wipe. That ending acts on the Google account and the app's client id, so a new
  /// account linking the same Gmail here next must not get there first.
  @Test func aDeletionEndsItsGmailGrantBeforeItLeaves() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let env = Self.phone(server)
    let (a, _) = try await Self.signUp(server, env)
    let user = try #require(try env.secrets.binding()?.userID)
    try SecretsMailRefreshTokenStore(secrets: env.secrets, userID: user, provider: .gmail).write("synthetic-refresh-a")

    let log = MailGrantEndsTests.Log()
    a.grantEnds = MailGrantEnds()
    a.endGrant = { held, stopWatch in
      try? await Task.sleep(for: .milliseconds(50))
      let what = held.grants.map { "\($0.provider.rawValue):\($0.refreshToken)" }.joined(separator: ",")
      log.add("end \(what) stopWatch=\(stopWatch)")
    }
    a.hooks = LiveAccountHooks(left: { log.add("left") })
    try await a.perform(.deleteAccount, password: Self.password)

    #expect(log.all == ["end gmail:synthetic-refresh-a stopWatch=true", "left"])
    // Nothing of the account's mailbox stays here for the next account.
    #expect(try SecretsMailRefreshTokenStore(secrets: env.secrets, userID: user, provider: .gmail).read() == nil)
    #expect(MailboxLane.heldGrant(secrets: env.secrets, userID: user) == nil)
  }

  @Test func signingInAgainOnABoundIPhoneOpensStraightAway() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let env = Self.phone(server)
    let (a, _) = try await Self.signUp(server, env)
    var left = 0
    a.hooks = LiveAccountHooks(left: { left += 1 })
    await a.signOut()
    #expect(left == 1)
    #expect(try env.secrets.session() == nil)
    #expect(try env.secrets.binding() != nil)  // local data stays (S-26)
    // C2b-P: the bound writer signs the login nonce; the keys are here.
    let again = LiveAccountService(env: env)
    #expect(try await again.signInWithPassword(email: Self.email, password: Self.password) == .ready)
  }

  /// One account per iPhone: a signup, or a sign-in to another address, while this
  /// iPhone holds an account's data opens the "Remove this iPhone's data" wall and
  /// leaves the binding (and the first account's keys) alone.
  @Test func aBoundIPhoneAsksToRemoveItsDataBeforeAnotherAccount() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let env = Self.phone(server)
    let (a, _) = try await Self.signUp(server, env)
    await a.signOut()
    let binding = try #require(try env.secrets.binding())

    let again = LiveAccountService(env: env)
    var walls: [String?] = []
    again.hooks = LiveAccountHooks(otherAccountHere: { walls.append($0) })
    await #expect(throws: AuthFailure.cancelled) {
      _ = try await again.beginSignup(
        code: try #require(InviteCode(Self.invite)), linkKey: nil, email: "omar@example.com", displayName: "Omar")
    }
    await #expect(throws: AuthFailure.cancelled) {
      _ = try await again.signInWithPassword(email: "omar@example.com", password: Self.password)
    }
    #expect(walls == [Self.email, Self.email])
    #expect(try env.secrets.binding() == binding)
    // The bound account's own address (any case) signs in again (C2b-P).
    #expect(try await again.signInWithPassword(email: "Maya@Example.com", password: Self.password) == .ready)
    #expect(walls.count == 2)
  }

  /// §4.7 row 1: an offline sign-out keeps the session item marked `pending_logout`; the
  /// logout is retried later, and the item goes once the server confirms.
  @Test func anOfflineSignOutIsFinishedLater() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let env = Self.phone(server)
    let (a, _) = try await Self.signUp(server, env)
    let token = try #require(try env.secrets.session()).token
    server.offline = true
    await a.signOut()
    #expect(try env.secrets.session()?.pending_logout == true)
    #expect(await LiveAccountService.retryPendingLogout(env) == token)  // still offline
    #expect(try env.secrets.session()?.pending_logout == true)
    server.offline = false
    #expect(await LiveAccountService.retryPendingLogout(env) == nil)
    #expect(try env.secrets.session() == nil)
    await #expect(throws: (any Error).self) { _ = try await env.client.session(bearer: token) }
  }

  @Test func aSignInFinishesAPendingSignOutFirst() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let env = Self.phone(server)
    let (a, _) = try await Self.signUp(server, env)
    let old = try #require(try env.secrets.session()).token
    server.offline = true
    await a.signOut()
    server.offline = false
    let again = LiveAccountService(env: env)
    #expect(try await again.signInWithPassword(email: Self.email, password: Self.password) == .ready)
    let new = try #require(try env.secrets.session())
    #expect(new.token != old && !new.pending_logout)
    await #expect(throws: (any Error).self) { _ = try await env.client.session(bearer: old) }
  }

  /// After a relaunch the binding doesn't say how the account signs in: the step-up asks
  /// `GET /account` rather than assume a passkey.
  @Test func aRelaunchAsksTheServerHowTheAccountSignsIn() async throws {
    let server = MiniHasalad(invite: Self.invite)
    let env = Self.phone(server)
    _ = try await Self.signUp(server, env)
    let relaunched = LiveAccountService(env: env)
    relaunched.loadProfile()
    #expect(relaunched.profile?.method == .passkey)  // the binding's guess
    #expect(await relaunched.usesPasskey() == false)
    #expect(relaunched.profile?.method == .password)
  }

  static func refused(_ status: Int, _ code: String) -> CeremonyError {
    .api(.refused(APIFailure(status: status, code: code)))
  }

  @Test(arguments: [
    (403, "not_invited", AuthFailure.notInvited),
    (400, "bad_name", .badName),
    (400, "bad_email", .badEmail),
    (403, "password_rejected", .wrongCredentials),
    (409, "email_in_use", .emailInUse),
    (403, "code_rejected", .codeExpired),
    (409, "last_authenticator", .lastAuthenticator),
    (403, "account_frozen", .frozen),
    (403, "step_up_failed", .stepUpFailed),
    (429, "rate_limited", .rateLimited),
    (503, "unavailable", .offline),
    (403, "passkey_rejected", .refused),
  ])
  func refusalsMapToTheirCopy(_ status: Int, _ code: String, _ want: AuthFailure) {
    #expect(LiveAccountService.map(Self.refused(status, code)) == want)
  }

  @Test func ceremonyFailuresMapToTheirCopy() {
    #expect(LiveAccountService.map(.passkey(.cancelled)) == .cancelled)
    #expect(LiveAccountService.map(.passkey(.noCredential)) == .noCredential)
    #expect(LiveAccountService.map(.passkey(.unsupported)) == .unsupported)
    #expect(LiveAccountService.map(.notThisAccountsPhrase) == .phraseMismatch)
    #expect(LiveAccountService.map(.challengeMismatch) == .integrity)
    #expect(LiveAccountService.map(.integrityAlarm("keys")) == .integrity)
    #expect(LiveAccountService.map(.api(.transport(.offline(.notConnectedToInternet)))) == .offline)
    #expect(LiveAccountService.map(.noPRF) == .noCredential)
  }

  /// "View your 12 words" with a passkey that has no PRF says why, not "not in this build".
  @Test func aPasskeyWithoutPRFSaysItCantShowTheWords() throws {
    let m = try #require(AuthFailure.passkeyCantShowPhrase.message)
    #expect(m.contains("12 words") && !m.contains("build"))
    #expect(AuthFailure.passkeyCantShowPhrase != .notInThisBuild)
  }

  /// `GET /account`'s freeze: who froze it, and the trigger in the app's +04:00 clock.
  @Test func theFreezeIsReadFromTheAccount() {
    func fields(frozen: Bool, by: String?, at: String? = nil, restricted: Bool = false) -> LiveAccountFields {
      LiveAccountFields(frozen: frozen, freeze_trigger_at: at, frozen_by: by, restricted: restricted)
    }
    #expect(LiveAccountService.freeze(fields(frozen: false, by: nil)) == nil)
    #expect(LiveAccountService.freeze(fields(frozen: true, by: "operator")) == FreezeInfo(by: .operator, when: nil))
    #expect(LiveAccountService.freeze(fields(frozen: true, by: "holder")) == FreezeInfo(by: .holder, when: nil))
    // A restricted session reads as frozen even before `frozen` says so; unknown is the holder's.
    #expect(LiveAccountService.freeze(fields(frozen: false, by: nil, restricted: true))?.by == .holder)
    #expect(
      LiveAccountService.freeze(fields(frozen: true, by: "holder", at: "2026-10-11T17:20:05.123456Z"))?.when
        == "on Sun 11 Oct at 21:20")
    #expect(LiveAccountService.freezeTime("2026-10-11T22:30:00Z") == "on Mon 12 Oct at 02:30")
    #expect(LiveAccountService.freezeTime("not a time") == nil)
    #expect(LiveAccountService.freezeTime(nil) == nil)
  }
}
