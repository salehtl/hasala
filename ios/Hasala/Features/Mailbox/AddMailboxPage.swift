import HasalaDesign
import HasalaModels
import SwiftUI

/// Add a mailbox (Paper "Add a mailbox · 2 Choose your email" 1NW2), pushed inside the
/// profile sheet (decision 11): the providers, a connected one naming its address. Picking
/// one pushes its read-only screen. With one provider to offer it is that provider's screen
/// straight away (plan B4.6 rule 2).
struct AddMailboxPage: View {
  @Bindable var app: AppModel

  init(app: AppModel) {
    self.app = app
  }

  var body: some View {
    if let mailbox = app.mailbox {
      if mailbox.connectable.count == 1, let only = mailbox.connectable.first {
        ConnectMailPage(app: app, provider: only)
      } else {
        ChooseEmailSheet(mailbox: mailbox, title: .addMailbox) { app.router.profile.append(.connectMail($0)) }
      }
    }
  }
}
