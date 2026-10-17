import Foundation
import Testing

@testable import Hasala

/// What the account, setup and mailbox suites share (B7.4): the mock services, the typed
/// invite code, and a mock whose phrase the test chooses. Each suite conforms to
/// `AccountSuite` and calls `services(_:sample:)` and `Self.code` as one suite did before.
@MainActor
protocol AccountSuite {}

extension AccountSuite {
  static var code: String { "ABCDEFGHIJKLMNOPQRSTUVWX" }

  func services(_ account: MockAccountService, sample: Bool = false) -> AccountServices {
    let a = account
    a.delay = .zero
    let mailbox = MockMailbox(offersSampleData: sample)
    mailbox.step = .milliseconds(1)
    mailbox.connectDelay = .zero
    return AccountServices(account: a, mailbox: mailbox, setup: MockSetupAuthoring(),
                           notifications: MockNotificationPermission())
  }

  /// "Tap to show your words": what lets "I've written them down" publish.
  func showPhrase(_ m: SignupModel) {
    m.phraseRevealed = true
  }
}

/// A mock whose phrase is chosen by the test.
@MainActor
final class StubPhraseAccount: AccountService {
  let mock = MockAccountService()
  let phrase: RecoveryPhrase
  init(phrase: RecoveryPhrase) { self.phrase = phrase }

  func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase { phrase }

  var profile: AccountProfile? { mock.profile }
  func beginSignup(code: InviteCode, linkKey: String?, email: String, displayName: String)
    async throws(AuthFailure) -> SignupTicket
  { try await mock.beginSignup(code: code, linkKey: linkKey, email: email, displayName: displayName) }
  func verifySignupEmail(_ ticket: SignupTicket, code: String) async throws(AuthFailure) {
    try await mock.verifySignupEmail(ticket, code: code)
  }
  func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) -> SignupTicket {
    try await mock.resendSignupCode(ticket)
  }
  func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure) { try await mock.registerPasskey(ticket) }
  func finishAccount(_ ticket: SignupTicket, credential: NewCredential, phrase: RecoveryPhrase)
    async throws(AuthFailure) -> AccountProfile
  { try await mock.finishAccount(ticket, credential: credential, phrase: phrase) }
  func signInWithPasskey() async throws(AuthFailure) -> SignInOutcome { try await mock.signInWithPasskey() }
  func signInWithPassword(email: String, password: String) async throws(AuthFailure) -> SignInOutcome {
    try await mock.signInWithPassword(email: email, password: password)
  }
  func unlockWithPasskey() async throws(AuthFailure) { try await mock.unlockWithPasskey() }
  func unlockWithPhrase(_ words: [String]) async throws(AuthFailure) { try await mock.unlockWithPhrase(words) }
  func resumeSignedIn() async throws(AuthFailure) -> SignInOutcome { try await mock.resumeSignedIn() }
  func finishInterruptedSetup(phrase: RecoveryPhrase) async throws(AuthFailure) -> AccountProfile {
    try await mock.finishInterruptedSetup(phrase: phrase)
  }
  func beginPasswordReset(email: String) async throws(AuthFailure) -> ResetTicket {
    try await mock.beginPasswordReset(email: email)
  }
  func verifyPasswordReset(_ ticket: ResetTicket, code: String) async throws(AuthFailure) -> ResetTicket {
    try await mock.verifyPasswordReset(ticket, code: code)
  }
  func requestResetApproval(_ ticket: ResetTicket, newPassword: String) async throws(AuthFailure) -> ResetTicket {
    try await mock.requestResetApproval(ticket, newPassword: newPassword)
  }
  func pollResetApproval(_ ticket: ResetTicket) async throws(AuthFailure) -> Bool {
    try await mock.pollResetApproval(ticket)
  }
  func beginRecovery(words: [String]) async throws(AuthFailure) -> RecoveryTicket {
    try await mock.beginRecovery(words: words)
  }
  func verifyRecovery(_ ticket: RecoveryTicket, code: String, kind: SignInMethod) async throws(AuthFailure) {
    try await mock.verifyRecovery(ticket, code: code, kind: kind)
  }
  func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure) {
    try await mock.finishRecovery(ticket, credential: credential)
  }
  func securityState() async throws(AuthFailure) -> SecurityState { try await mock.securityState() }
  func perform(_ action: SecurityAction, password: String?) async throws(AuthFailure) {
    try await mock.perform(action, password: password)
  }
  func viewRecoveryPhrase() async throws(AuthFailure) -> [String] { try await mock.viewRecoveryPhrase() }
  func signOut() async { await mock.signOut() }
  func pendingResetRequest() async -> PendingReset? { await mock.pendingResetRequest() }
  func approveReset(_ request: PendingReset, code: String) async throws(AuthFailure) {
    try await mock.approveReset(request, code: code)
  }
}

extension FreezeInfo {
  func with(when: String?) -> FreezeInfo { FreezeInfo(by: by, when: when) }
}
