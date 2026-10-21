import Foundation
import Observation

/// Everything onboarding remembers, for the life of the process (plan B3; owner
/// requirement 4): the welcome stories' page, signup and sign-in as typed, setup's draft
/// and progress, and the replacement phrase of an interrupted signup. Anything done in
/// onboarding (a connected mailbox, the salary, payday, the plan, the banks, the
/// notification choice, every typed account field) stays through Back and Forward, a
/// re-made gate, a passcode wall, a launch view and a wall overlay, until the process ends
/// or the account it describes is gone (`phaseChanged`).
///
/// One per process: the live `BootController` makes it with its services, the Debug
/// `MockGraph` with the mock's; `AccountRootView` passes it down. No onboarding model is
/// made in a `body` or a view's `init`.
@MainActor
@Observable
final class OnboardingStore {
  let services: AccountServices
  /// The gate's current session (the live gate replaces it once, at boot).
  let session: () -> AccountSession
  /// Signed out: join, the phrase, and the signed-out stack's path. Made once; made
  /// again only when the account it described is gone.
  private(set) var signup: SignupModel
  /// Signed out: sign in, forgot password, recover. Made like `signup`.
  private(set) var signIn: SignInModel
  /// The welcome pager's page.
  var storyPage = 0
  /// Setup after the account: made on the first `.onboarding` phase, then kept.
  /// (Not observed: it is made while the gate's body runs.)
  @ObservationIgnored private(set) var setup: SetupModel?
  /// C1 interrupted: the replacement phrase, made once (not on every re-render).
  @ObservationIgnored private(set) var replacement: SignupModel?
  @ObservationIgnored private var finish: FinishSetupModel?
  /// The facts setup was last brought in line with.
  @ObservationIgnored private var reconciledFacts: OnboardingStep.Facts?
  @ObservationIgnored private var lastPhase: AccountSession.Phase?

  init(services: AccountServices, session: @escaping () -> AccountSession) {
    self.services = services
    self.session = session
    signup = SignupModel(account: services.account)
    signIn = Self.signInModel(services.account, session)
  }

  private static func signInModel(_ account: AccountService, _ session: @escaping () -> AccountSession) -> SignInModel {
    SignInModel(account: account) { outcome in session().signedIn(outcome) }
  }

  /// The one setup model, made on first use, then brought in line with what the account
  /// holds whenever the gate's facts change (a relaunch, a runtime that opened again).
  func setupModel(displayName: String, facts: OnboardingStep.Facts) -> SetupModel {
    if let setup {
      if !displayName.isEmpty, setup.displayName != displayName { setup.displayName = displayName }
      if reconciledFacts != facts { reconcile(setup, facts) }
      return setup
    }
    let session = self.session
    let made = SetupModel(services: services, displayName: displayName, facts: facts) { session().setupFinished() }
    setup = made
    reconcile(made, facts)
    return made
  }

  private func reconcile(_ model: SetupModel, _ facts: OnboardingStep.Facts) {
    reconciledFacts = facts
    model.reconcile(facts: facts, banks: services.mailbox.chosenBanks())
  }

  func finishSetupModel() -> FinishSetupModel {
    if let finish { return finish }
    let made = FinishSetupModel(services: services)
    finish = made
    return made
  }

  /// The replacement phrase's model (`.needsKeys`): one, its phrase made once.
  func replacementModel() -> SignupModel {
    if let replacement { return replacement }
    let made = SignupModel(account: services.account)
    made.startReplacement()
    replacement = made
    return made
  }

  /// Called by `AccountRootView` on every phase change (and with `old` nil when it
  /// appears). Signing out after any signed-in phase (sign out, erase, a wipe, the session
  /// ended) drops every draft: the account it described is gone (plan B3.4). Nothing else
  /// does: not a wall, the passcode wall, the launch view, a failed sign-in or Back.
  func phaseChanged(from old: AccountSession.Phase?, to new: AccountSession.Phase) {
    let previous = old ?? lastPhase
    lastPhase = new
    if new == .signedOut, let previous, previous != .signedOut { forgetAccountDrafts() }
    if new != .signedOut, new != .checking { signIn.forgetRecovery() }
  }

  /// Sign-out, erase, wipe: every draft goes; the stories' page stays.
  func forgetAccountDrafts() {
    setup = nil
    finish = nil
    reconciledFacts = nil
    replacement = nil
    signup = SignupModel(account: services.account)
    signIn = Self.signInModel(services.account, session)
  }
}
