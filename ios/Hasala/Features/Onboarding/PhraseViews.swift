import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

// Paper P2.2 "Recovery phrase" (spec 07 §5): why it matters, then the 12 words hidden
// until tapped and written on paper, then "Your account is ready". There is no word check
// (`docs/decisions/recovery-phrase-no-quiz.md`): "I've written them down" publishes the
// account once the words were drawn for the person.

/// Recovery phrase · 3 of 3 · Why it matters (Paper F46-0; spec 07 S11). No way back: the
/// account exists.
struct PhraseIntroView: View {
  var model: SignupModel

  var body: some View {
    AccountScreen(
      title: "Your recovery phrase is your spare key",
      subtitle: "Hasala seals your data with a key only your devices hold. These words can rebuild that key on a new iPhone.",
      steps: (3, 3)
    ) {
      VStack(alignment: .leading, spacing: 18) {
        point(.paper, .sand, "Write them on paper", "Keep it somewhere safe at home. Not in your photos, notes or email.")
        point(.phone, .sky, "For a new iPhone", newIPhone)
        point(.lock, .rose, "Only you have them",
              "We never see them, so we can't reset or resend them. Lose them and every device that unlocks Hasala, and your data is gone for good.")
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    } actions: {
      Button("Show my 12 words") { model.go(.phraseShow) }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("phrase.start")
      ActionNote(text: "Takes about two minutes. It can't be skipped.")
    }
  }

  /// Paper's line, where this build can get someone back in with the words alone
  /// (`recoverAccess`). The beta can't yet: there the words unlock a new iPhone only after
  /// signing in there (a Release copy exception, plan P1).
  private var newIPhone: String {
    model.capabilities.contains(.recoverAccess)
      ? "If your passkey isn't there, these words unlock your data. A password can't."
      : "They unlock your data on a new iPhone once you sign in there. A password can't."
  }

  private func point(_ icon: HIcon, _ hue: Hue, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      IconTile(icon: icon, hue: hue)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The words, hidden until tapped; hidden again when the app leaves the foreground or the
/// screen is captured (spec 04 §6.7), and not shown at all while it is captured. In create
/// mode "I've written them down" stays off until the words were shown (Paper F6Q), then
/// publishes them: there is no word check after this screen
/// (`docs/decisions/recovery-phrase-no-quiz.md`), so a reveal that drew only dots must not
/// count (`onCapture` tells the model).
struct PhraseShowView: View {
  @Binding var revealed: Bool
  var words: [String]
  var mode: Mode = .create
  var onBack: (() -> Void)?
  /// "I've written them down" (create) or "Done" (view).
  var onContinue: () -> Void
  /// Create mode: the words were shown at least once, so "I've written them down" can go.
  var seen = true
  /// Create mode: publishing is under way.
  var busy = false
  /// Create mode: why the last publish didn't go through.
  var failure: AuthFailure?
  /// Whether the screen is being recorded or mirrored, on appear and on every change.
  var onCapture: (Bool) -> Void = { _ in }

  enum Mode { case create, view }

  @Environment(\.scenePhase) private var scenePhase
  @State private var captured = PhraseShowView.screenCaptured()
  @State private var screenshotWarning = false

  /// The words are drawn (revealed and not masked by a capture).
  private var shown: Bool { revealed && !captured }

  var body: some View {
    AccountScreen(
      title: "Write these down, in order",
      subtitle: shown
        ? "On paper, numbered, in this order. Check each word twice."
        : "Check that no one can see your screen, then tap to show them.",
      steps: mode == .create ? (3, 3) : nil,
      // Creating, there is no way back (Paper S12); viewing, back closes the words.
      back: mode == .view ? onBack.map { AccountBack.action($0) } ?? AccountBack.none : AccountBack.none
    ) {
      VStack(alignment: .leading, spacing: shown ? 10 : 12) {
        PhraseGrid(words: words, revealed: $revealed, masked: captured)
        FailureBanner(failure: failure)
        if screenshotWarning {
          FailureBanner(failure: .badPhrase("That screenshot holds your recovery phrase. Delete it from Photos, and from Recently Deleted."))
        }
        WarningCallout(icon: .cameraSlash,
                       text: "No screenshots or copying. Photos sync to the cloud, and other apps can read your clipboard.")
      }
      // Revealed, the phrase header joins the card and the content moves up to make room
      // (Paper F9O-0: 12 under the question block, 10 apart; hidden, 24 and 12).
      .padding(.top, shown ? -12 : 0)
      .hAnimation(.stateSwap, value: shown)
    } actions: {
      if mode == .create {
        BusyButton(title: "I've written them down", busy: busy, enabled: seen, identifier: "phrase.written") {
          revealed = false
          onContinue()
        }
        ActionNote(text: "They hide again when you leave this screen.")
      } else {
        Button("Done", action: onContinue)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("phrase.done")
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { revealed = false }
    }
    .onAppear { noteCapture() }
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
      noteCapture()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
      screenshotWarning = revealed
    }
    .onDisappear { revealed = false }
  }

  /// Captured, the words hide and stay hidden until capture stops.
  private func noteCapture() {
    captured = Self.screenCaptured()
    if captured { revealed = false }
    onCapture(captured)
  }

  /// Whether any screen showing Hasala is being recorded or mirrored.
  static func screenCaptured() -> Bool {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { $0.screen.isCaptured }
  }
}

/// Recovery phrase · Saved → "Your account is ready." (Paper FJI-0; spec 07 S13): what the
/// account has (the address, how it signs in, the words on paper), then the hand-off to
/// setup, where the person connects their email. "What Hasala reads, and what it doesn't"
/// opens "Who can see what". No way back: the account exists.
struct AccountReadyView: View {
  var profile: AccountProfile?
  /// Outlook can be connected in this build ("Who can see what" names Microsoft only then).
  var outlook: Bool
  var onContinue: () -> Void

  @State private var whoSeesOpen = false
  @Environment(\.dynamicTypeSize) private var typeSize

  private var passkey: Bool { profile?.method != .password }

  var body: some View {
    CelebrationScreen(
      badge: .check,
      title: "Your account is ready.",
      subtitle: passkey
        ? "Keep the paper safe, away from this iPhone. You can see the words again in Profile after Face ID."
        : "Keep the paper safe, away from this iPhone. It's the only copy: your words can't be shown again on this account.",
      // Paper's 76 / 36, less the line the title takes when it wraps (the bundled Inter
      // sets "Your account is ready." wider than Paper does), so the summary clears the
      // hand-off at the default size.
      spacing: (56, 28)
    ) {
      VStack(spacing: 16) {
        summary
        // At the largest sizes the hand-off and the actions scroll with the rest rather
        // than fill the dock.
        if typeSize.isAccessibilitySize {
          handOff
          VStack(spacing: 4) { actions }.padding(.top, 16)
        }
      }
    } footer: {
      if !typeSize.isAccessibilitySize {
        handOff.padding(.bottom, 12)
        actions
      }
    }
    .sheet(isPresented: $whoSeesOpen) { WhoCanSeeSheet(outlook: outlook) }
  }

  /// Continue to setup, and what Hasala reads (the "Who can see what" sheet).
  @ViewBuilder private var actions: some View {
    Button("Continue", action: onContinue)
      .buttonStyle(.pill(.primary, fill: true))
      .accessibilityIdentifier("ready.continue")
    DockTextButton(title: "What Hasala reads, and what it doesn't", identifier: "ready.whoSees") {
      whoSeesOpen = true
    }
  }

  /// Paper "ListCard · Account summary": a green dot, what, and where it is.
  private var summary: some View {
    VStack(spacing: 0) {
      row(profile?.email ?? "", "Verified")
      divider
      row(passkey ? "Face ID passkey" : "Password", passkey ? "In iCloud Keychain" : "Set")
      divider
      row("Recovery phrase", "On paper")
    }
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private var divider: some View {
    Rectangle().fill(HColor.borderSubtle).frame(height: 1).padding(.leading, 35)
  }

  /// Paper's hand-off card ("Next: connect your email").
  private var handOff: some View {
    InfoCard(icon: .envelope, hue: .sky, title: "Next: connect your email",
             detail: "Hasala reads your bank's alert emails on this iPhone. Read-only, and only from your banks.")
  }

  private func row(_ title: String, _ value: String) -> some View {
    ReflowingRow(spacing: 12) {
      HStack(spacing: 12) {
        Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7).accessibilityHidden(true)
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary).lineLimit(1).truncationMode(.middle)
      }
    } trailing: {
      Text(value).hType(.subheadline).foregroundStyle(HColor.textSecondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(minHeight: 52)
    .accessibilityElement(children: .combine)
  }
}
