import HasalaDesign
import HasalaWidgetData
import SwiftUI

/// The account gate in front of the app (spec 04 §13.1 BootWalls + OnboardingFlow):
/// welcome and sign-in while signed out, setup until it is finished, the unlock and
/// frozen walls, then `main`.
///
/// Every onboarding model is the store's (`OnboardingStore`, one per process), so this
/// view can be made again, flip to the passcode wall or sit under a wall without losing
/// what was typed or chosen (plan B3).
struct AccountRootView<Main: View>: View {
  let session: AccountSession
  let onboarding: OnboardingStore
  /// The facts setup resumes from (the live build reads them from the projection).
  var setupFacts: OnboardingStep.Facts = .init(hasSession: true, keysReady: true)
  @ViewBuilder var main: () -> Main

  init(
    session: AccountSession, onboarding: OnboardingStore,
    setupFacts: OnboardingStep.Facts = .init(hasSession: true, keysReady: true), @ViewBuilder main: @escaping () -> Main
  ) {
    self.session = session
    self.onboarding = onboarding
    self.setupFacts = setupFacts
    self.main = main
  }

  var body: some View {
    ZStack {
      content
        .id(gate)
        .transition(.opacity)
    }
    .animation(handOff, value: gate)
    .environment(session)
    .environment(onboarding)
    .onAppear { onboarding.phaseChanged(from: nil, to: session.phase) }
    .onChange(of: session.phase) { old, new in onboarding.phaseChanged(from: old, to: new) }
    .onOpenURL { url in
      if let link = WidgetLink(url: url) {
        WidgetLinkInbox.shared.pending = link
      } else {
        session.open(url)
      }
    }
    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { session.open(url) }
    }
    .overlay(alignment: .bottom) {
      // The gate's one note ("You already have an account"): the glass toast, risen in
      // over the screen's dock and gone after the toast's dwell.
      ZStack {
        if let notice = session.notice {
          GlassToast(.ink(.info), title: notice, actionTitle: "OK") { session.notice = nil }
            .padding(.horizontal, HSpacing.insetPage)
            .padding(.bottom, 90)
            .hTransition(.toastIn)
            .task {
              try? await Task.sleep(for: .seconds(HMotion.toastDwell))
              session.notice = nil
            }
        }
      }
      .hAnimation(session.notice == nil ? .toastOut : .toastIn, value: session.notice)
    }
  }

  @Environment(\.scenePhase) private var scenePhase
  @State private var passcodeChecked = 0
  @State private var pendingReset: PendingReset?
  @State private var lockingDown = false
  /// "No, that's not me" was tapped: the lockdown sheet follows once the approval sheet
  /// has finished dismissing (two sheets at once drop the second).
  @State private var lockdownAfterApproval = false

  @StageMotion private var motion: MotionPolicy

  private enum Gate: Hashable { case passcode, signedOut, checking, onboarding, needsUnlock, needsKeys, frozen, ready }

  private var gate: Gate {
    if session.phase != .ready, !session.services.hasPasscode() { return .passcode }
    switch session.phase {
    case .signedOut: return .signedOut
    case .checking: return .checking
    case .onboarding: return .onboarding
    case .needsUnlock: return .needsUnlock
    case .needsKeys: return .needsKeys
    case .frozen: return .frozen
    case .ready: return .ready
    }
  }

  private var handOff: Animation? {
    if motion.settled { return nil }
    return HMotion.easeOutSoft(motion.reduceMotion ? HMotion.reduceMotionFade : 0.3)
  }

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
      WelcomeFlowView(store: onboarding)
    case .checking:
      BootCheckView(session: session)
    case .onboarding:
      SetupFlowView(model: onboarding.setupModel(
        displayName: session.account.profile?.displayName ?? "", facts: setupFacts))
    case .needsUnlock:
      UnlockView(session: session)
    case .needsKeys:
      InterruptedSetupFlowView(store: onboarding)
    case .frozen(let info):
      FrozenWall(session: session, info: info)
    case .ready:
      main()
        .safeAreaInset(edge: .top, spacing: 0) {
          if let info = session.leftFrozen {
            FrozenBanner(by: info.by) { session.showFrozenWall() }
          }
        }
        // A password reset another iPhone asked this one to approve (spec 04 §6.12):
        // checked on every foreground, in builds that offer password resets.
        .task(id: scenePhase) {
          guard scenePhase == .active, pendingReset == nil, session.capabilities.contains(.resetPassword) else { return }
          pendingReset = await session.account.pendingResetRequest()
        }
        .sheet(item: $pendingReset, onDismiss: {
          if lockdownAfterApproval {
            lockdownAfterApproval = false
            lockingDown = true
          }
        }) { request in
          ResetApprovalSheet(model: ResetApprovalModel(account: session.account, request: request)) {
            lockdownAfterApproval = true
          }
        }
        .sheet(isPresented: $lockingDown) {
          NavigationStack { LockdownSheetContent(session: session) }
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

/// "Let's lock it down" as a sheet, after "No, that's not me".
private struct LockdownSheetContent: View {
  @State private var model: SecurityModel
  @Environment(\.dismiss) private var dismiss

  init(session: AccountSession) {
    _model = State(initialValue: SecurityModel(session: session))
  }

  var body: some View {
    LockdownView(model: model)
      .task { await model.load() }
      // LockdownView presents its own "Confirm it's you" (`host: .lockdown`).
      .sheet(isPresented: $model.editingPassword) { PasswordEditSheet(model: model) }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          // In the glass ink, as Paper draws the sheet's close (not the accent).
          Button(role: .close) { dismiss() }
            .tint(HColor.iconGlass)
            .accessibilityIdentifier("lockdown.close")
        }
      }
  }
}
