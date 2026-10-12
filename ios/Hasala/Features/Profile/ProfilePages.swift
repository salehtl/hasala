import HasalaDesign
import SwiftUI

/// Profile › Delete your account (Paper "Sign-in & security · Delete your account"; copy
/// S-22), reachable from the profile itself as App Review requires (Guideline 5.1.1(v)).
/// It runs the same ceremony as Sign-in & security: `AccountService.perform(.deleteAccount,
/// password:)` behind its step-up (Face ID for a passkey account; the password plus this
/// iPhone's key for a password-only one). Once it succeeds the session signs out and the
/// account gate shows the welcome screens.
struct DeleteAccountPage: View {
  @State private var model: SecurityModel

  init(session: AccountSession) {
    _model = State(initialValue: SecurityModel(session: session))
  }

  var body: some View {
    DeleteAccountView(failure: model.failure) {
      Task { await delete() }
    }
    .disabled(model.busy)
    .overlay { if model.busy { ProgressView().controlSize(.large) } }
    .task { await model.load() }
    .confirmSheet(model)
  }

  /// The step-up depends on whether the account has a passkey, which `load()` reads; a
  /// first load that failed (offline) is retried here.
  private func delete() async {
    if model.state == nil { await model.load() }
    guard model.state != nil else { return }
    await model.request(.deleteAccount)
  }
}

/// Profile › Get help: how to send feedback from TestFlight, and how to reach a person.
struct HelpPage: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 14) {
          help("camera.viewfinder", "Send feedback from TestFlight",
               "Take a screenshot in Hasala, then tap Share Beta Feedback. Or open TestFlight, choose Hasala and tap Send Beta Feedback.")
          help("person.2", "Talk to a person",
               "Write to us about anything that isn't working or that you'd like changed. A person reads every email.")
        }
        .padding(18)
        .listCard()
        SupportLink(lead: "Questions, or something not working?", identifier: "help.email", web: false)
        WebLink(title: "Help and support", url: "https://hasala.app/support", identifier: "help.support")
        WebLink(title: "Privacy policy", url: "https://hasala.app/privacy", identifier: "help.privacy")
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Get help")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func help(_ symbol: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).foregroundStyle(HColor.iconPrimary).frame(width: 24).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
        Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
