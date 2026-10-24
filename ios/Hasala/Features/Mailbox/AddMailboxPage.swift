import HasalaDesign
import HasalaModels
import SwiftUI

/// Add a mailbox (Paper "Add a mailbox · 2 Choose your email" 1NW2), pushed inside the
/// profile sheet (decision 11): the providers, a connected one naming its address. Picking
/// one pushes its read-only screen. With one provider to offer it is that provider's screen
/// straight away (plan B4.6 rule 2). Where the build holds one mailbox and the account has
/// it, the same page is "Use another email": the provider's screen confirms the switch.
struct AddMailboxPage: View {
  @Bindable var app: AppModel

  var body: some View {
    if let mailbox = app.mailbox {
      if mailbox.connectable.count == 1, let only = mailbox.connectable.first {
        ConnectMailPage(app: app, provider: only)
      } else {
        let change = mailbox.holdsOneLink && mailbox.mailboxes.contains { $0.state != .disconnected }
        ChooseEmailSheet(mailbox: mailbox, title: change ? .change : .addMailbox) {
          app.router.profile.append(.connectMail($0))
        }
      }
    }
  }
}
