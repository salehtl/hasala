import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup after the account (Paper row 10 and P2.9 row 1): one navigation stack over the bank
/// step, with "Choose your email" as a sheet over whichever step asked for it (plan
/// decision 5). Steps push and pop with the system's timing. The model is the store's
/// (`OnboardingStore`), so everything done here stays for the life of the process.
struct SetupFlowView: View {
  @State private var model: SetupModel

  init(model: SetupModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationStack(path: $model.navigationPath) {
      BankStep(model: model)
        .navigationDestination(for: SetupRoute.self) { route in
          switch route {
          case .connectError(let provider): EmailErrorStep(model: model, provider: provider)
          }
        }
    }
    .sheet(isPresented: $model.choosingEmail, onDismiss: model.choosingEnded) {
      ChooseEmailSheet(mailbox: model.mailbox, title: .setup) { model.choose($0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.chooseEmail")
    }
    .onAppear { model.resume() }
    // The account's facts can arrive after setup first appeared (a runtime that opened on
    // "Try again"): the stack is built for them then.
    .onChange(of: model.step) { model.resume() }
  }
}

/// The connect didn't happen (Paper "Connect email · Work or school account needs an
/// admin", "Microsoft sign-in didn't finish"): the mailbox screens' error view. Trying
/// again runs on this screen, its button or link turning while the sign-in runs, and
/// replaces it with the first scan once it works; a second failure leaves it as it was.
private struct EmailErrorStep: View {
  var model: SetupModel
  let provider: MailProviderKind
  /// The failure this screen shows. A retry clears the attempt's outcome while it runs, so
  /// the screen keeps its words until the retry says otherwise.
  @State private var shown: MailConnectFailure?
  @Environment(\.openURL) private var openURL

  var body: some View {
    let coordinator = model.coordinator(provider)
    MailConnectErrorView(
      failure: model.connectFailure(provider) ?? shown ?? .cancelled, provider: provider,
      busy: coordinator.busy,
      onRetry: { Task { await model.retryConnect(provider) } },
      onChooseDifferent: {
        if model.canChooseEmail { model.chooseEmail() } else { openURL(BuildSurface.supportMail) }
      },
      steps: nil)
      .mailSwitchQuestion(coordinator)
      .onChange(of: model.connectFailure(provider), initial: true) { _, failure in
        if let failure { shown = failure }
      }
  }
}
