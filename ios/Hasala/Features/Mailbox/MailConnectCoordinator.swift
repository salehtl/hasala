import HasalaModels
import Observation

/// One connect attempt, for setup's email step, Add a mailbox and Sign in again (plan
/// B4.3): it runs the provider's sign-in through `MailboxConnecting` and says how it went.
/// A closed Google sign-in is not an error, as before (the screen stays as it was); any
/// other failure is the outcome the screen shows.
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
  @ObservationIgnored private let mailbox: MailboxConnecting
  private(set) var busy = false
  private(set) var outcome: Outcome?

  init(mailbox: MailboxConnecting, context: Context) {
    self.mailbox = mailbox
    self.context = context
  }

  /// Runs the sign-in (or the sign-in again). A second tap while one runs does nothing.
  func connect(_ provider: MailProviderKind) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    outcome = nil
    do {
      if case .signInAgain(let id) = context {
        try await mailbox.signInAgain(id)
        outcome = .connected(mailboxID: id)
      } else {
        outcome = .connected(mailboxID: try await mailbox.connect(provider))
      }
    } catch .cancelled where provider == .gmail {
      outcome = nil
    } catch {
      outcome = .failed(error)
    }
  }

  /// Back to before the attempt ("Try again", "Choose a different email").
  func reset() {
    outcome = nil
  }
}
