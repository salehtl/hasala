import CoreAuth
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
    #expect(!a.capabilities.contains(.resetPassword) && !a.capabilities.contains(.recoverAccess))
    #expect(a.capabilities.contains(.deleteAccount) && a.capabilities.contains(.removeThisIPhone))
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
}
