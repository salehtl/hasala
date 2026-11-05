import HasalaDesign
import HasalaModels
import SwiftUI

/// A connect that didn't happen (Paper "Microsoft sign-in didn't finish" 1NQF, "Gmail isn't
/// connected (permission)"): what happened, that nothing was connected, what the person can
/// do, and the two ways on. Google gets the same screens in its own words.
///
/// `steps` is setup's indicator ("2 of 4"); the profile shows none. `busy` is a retry that
/// runs on this screen (setup keeps it on top while the sign-in runs): the button or the
/// link shows it, so a second failure that leaves the screen as it was doesn't read as a
/// dead tap. The profile goes back to the read-only screen to retry instead. `onUseTexts`
/// is setup's way back to the source choice, given only where bank texts are offered.
struct MailConnectErrorView: View {
  let failure: MailConnectFailure
  let provider: MailProviderKind
  var steps: (current: Int, of: Int)?
  var busy: Bool
  var onRetry: () -> Void
  var onChooseDifferent: () -> Void
  var onUseTexts: (() -> Void)?

  init(
    failure: MailConnectFailure, provider: MailProviderKind, busy: Bool = false, onRetry: @escaping () -> Void,
    onChooseDifferent: @escaping () -> Void, onUseTexts: (() -> Void)? = nil, steps: (current: Int, of: Int)? = nil
  ) {
    self.failure = failure
    self.provider = provider
    self.busy = busy
    self.onRetry = onRetry
    self.onChooseDifferent = onChooseDifferent
    self.onUseTexts = onUseTexts
    self.steps = steps
  }

  static let textsLead = "Only get texts from your bank?"
  static let textsLink = "Use bank texts instead"

  var body: some View {
    let copy = Self.copy(failure, provider)
    AccountScreen(title: copy.title, subtitle: copy.subtitle, steps: steps, back: .system) {
      VStack(alignment: .leading, spacing: 16) {
        if let reasons = copy.reasons {
          MailReasonsCard(title: reasons.title, items: reasons.items, numbered: reasons.numbered)
        }
        if let onUseTexts {
          TextLinkRow(lead: Self.textsLead, link: Self.textsLink, identifier: "mail.error.useTexts", action: onUseTexts)
            .disabled(busy)
        }
      }
    } footer: {
      if case .noMailbox(let account) = failure {
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
  static func permissionStep(_ account: MailProviderKind) -> String {
    switch account {
    case .gmail: "Tick \u{201C}View your email messages and settings\u{201D}"
    case .outlook: "Allow \u{201C}Read your mail\u{201D}"
    }
  }

  static func copy(_ failure: MailConnectFailure, _ provider: MailProviderKind) -> Copy {
    switch failure {
    case .permissionMissing(let account):
      return Copy(
        title: "\(account.appName) isn't connected.",
        subtitle: "Hasala can't see your alerts without read access. Nothing was connected and nothing was read.",
        reasons: Copy.Reasons(
          title: "What to do",
          items: [
            MailReasonsCard.Item(title: Self.permissionStep(account), detail: "It's on \(account.company)'s screen."),
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
