import Foundation
import Observation

/// The account half of the boot state machine (spec 04 §6.5) as the root view sees it:
/// which wall, flow or the main app is on screen. The live build derives `phase` from the
/// Keychain, the store and `GET /auth/session`; Debug scenarios set it directly.
@MainActor
@Observable
final class AccountSession {
  enum Phase: Equatable {
    /// No account on this iPhone: the welcome stories and sign-in.
    case signedOut
    /// A session from before a relaunch and no keys here: asking the server what's left
    /// (`resume()`); a failure to reach it stays here with Retry.
    case checking
    /// Signed in with keys here; setup resumes at the derived step (§6.6).
    case onboarding
    /// Signed in, data sealed here (§6.10).
    case needsUnlock(passkeyCanUnlock: Bool)
    /// Signed in without keys anywhere (C1 interrupted after register/finish): make a new
    /// phrase and publish the keys.
    case needsKeys
    /// The account is frozen (§6.11).
    case frozen(FreezeInfo)
    /// The app.
    case ready
  }

  let services: AccountServices
  private(set) var phase: Phase
  /// "Leave it frozen": the app opens with the frozen banner. The freeze is kept as it
  /// was (who froze it decides whether Unfreeze is offered, spec 04 §6.11).
  private(set) var leftFrozen: FreezeInfo?
  private var setupBehindWall = false
  private var behindWall: Phase { setupBehindWall ? .onboarding : .ready }
  /// An invite link that arrived while signed out (§13.5), for the invite screen.
  var pendingInvite: InviteLink?
  /// A toast for links that can't act now ("You already have an account").
  var notice: String?
  static let hasAccountNotice = "You already have an account"
  /// The signed-in account is the App Review demo account (`review_account` on
  /// `GET /account`), so its ledger is sample data. Set by the runtime once the account
  /// is known; false until then and after signing out.
  var reviewAccount = false

  init(services: AccountServices, phase: Phase) {
    self.services = services
    self.phase = phase
  }

  var account: AccountService { services.account }

  /// The account actions this build can carry out (the service's); screens hide the rest.
  var capabilities: AccountCapabilities { account.capabilities }

  /// After a sign-in ceremony.
  func signedIn(_ outcome: SignInOutcome) {
    switch outcome {
    case .ready: phase = .ready
    case .needsUnlock(let p): phase = .needsUnlock(passkeyCanUnlock: p)
    case .needsKeys: phase = .needsKeys
    case .frozen(let info): phase = .frozen(info)
    }
  }

  /// Why the last `resume()` couldn't decide (offline, rate limited).
  private(set) var resumeFailure: AuthFailure?

  /// `.checking`: the server says whether this account's keys exist (§6.5).
  private(set) var resuming = false

  func resume() async {
    guard phase == .checking, !resuming else { return }
    resuming = true
    defer { resuming = false }
    do {
      let outcome = try await account.resumeSignedIn()
      guard phase == .checking else { return }
      resumeFailure = nil
      signedIn(outcome)
    } catch .offline, .rateLimited {
      guard phase == .checking else { return }
      resumeFailure = .offline
    } catch {
      guard phase == .checking else { return }
      // The session is gone or refused: sign in again.
      resumeFailure = nil
      await account.signOut()
      signedOut()
    }
  }

  /// After the account and keys exist (C1/C1-P complete): setup continues at the bank.
  func accountCreated() {
    switch phase {
    case .signedOut, .needsKeys: phase = .onboarding
    default: break
    }
  }

  /// After unlocking on a new iPhone: setup steps that are per-device still run.
  func unlocked() {
    guard case .needsUnlock = phase else { return }
    phase = .ready
  }

  func setupFinished() {
    switch phase {
    case .onboarding:
      setupBehindWall = false
      phase = .ready
    case .frozen: setupBehindWall = false
    default: break
    }
  }

  func froze(_ info: FreezeInfo) {
    if case .onboarding = phase { setupBehindWall = true }
    leftFrozen = nil
    phase = .frozen(info)
  }

  /// A run found the account frozen; `info` is `GET /account`'s answer, nil when the
  /// server couldn't be asked. After "Leave it frozen" the banner stays, with the answer;
  /// otherwise the wall shows. No answer keeps the freeze as known (an operator's never
  /// becomes the holder's), and is the holder's when nothing is known.
  func runFoundFrozen(_ info: FreezeInfo?) {
    if let left = leftFrozen {
      leftFrozen = info ?? left
      return
    }
    var known: FreezeInfo?
    if case .frozen(let shown) = phase { known = shown }
    froze(info ?? known ?? FreezeInfo(by: .holder, when: nil))
  }

  var canLeaveFrozen: Bool { account.keysOnThisIPhone }

  var deleteWaitsForUnfreeze: Bool { leftFrozen != nil }

  func leaveFrozen() {
    guard canLeaveFrozen, case .frozen(let info) = phase else { return }
    leftFrozen = info
    phase = behindWall
  }

  /// The wall again, from the banner, with the freeze as it was.
  func showFrozenWall() {
    guard let info = leftFrozen else { return }
    froze(info)
  }

  func unfroze() {
    switch phase {
    case .frozen: phase = behindWall
    case .onboarding, .ready: break
    default: return
    }
    leftFrozen = nil
  }

  /// The server says the operator froze the account: the wall, or the banner after "Leave
  /// it frozen", shows the operator's freeze from now on (no Unfreeze, spec 04 §6.11).
  func learnedOperatorFreeze() {
    if case .frozen(let info) = phase {
      phase = .frozen(FreezeInfo(by: .operator, when: info.when))
    } else if let info = leftFrozen {
      leftFrozen = FreezeInfo(by: .operator, when: info.when)
    }
  }

  /// "Unfreeze" on the wall: #66 behind its step-up, then the app. The service refuses an
  /// operator freeze before any step-up (`.frozenByOperator`); the wall then shows it. A
  /// session the server ended (an operator freeze revokes them all) signs in again.
  func unfreeze(password: String?) async throws(AuthFailure) {
    do {
      try await account.perform(.unfreeze, password: password)
    } catch .frozenByOperator {
      learnedOperatorFreeze()
      throw .frozenByOperator
    } catch .sessionEnded {
      signedOut()
      throw .sessionEnded
    }
    guard account.keysOnThisIPhone else {
      guard case .frozen = phase else { return }
      leftFrozen = nil
      setupBehindWall = false
      phase = .checking
      await resume()
      return
    }
    unfroze()
  }

  func signOut() async {
    await account.signOut()
    signedOut()
  }

  func signedOut() {
    if phase != .signedOut { account.sessionEnded() }
    leftFrozen = nil
    setupBehindWall = false
    reviewAccount = false
    phase = .signedOut
  }

  /// A universal link (`https://hasala.app/i/<CODE>#<KEY>`).
  func open(_ url: URL) {
    guard let link = InviteLink.parse(url) else { return }
    if phase == .signedOut {
      pendingInvite = link
    } else {
      notice = Self.hasAccountNotice
    }
  }
}

/// The services the account and setup flows talk to, built once in the composition root.
@MainActor
struct AccountServices {
  var account: AccountService
  var mailbox: MailboxConnecting
  var setup: SetupAuthoring
  var notifications: NotificationPermissionAsking
  /// Onboarding step 0 (spec 04 §6.6): whether this iPhone has a passcode.
  var hasPasscode: @MainActor () -> Bool = { DevicePasscode.isSet() }
  var cloudSort: CloudSortOffering?
  var unseenPhrase: any UnseenPhraseNoting = InMemoryUnseenPhrase()
  var manualEntry = ManualEntryChoice()
  var bankTexts: (any BankTextsConnecting)?
}
