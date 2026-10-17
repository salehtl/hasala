import HasalaModels
import Observation

/// One connect attempt, for setup's email step, Add a mailbox and Sign in again (plan
/// B4.3): it runs the provider's sign-in through `MailboxConnecting` and says how it went.
///
/// How a failure shows (spec 06 §5, plan P3 work 1):
/// - A closed Google sign-in is not an error, as before: the screen stays as it was.
/// - A closed or declined Microsoft sign-in, and an admin's approval, get their own screen
///   (`errorScreen`: "Outlook isn't connected.", "Your organisation needs to approve
///   Hasala."); setup pushes it, the profile swaps it in.
/// - Everything else is a line on the screen that tried (`inlineMessage`): "<address> is
///   already connected.", offline, another iPhone, the live lane's content-free copy.
@MainActor
@Observable
final class MailConnectCoordinator {
  enum Context: Equatable {
    /// Setup's step, with its indicator ("2 of 4").
    case setup(stepOf: (Int, Int)?)
    /// Profile › Bank alerts › Add a mailbox.
    case addMailbox
    /// A new sign-in for this mailbox.
    case signInAgain(mailboxID: String)

    static func == (a: Context, b: Context) -> Bool {
      switch (a, b) {
      case (.setup(let x), .setup(let y)): x?.0 == y?.0 && x?.1 == y?.1
      case (.addMailbox, .addMailbox): true
      case (.signInAgain(let x), .signInAgain(let y)): x == y
      default: false
      }
    }
  }

  enum Outcome: Equatable {
    case connected(mailboxID: String)
    case failed(MailConnectFailure)
  }

  let context: Context
  @ObservationIgnored let mailbox: MailboxConnecting
  private(set) var busy = false
  private(set) var outcome: Outcome?
  /// The provider of the last attempt (the error screens name it).
  private(set) var provider: MailProviderKind?

  init(mailbox: MailboxConnecting, context: Context) {
    self.mailbox = mailbox
    self.context = context
  }

  /// Runs the sign-in (or the sign-in again). A second tap while one runs does nothing.
  /// `replacing`: the person confirmed that this connect replaces the account's link to
  /// another provider ("Change your email?"; one link held, `.replace`).
  func connect(_ provider: MailProviderKind, replacing: Bool = false) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    outcome = nil
    self.provider = provider
    do {
      if case .signInAgain(let id) = context {
        try await mailbox.signInAgain(id)
        outcome = .connected(mailboxID: id)
      } else {
        outcome = .connected(mailboxID: try await mailbox.connect(provider, replacing: replacing))
      }
    } catch .cancelled where provider == .gmail {
      // The person closed Google's sheet: nothing to say (today's behaviour).
      outcome = nil
    } catch {
      outcome = .failed(error)
    }
  }

  /// The mailbox a connect of `provider` here would replace, which the screen confirms
  /// first; nil for a new sign-in, which replaces nothing.
  func replaced(by provider: MailProviderKind) -> MailboxSnapshot? {
    if case .signInAgain = context { return nil }
    return mailbox.replaced(by: provider)
  }

  /// Back to before the attempt ("Try again", "Choose a different email").
  func reset() {
    outcome = nil
  }

  // MARK: What the screens show

  /// The mailbox this attempt connected, or, in setup, the one setup connected before
  /// (Back from the first scan): the connect screen then shows it and "Continue", never a
  /// second sign-in (plan B3.2 rule 2). Read live from the service, so a relaunch that
  /// finds the lane linked shows the same.
  func connectedMailbox(_ provider: MailProviderKind) -> MailboxSnapshot? {
    let live = mailbox.mailboxes.filter { $0.state != .disconnected }
    switch outcome {
    case .connected(let id)?:
      // Another provider's attempt (a host that kept this coordinator for a different
      // screen) says nothing about this one.
      guard self.provider == nil || self.provider == provider else { return nil }
      if let m = live.first(where: { $0.id == id }) { return m.provider == provider ? m : nil }
      return MailboxSnapshot(id: id, provider: provider, address: provider.appName, state: .syncing, meta: "Checking now")
    case .failed?:
      return nil
    case nil:
      // Only setup carries a connect over from before this screen: in the profile a second
      // mailbox of the same provider is a real new connect.
      guard case .setup = context else { return nil }
      return live.first { $0.provider == provider }
    }
  }

  /// The failure that has a screen of its own; nil when there is none, or it shows inline.
  var errorScreen: MailConnectFailure? {
    guard case .failed(let failure)? = outcome, Self.hasScreen(failure, provider: provider ?? .gmail) else {
      return nil
    }
    return failure
  }

  /// The line the screen that tried shows; nil when nothing failed or the failure has its
  /// own screen.
  var inlineMessage: String? {
    guard case .failed(let failure)? = outcome, let provider, !Self.hasScreen(failure, provider: provider) else {
      return nil
    }
    return failure.message(for: provider)
  }

  /// Which failures get a screen: an admin's approval for any provider, and a sign-in that
  /// didn't finish for any provider but Google (whose closed sheet says nothing).
  static func hasScreen(_ failure: MailConnectFailure, provider: MailProviderKind) -> Bool {
    switch failure {
    case .adminApprovalNeeded: true
    case .cancelled: provider != .gmail
    case .alreadyConnected, .takenByOtherIPhone, .offline, .failed: false
    }
  }
}
