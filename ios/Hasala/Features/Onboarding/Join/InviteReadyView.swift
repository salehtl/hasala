import SwiftUI

/// "Your invite is ready" (Paper E5B-0): an invite link opened the app with the code filled
/// in. It is never submitted on its own; "Create my account" goes on to About you.
///
/// The foundation's version (plan B7.3): today's invite screen, prefilled.
// TODO(plan P1): the "Your invite is ready" board ("Create my account", "Use a different
// code").
struct InviteReadyView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View { InviteCodeView(model: store.signup) }
}
