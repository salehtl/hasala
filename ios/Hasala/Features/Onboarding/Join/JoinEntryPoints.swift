import SwiftUI

// The signed-out screens' entry points (plan B7.3): each is `init(store: OnboardingStore)`,
// with the store's `signup` model and the store's path for its navigation, so
// `WelcomeFlowView` only says which screen a route shows. The initializers are frozen; the
// bodies are the screens'.

extension StoriesView {
  init(store: OnboardingStore) {
    self.init(
      page: Bindable(store).storyPage, whoSeesOpen: Bindable(store.signup).whoCanSeeOpen,
      outlook: store.services.mailbox.connectable.contains(.outlook),
      onGetStarted: { store.signup.go(.welcome) }, onSignIn: { store.signup.go(.signIn) })
  }
}

extension JoinWelcomeView {
  init(store: OnboardingStore) {
    self.init(onJoin: { store.signup.go(.invite) }, onSignIn: { store.signup.go(.signIn) },
              onBack: { store.signup.back() })
  }
}

extension InviteCodeView {
  init(store: OnboardingStore) {
    self.init(model: store.signup)
  }
}

extension AboutYouView {
  init(store: OnboardingStore) {
    self.init(model: store.signup, onSignIn: { store.signup.path = [.signIn] })
  }
}

extension SignInMethodView {
  init(store: OnboardingStore) {
    self.init(model: store.signup)
  }
}

extension CreatePasswordView {
  init(store: OnboardingStore) {
    self.init(model: store.signup)
  }
}

extension PhraseIntroView {
  init(store: OnboardingStore) {
    self.init(model: store.signup)
  }
}

extension PhraseShowView {
  /// Signup's phrase, in create mode.
  init(store: OnboardingStore) {
    self.init(signup: store.signup)
  }

  /// A signup model's phrase in create mode (signup's, or the interrupted signup's
  /// replacement): hidden until tapped, then "I've written them down" publishes it.
  init(signup m: SignupModel) {
    self.init(
      revealed: Bindable(m).phraseRevealed, words: m.phrase?.words ?? [], onBack: { m.back() },
      onContinue: { Task { await m.finish() } }, seen: m.phraseSeen, busy: m.busy, failure: m.failure,
      onCapture: { m.phraseMasked = $0 })
  }
}

extension AccountReadyView {
  init(store: OnboardingStore) {
    self.init(profile: store.signup.profile, outlook: store.services.mailbox.connectable.contains(.outlook),
              capabilities: store.signup.capabilities) {
      store.session().accountCreated()
    }
  }
}
