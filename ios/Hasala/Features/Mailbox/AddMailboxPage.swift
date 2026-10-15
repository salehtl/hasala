import HasalaDesign
import HasalaModels
import SwiftUI

/// Add a mailbox (Paper "Add a mailbox · 2 Choose your email"), pushed inside the profile
/// sheet (decision 11). With one provider to offer it goes straight to that provider's
/// screen (plan B4.6 rule 2).
///
/// The foundation's version (plan B7.3).
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
          .navigationTitle("Add a mailbox")
          .navigationBarTitleDisplayMode(.inline)
      }
    }
  }
}
