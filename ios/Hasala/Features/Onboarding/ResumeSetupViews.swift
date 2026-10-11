import HasalaDesign
import SwiftUI

/// After a relaunch with a session and no keys here (spec 04 §6.5): the server decides
/// between unlocking and finishing setup. Offline stays here with Retry.
struct BootCheckView: View {
  let session: AccountSession
  @State private var signingOut = false

  var body: some View {
    NavigationStack {
      AccountScreen(
        title: session.resumeFailure == nil ? "Opening Hasala" : "Can't reach Hasala",
        subtitle: session.resumeFailure == nil
          ? "Checking your account."
          : "You're signed in. Hasala needs a connection to open your account on this iPhone."
      ) {
        if session.resumeFailure == nil {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
        }
      } footer: {
        if session.resumeFailure != nil {
          Button("Try again") { Task { await session.resume() } }
            .buttonStyle(.pill(.primary, fill: true))
            .accessibilityIdentifier("boot.retry")
          LinkButton(title: "Sign out", identifier: "boot.signOut") {
            Task {
              await session.account.signOut()
              session.signedOut()
            }
          }
        }
      }
    }
    .task { await session.resume() }
  }
}

/// C1 interrupted (spec 04 §6.2, §6.5 `onboarding(keys)`): the account exists but its
/// keys never reached the server. A NEW phrase opens with S-07, is checked like at
/// signup, then published behind one Face ID prompt (step-up `keys.bootstrap`). The
/// phrase screens are signup's, on the same model and routes.
struct InterruptedSetupFlowView: View {
  let session: AccountSession
  @State private var model: SignupModel

  init(session: AccountSession) {
    self.session = session
    let m = SignupModel(account: session.account)
    m.startReplacement()
    _model = State(initialValue: m)
  }

  var body: some View {
    NavigationStack(path: $model.path) {
      AccountScreen(
        title: "Let's finish setting up",
        subtitle: "Your account was made, but setup stopped before your keys were saved. Hasala makes them again now."
      ) {
        VStack(spacing: 12) {
          NoteCard(systemImage: "doc.text", title: "This is a new recovery phrase",
                   text: "This is a new recovery phrase. Throw away any words you wrote down before.",
                   tint: HColor.statusWarningSurface)
          NoteCard(systemImage: "faceid", title: "Then Face ID",
                   text: "Your passkey confirms it's you, and your data is locked with the new words.")
          FailureBanner(failure: model.failure)
        }
      } footer: {
        Button("Show my new words") { model.go(.phraseShow) }
          .buttonStyle(.pill(.primary, fill: true))
          .disabled(model.phrase == nil)
          .accessibilityIdentifier("resume.start")
        LinkButton(title: "Sign out", identifier: "resume.signOut") {
          Task {
            await session.account.signOut()
            session.signedOut()
          }
        }
      }
      .navigationDestination(for: WelcomeRoute.self) { route in
        switch route {
        case .phraseShow:
          PhraseShowView(revealed: $model.phraseRevealed, words: model.phrase?.words ?? [], onBack: model.back,
                         onContinue: { model.go(.phraseConfirm) })
        case .phraseConfirm:
          PhraseConfirmView(model: model)
        case .accountReady:
          AccountReadyView(profile: model.profile) { session.accountCreated() }
            .navigationBarBackButtonHidden()
        default:
          EmptyView()
        }
      }
    }
  }
}
