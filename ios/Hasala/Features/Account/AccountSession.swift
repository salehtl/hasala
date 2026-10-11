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
    /// Signed in with keys here; setup resumes at the derived step (§6.6).
    case onboarding(OnboardingStep)
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
  /// "Leave it frozen": the app opens with the frozen banner.
  private(set) var leftFrozen = false
  /// An invite link that arrived while signed out (§13.5), for the invite screen.
  var pendingInvite: InviteLink?
  /// A toast for links that can't act now ("You already have an account").
  var notice: String?

  init(services: AccountServices, phase: Phase) {
    self.services = services
    self.phase = phase
  }

  var account: AccountService { services.account }

  /// After a sign-in ceremony.
  func signedIn(_ outcome: SignInOutcome) {
    switch outcome {
    case .ready: phase = .ready
    case .needsUnlock(let p): phase = .needsUnlock(passkeyCanUnlock: p)
    case .needsKeys: phase = .needsKeys
    case .frozen: phase = .frozen(FreezeInfo(by: .holder, when: nil))
    }
  }

  /// After the account and keys exist (C1/C1-P complete): setup continues at the bank.
  func accountCreated() { phase = .onboarding(.bank) }

  /// After unlocking on a new iPhone: setup steps that are per-device still run.
  func unlocked() { phase = .ready }

  func setupFinished() { phase = .ready }

  func froze(_ info: FreezeInfo) {
    leftFrozen = false
    phase = .frozen(info)
  }

  func leaveFrozen() {
    leftFrozen = true
    phase = .ready
  }

  func unfroze() {
    leftFrozen = false
    phase = .ready
  }

  func signedOut() {
    leftFrozen = false
    phase = .signedOut
  }

  /// A universal link (`https://hasala.app/i/<CODE>#<KEY>`).
  func open(_ url: URL) {
    guard let link = InviteLink.parse(url) else { return }
    if phase == .signedOut {
      pendingInvite = link
    } else {
      notice = "You already have an account"
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
}
