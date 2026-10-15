import HasalaDesign
import HasalaModels
import SwiftUI

/// Which heading "Choose your email" carries: setup's, or the profile's Add a mailbox.
enum ChooseEmailTitle: Sendable {
  case setup
  case addMailbox

  var title: String {
    switch self {
    case .setup: "Choose your email"
    case .addMailbox: "Add a mailbox"
    }
  }

  var subtitle: String {
    switch self {
    case .setup: "Pick where your bank sends its alerts. Access is read-only, and this iPhone does the reading."
    case .addMailbox: "Pick the one your bank also sends alerts to. Access is read-only, and this iPhone does the reading."
    }
  }
}

/// The providers this build can connect (Paper "Connect email · Choose your email"), as a
/// sheet over setup's bank step, or pushed in the profile (Add a mailbox). A provider not in
/// `connectable` is never listed.
///
/// The foundation's version (plan B7.3), on today's parts.
// TODO(plan P3): ProviderRow with ProviderMark, a connected provider's address as its
// subtitle, the content-height sheet and the "Tell us which" link.
struct ChooseEmailSheet: View {
  let mailbox: MailboxConnecting
  let title: ChooseEmailTitle
  var onPick: (MailProviderKind) -> Void

  init(mailbox: MailboxConnecting, title: ChooseEmailTitle, onPick: @escaping (MailProviderKind) -> Void) {
    self.mailbox = mailbox
    self.title = title
    self.onPick = onPick
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text(title.title).hType(.title1).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
          Text(title.subtitle).hType(.body).foregroundStyle(HColor.textSecondary)
        }
        ListCard {
          ForEach(mailbox.connectable) { provider in
            Button { onPick(provider) } label: {
              NavRow(title: provider.appName, detail: provider.chooserSubtitle) {
                RowIcon(systemName: "envelope")
              }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mail.choose.\(provider.rawValue)")
          }
        }
        Text("Each mailbox can be disconnected on its own, at any time.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
  }
}
