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
          case .connect(let provider): EmailStep(model: model, provider: provider)
          case .connectError(let provider): EmailErrorStep(model: model, provider: provider)
          case .scan: ScanStep(model: model)
          case .income: IncomeStep(model: model)
          case .plan: PlanStep(model: model)
          case .result: ResultStep(model: model)
          case .notifications: NotificationsStep(model: model)
          case .done: DoneStep(model: model)
          }
        }
    }
    .sheet(isPresented: $model.choosingEmail) {
      ChooseEmailSheet(mailbox: model.mailbox, title: .setup) { model.pickProvider($0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.chooseEmail")
    }
    .onAppear { model.resume() }
    // The account's facts can arrive after setup first appeared (a runtime that opened on
    // "Try again"): the stack is built for them then.
    .onChange(of: model.step) { model.resume() }
  }
}

/// Setup · 2 of 4 · your email, read-only, for one provider (Paper 6RN-0, 1MOH-0): the
/// mailbox screens' view in setup's context, on the attempt the model keeps for the
/// process, so coming back here shows it connected, with "Continue" and no second sign-in.
/// A failure the design draws a screen for pushes it (an admin's approval, a Microsoft
/// sign-in that didn't finish); a closed Google sign-in leaves the screen as it was.
private struct EmailStep: View {
  var model: SetupModel
  let provider: MailProviderKind
  @Environment(\.openURL) private var openURL

  var body: some View {
    let coordinator = model.coordinator(provider)
    ConnectProviderView(
      provider: provider, coordinator: coordinator, banks: model.orderedBanks,
      sample: model.offersSampleData ? { Task { await model.useSampleData() } } : nil,
      onConnected: { _ in model.continueFromEmail(provider) },
      onChooseDifferent: chooseDifferent)
      .onChange(of: coordinator.outcome) { _, outcome in
        if case .failed? = outcome { model.connectFailed(provider) }
      }
      // A connect that already happened (a relaunch, the account's link) shows as connected.
      .task { await model.settle(provider) }
  }

  /// "Not your email? Choose a different one.": the chooser, or, where this build reads
  /// one provider, a note to us about the one it doesn't (plan B4.6 rule 2).
  private func chooseDifferent() {
    if model.canChooseEmail { model.chooseEmail() } else { openURL(BuildSurface.supportMail) }
  }
}

/// The connect didn't happen (Paper "Connect email · Work or school account needs an
/// admin", "Microsoft sign-in didn't finish"): the mailbox screens' error view. Trying
/// again replaces it with the first scan once it works.
private struct EmailErrorStep: View {
  var model: SetupModel
  let provider: MailProviderKind
  @Environment(\.openURL) private var openURL

  var body: some View {
    MailConnectErrorView(
      failure: model.connectFailure(provider) ?? .cancelled, provider: provider,
      onRetry: { Task { await model.retryConnect(provider) } },
      onChooseDifferent: {
        if model.canChooseEmail { model.chooseEmail() } else { openURL(BuildSurface.supportMail) }
      })
  }
}
