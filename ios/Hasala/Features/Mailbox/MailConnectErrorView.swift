import HasalaDesign
import HasalaModels
import SwiftUI

/// A connect that didn't happen (Paper "Connect email · Work or school account needs an
/// admin", "Microsoft sign-in didn't finish"): what happened, that nothing was connected,
/// and the two ways on.
///
/// The foundation's version (plan B7.3), on today's parts.
// TODO(plan P3): the reasons cards, ProviderButton and the per-failure footers.
struct MailConnectErrorView: View {
  let failure: MailConnectFailure
  let provider: MailProviderKind
  var onRetry: () -> Void
  var onChooseDifferent: () -> Void
  @Environment(\.dismiss) private var dismiss

  init(
    failure: MailConnectFailure, provider: MailProviderKind, onRetry: @escaping () -> Void,
    onChooseDifferent: @escaping () -> Void
  ) {
    self.failure = failure
    self.provider = provider
    self.onRetry = onRetry
    self.onChooseDifferent = onChooseDifferent
  }

  private var title: String {
    switch failure {
    case .adminApprovalNeeded: "Your organisation needs to approve Hasala."
    default: "\(provider.appName) isn't connected."
    }
  }

  private var subtitle: String {
    switch failure {
    case .adminApprovalNeeded(let address):
      "\(address) is a work or school account. Its admin has to allow Hasala to read mail before it can connect. Nothing was connected."
    case .cancelled:
      "\(provider.company) sign-in was cancelled or didn't finish. Nothing was connected and nothing was read."
    default:
      (failure.message(for: provider) ?? "") + " Nothing was connected."
    }
  }

  var body: some View {
    AccountScreen(title: title, subtitle: subtitle, onBack: { dismiss() }) {
      EmptyView()
    } footer: {
      BusyButton(title: provider.continueTitle, busy: false, identifier: "mail.error.retry", action: onRetry)
      LinkButton(title: "Choose a different email", identifier: "mail.error.chooseDifferent", action: onChooseDifferent)
    }
  }
}
