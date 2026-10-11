import HasalaDesign
import SwiftUI

/// The account gate in front of the app (spec 04 §13.1 BootWalls + OnboardingFlow):
/// welcome and sign-in while signed out, setup until it is finished, the unlock and
/// frozen walls, then `main`.
struct AccountRootView<Main: View>: View {
  let session: AccountSession
  /// The facts setup resumes from (the live build reads them from the projection).
  var setupFacts: OnboardingStep.Facts = .init(hasSession: true, keysReady: true)
  @ViewBuilder var main: () -> Main

  var body: some View {
    content
      .environment(session)
      .onOpenURL { session.open($0) }
      .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
        if let url = activity.webpageURL { session.open(url) }
      }
      .overlay(alignment: .bottom) {
        if let notice = session.notice {
          GlassToast(systemImage: "person.crop.circle.badge.checkmark", title: notice, actionTitle: "OK") {
            session.notice = nil
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 90)
          .task {
            try? await Task.sleep(for: .seconds(4))
            session.notice = nil
          }
        }
      }
  }

  @Environment(\.scenePhase) private var scenePhase
  @State private var passcodeChecked = 0

  @ViewBuilder private var content: some View {
    let _ = passcodeChecked
    if session.phase != .ready, !session.services.hasPasscode() {
      PasscodeWall()
        .onChange(of: scenePhase) { _, p in if p == .active { passcodeChecked += 1 } }
    } else {
      phaseContent
    }
  }

  @ViewBuilder private var phaseContent: some View {
    switch session.phase {
    case .signedOut:
      WelcomeFlowView(session: session)
    case .onboarding:
      SetupFlowView(model: SetupModel(
        services: session.services,
        displayName: session.account.profile?.displayName ?? "",
        facts: setupFacts,
        onFinished: { [weak session] in session?.setupFinished() }))
    case .needsUnlock(let passkeyCanUnlock):
      UnlockView(
        model: UnlockModel(account: session.account, passkeyCanUnlock: passkeyCanUnlock,
                           onUnlocked: { [weak session] in session?.unlocked() }),
        onSignOut: {
          Task {
            await session.account.signOut()
            session.signedOut()
          }
        })
    case .needsKeys:
      NeedsKeysWall { session.signedOut() }
    case .frozen(let info):
      FrozenWall(session: session, info: info)
    case .ready:
      main()
        .safeAreaInset(edge: .top, spacing: 0) {
          if session.leftFrozen {
            FrozenBanner { session.froze(FreezeInfo(by: .holder, when: nil)) }
          }
        }
    }
  }
}

/// Onboarding step 0 (spec 04 §6.6; copy S-24). Re-checked when the app comes back.
struct PasscodeWall: View {
  var body: some View {
    NavigationStack {
      AccountScreen(
        title: "Set a passcode first",
        subtitle: "Set a passcode on your iPhone to use Hasala. It protects your data and lets this iPhone confirm it's you."
      ) {
        NoteCard(systemImage: "gear", title: "Settings › Face ID & Passcode",
                 text: "Turn on a passcode, then come back here. Hasala carries on where you left off.")
      } footer: {
        EmptyView()
      }
    }
    .accessibilityIdentifier("passcode.wall")
  }
}
