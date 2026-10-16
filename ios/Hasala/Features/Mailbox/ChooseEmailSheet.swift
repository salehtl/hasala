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

  var footnote: String {
    switch self {
    case .setup: "You can add another mailbox later in Profile › Bank alerts. Disconnect any of them at any time."
    case .addMailbox: "Each mailbox can be disconnected on its own, at any time."
    }
  }
}

/// The providers this build can connect (Paper "Connect email · Choose your email (sheet
/// over setup 1)" 1MZG, "Add a mailbox · 2 Choose your email" 1NW2; page 15 §03): one row
/// per provider, named by the mail app ("Gmail", "Outlook"), the account kinds it covers,
/// or the address already connected ("maya@example.com is connected. Add another Google
/// account.") or needing a new sign-in. A provider not in `connectable` is never listed.
/// Picking a row moves to the provider's read-only screen.
///
/// In setup it is a large sheet over the bank step (plan decision 5) that hugs its content:
/// it sets its own height, grabber, corner radius and grey surface, so present it bare, and
/// it closes itself before `onPick`. In the profile (`.addMailbox`) it is a page pushed
/// inside the profile sheet (decision 11), with the same heading and rows.
struct ChooseEmailSheet: View {
  let mailbox: MailboxConnecting
  let title: ChooseEmailTitle
  var onPick: (MailProviderKind) -> Void
  /// The sheet's content height; the detent follows it.
  @State private var height: CGFloat = 0
  @Environment(\.dismiss) private var dismiss

  init(mailbox: MailboxConnecting, title: ChooseEmailTitle, onPick: @escaping (MailProviderKind) -> Void) {
    self.mailbox = mailbox
    self.title = title
    self.onPick = onPick
  }

  var body: some View {
    switch title {
    case .setup: sheet
    case .addMailbox: page
    }
  }

  /// Setup: Paper's large sheet hugging its content (1MZG): the heading 43 under the
  /// sheet's top (8, the system grabber, 18, 12), 20 at the sides, 18 between the heading,
  /// the providers and the footnote, 14 under the link (the system keeps the home
  /// indicator's inset below that, Paper's 48 in all). The detent is the content's height,
  /// so it stays right at every text size; past the screen it scrolls.
  private var sheet: some View {
    ScrollView {
      content(headingTop: 43)
        .padding(.horizontal, HSpacing.sheetPadding)
        .padding(.bottom, 14)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(HColor.sheetSurfaceLarge)
    .presentationDetents(height > 0 ? [.height(height)] : [.medium])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
    .accessibilityIdentifier("mail.choose")
  }

  /// The profile: the same heading and rows on a page inside the profile sheet.
  private var page: some View {
    ScrollView {
      content(headingTop: 8)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 32)
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(HColor.surfaceSecondary)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("mail.choose")
  }

  private func content(headingTop: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text(title.title)
          .hType(HType(size: 28, leading: 34, weight: .bold, tracking: -0.5, textStyle: .title))
          .foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(title.subtitle).hType(.callout).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, headingTop)
      HListCard {
        ForEach(Array(mailbox.connectable.enumerated()), id: \.element) { i, provider in
          if i > 0 { HDivider(inset: .disc68) }
          // Setup's pick is always a new connect; the profile's follows the offer.
          ProviderRow(provider: provider, subtitle: Self.subtitle(
            provider, mailboxes: mailbox.mailboxes, offer: title == .addMailbox ? mailbox.offer : nil)) {
            pick(provider)
          }
            .accessibilityIdentifier("mail.choose.\(provider.rawValue)")
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title.footnote).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        TellUsWhichLink(small: true, leading: true)
      }
      .padding(.horizontal, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A connected provider names its address and offers another account of its own (page
  /// 15: "A provider already connected shows its address as the subtitle and stays
  /// tappable, to add a second mailbox"). A mailbox that needs a new sign-in is not
  /// connected: while the profile's connect of that provider signs it in again
  /// (`ConnectMailPage.context`, the offer the bell and the Profile card make), the row
  /// says so, as the screen it opens does ("Sign in to Outlook again.").
  static func subtitle(_ provider: MailProviderKind, mailboxes: [MailboxSnapshot], offer: MailOffer? = nil) -> String? {
    let own = mailboxes.filter { $0.provider == provider }
    if case .signInAgain(let id) = ConnectMailPage.context(provider, offer: offer),
       let broken = own.first(where: { $0.id == id }) {
      return "\(broken.address) needs a new sign-in. Sign in to \(provider.appName) again."
    }
    if let connected = own.first(where: { $0.state == .connected || $0.state == .syncing }) {
      return "\(connected.address) is connected. Add another \(provider.company) account."
    }
    if let broken = own.first(where: { $0.state == .needsSignIn }) {
      return "\(broken.address) needs a new sign-in."
    }
    return nil
  }

  private func pick(_ provider: MailProviderKind) {
    if title == .setup { dismiss() }
    onPick(provider)
  }
}
