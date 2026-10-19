import HasalaDesign
import HasalaModels
import SwiftUI

/// A connect that didn't happen (Paper "Connect email · Work or school account needs an
/// admin" 1MUP, "Microsoft sign-in didn't finish" 1NQF): what happened, that nothing was
/// connected, what the person can do, and the two ways on. Google gets the same screens in
/// its own words.
///
/// - An admin's approval: "Choose a different email" leads; "Approved since? Try Microsoft
///   again" follows.
/// - A sign-in that didn't finish: "Continue with Microsoft" leads; "Wrong account? Choose a
///   different email" follows.
///
/// `steps` is setup's indicator ("2 of 4"); the profile shows none. `busy` is a retry that
/// runs on this screen (setup keeps it on top while the sign-in runs): the button or the
/// link shows it, so a second failure that leaves the screen as it was doesn't read as a
/// dead tap. The profile goes back to the read-only screen to retry instead.
struct MailConnectErrorView: View {
  let failure: MailConnectFailure
  let provider: MailProviderKind
  var steps: (current: Int, of: Int)?
  var busy: Bool
  var onRetry: () -> Void
  var onChooseDifferent: () -> Void

  init(
    failure: MailConnectFailure, provider: MailProviderKind, busy: Bool = false, onRetry: @escaping () -> Void,
    onChooseDifferent: @escaping () -> Void, steps: (current: Int, of: Int)? = nil
  ) {
    self.failure = failure
    self.provider = provider
    self.busy = busy
    self.onRetry = onRetry
    self.onChooseDifferent = onChooseDifferent
    self.steps = steps
  }

  var body: some View {
    let copy = Self.copy(failure, provider)
    AccountScreen(title: copy.title, subtitle: copy.subtitle, steps: steps, back: .system) {
      if let reasons = copy.reasons {
        MailReasonsCard(title: reasons.title, items: reasons.items, numbered: reasons.numbered)
      }
    } footer: {
      if case .adminApprovalNeeded = failure {
        BusyButton(title: "Choose a different email", busy: false, identifier: "mail.error.chooseDifferent",
                   action: onChooseDifferent)
          .dockPill()
        TextLinkRow(lead: "Approved since?", link: "Try \(provider.company) again", identifier: "mail.error.retry",
                    busy: busy, action: onRetry)
      } else if case .noMailbox(let account) = failure {
        BusyButton(title: Self.otherAccountTitle(account), busy: busy, identifier: "mail.error.retry", action: onRetry)
          .dockPill()
        TextLinkRow(lead: "Alerts go somewhere else?", link: "Choose a different email",
                    identifier: "mail.error.chooseDifferent", action: onChooseDifferent)
      } else {
        ProviderButton(provider: provider, loading: busy, action: onRetry)
          .dockPill()
          .accessibilityIdentifier("mail.error.retry")
        TextLinkRow(lead: "Wrong account?", link: "Choose a different email", identifier: "mail.error.chooseDifferent",
                    action: onChooseDifferent)
      }
    }
  }

  static func otherAccountTitle(_ provider: MailProviderKind) -> String {
    "Use another \(provider.company) account"
  }

  struct Copy: Equatable {
    struct Reasons: Equatable {
      let title: String
      let items: [MailReasonsCard.Item]
      let numbered: Bool
    }

    let title: String
    let subtitle: String
    let reasons: Reasons?
  }

  /// The screen's words, verbatim from the boards for Microsoft and in the same pattern for
  /// Google. Another failure (if a host shows one here) keeps its own line.
  static func copy(_ failure: MailConnectFailure, _ provider: MailProviderKind) -> Copy {
    switch failure {
    case .adminApprovalNeeded(let address):
      let approve: String =
        switch provider {
        case .outlook: "They approve Hasala once in Microsoft Entra. Then come back and try again."
        case .gmail: "They approve Hasala once in the Google Admin console. Then come back and try again."
        }
      // A personal mailbox of a provider this build reads; Release names Google alone.
      let other =
        provider == .gmail
        ? "If your bank also emails a personal Gmail address, connect that one."
        : "If your bank also emails a personal Gmail or Outlook.com address, connect that one."
      return Copy(
        title: "Your organisation needs to approve Hasala.",
        subtitle: "\(address) is a work or school account. Its admin has to allow Hasala to read mail before it can connect. Nothing was connected.",
        reasons: Copy.Reasons(
          title: "What you can do",
          items: [
            MailReasonsCard.Item(title: "Ask your IT admin", detail: approve),
            MailReasonsCard.Item(title: "Use another mailbox", detail: other),
          ],
          numbered: true))
    case .cancelled:
      return Copy(
        title: "\(provider.appName) isn't connected.",
        subtitle: "\(provider.company) sign-in was cancelled or didn't finish. Nothing was connected and nothing was read.",
        reasons: Copy.Reasons(
          title: "Common reasons",
          items: [
            MailReasonsCard.Item(title: "Cancel or Back on \(provider.company)'s screen", detail: "Fine. Try again when you're ready."),
            MailReasonsCard.Item(
              title: "Permissions not accepted",
              detail: "Hasala needs read-only mail access to see your bank alerts. Without it, it can't connect."),
          ],
          numbered: false))
    case .noMailbox(let account):
      return Copy(
        title: "\(account.appName) isn't connected.",
        subtitle: MailConnectFailure.noMailboxLine(account) + " Nothing was connected and nothing was read.",
        reasons: nil)
    default:
      return Copy(
        title: "\(provider.appName) isn't connected.",
        subtitle: ((failure.message(for: provider) ?? "") + " Nothing was connected.")
          .trimmingCharacters(in: .whitespaces),
        reasons: nil)
    }
  }
}
