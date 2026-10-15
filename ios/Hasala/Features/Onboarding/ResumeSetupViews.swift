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
/// keys never reached the server. A NEW phrase opens with S-07, is shown like at signup,
/// then published behind one Face ID prompt (step-up `keys.bootstrap`) once the words were
/// shown. The phrase screens are signup's, on the same model and routes, and this first
/// screen stands on the same account template (no Paper board draws it).
///
/// The replacement phrase is the onboarding store's (`replacementModel()`): made once, not
/// on every re-render, and kept through the phrase screens.
struct InterruptedSetupFlowView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  private var session: AccountSession { store.session() }

  var body: some View {
    let model = store.replacementModel()
    NavigationStack(path: Bindable(model).navigationPath) {
      AccountScreen(
        title: "Let's finish setting up",
        subtitle: "Your account was made, but setup stopped before your keys were saved. Hasala makes them again now."
      ) {
        VStack(alignment: .leading, spacing: 12) {
          WarningCallout(icon: .paper, text: "This is a new recovery phrase. Throw away any words you wrote down before.")
          InfoCard(icon: .faceID, hue: .sky, title: "Then Face ID",
                   detail: "Your passkey confirms it's you, and your data is locked with the new words.",
                   radius: HRadius.tile)
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
          PhraseShowView(signup: model)
        case .accountReady:
          AccountReadyView(profile: model.profile, outlook: store.services.mailbox.connectable.contains(.outlook)) {
            session.accountCreated()
          }
          .navigationBarBackButtonHidden()
        default:
          EmptyView()
        }
      }
    }
  }
}
