import HasalaDesign
import SwiftUI
import UIKit

// Paper page 14, section 14.2: the recovery phrase (spec 04 §6.7; copy S-08-S-13).

struct PhraseIntroView: View {
  var model: SignupModel

  /// Getting back in with the words and an emailed code (C4) is only promised when this
  /// build can do it (`recoverAccess`).
  private var subtitle: String {
    let made = "These 12 words were made on this iPhone."
    let rest = "A password only signs you in. Our server keeps the words only in a locked form it can't open."
    return model.capabilities.contains(.recoverAccess)
      ? "\(made) They unlock your data on a new iPhone, even if you lose every device and passkey, once you sign in there with your password or with a code we email you. \(rest)"
      : "\(made) They unlock your data on a new iPhone once you sign in there. \(rest)"
  }

  var body: some View {
    AccountScreen(
      title: "12 words, your spare key",
      subtitle: subtitle,
      steps: (3, 3)
    ) {
      VStack(alignment: .leading, spacing: 18) {
        point("doc.text", HColor.huePeachStart, HColor.huePeachInk, "Write them on paper",
              "Write them on paper, or save them in your password manager. If you leave Hasala to do that, come straight back: closing it before you finish makes a new phrase.")
        point("iphone", HColor.hueSkyStart, HColor.hueSkyInk, "No way back without them",
              "If you lose these words and every passkey, your data can't be unlocked on a new iPhone. Not even by us.")
        point("lock", HColor.hueRoseStart, HColor.hueRoseInk, "Keep them private",
              "These words are the key to your account. Anyone who has them and can sign in, or can get a code from your email, can read your transactions and add devices. Keep them private.")
      }
      .padding(18)
      .listCard()
    } footer: {
      Button("Show my 12 words") { model.go(.phraseShow) }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("phrase.start")
      Text("Takes about two minutes. It can't be skipped.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .frame(minHeight: 32)
    }
  }

  private func point(_ symbol: String, _ tint: Color, _ ink: Color, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      IconDisc(systemImage: symbol, tint: tint, ink: ink)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
        Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// The words, hidden until tapped; hidden again when the app leaves the foreground or the
/// screen is captured (spec 04 §6.7). In create mode "I've written them down" stays off
/// until the words were shown (Paper F6Q), then publishes them: there is no word check
/// after this screen (`docs/decisions/recovery-phrase-no-quiz.md`).
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

  enum Mode { case create, view }

  @Environment(\.scenePhase) private var scenePhase
  @State private var captured = PhraseShowView.screenCaptured()
  @State private var screenshotWarning = false

  var body: some View {
    AccountScreen(
      title: "Write these down, in order",
      subtitle: "On paper, numbered, in this order. Check each word twice.",
      steps: mode == .create ? (3, 3) : nil,
      onBack: onBack
    ) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Your recovery phrase").hType(.overline).foregroundStyle(HColor.textSecondary)
          Spacer()
          if revealed {
            Button {
              revealed = false
            } label: {
              Label("Hide", systemImage: "eye.slash").hType(.buttonSmall)
            }
            .foregroundStyle(HColor.textLink)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(HColor.surfacePrimary, in: Capsule())
            .accessibilityIdentifier("phrase.hide")
          }
        }
        ZStack {
          PhraseGrid(words: captured ? Array(repeating: "•••••", count: words.count) : words,
                     hidden: !revealed)
          if !revealed {
            Button {
              revealed = true
            } label: {
              Label("Tap to show your words", systemImage: "eye")
                .hType(.rowTitle)
                .foregroundStyle(HColor.textPrimary)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(HColor.surfacePrimary, in: Capsule())
                .elevation()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("phrase.reveal")
          }
        }
        FailureBanner(failure: failure)
        if screenshotWarning {
          FailureBanner(failure: .badPhrase("That screenshot holds your recovery phrase. Delete it from Photos, and from Recently Deleted."))
        }
        NoteCard(systemImage: "camera.badge.ellipsis",
                 text: "No screenshots or copying. Photos sync to the cloud, and other apps can read your clipboard.",
                 tint: HColor.statusWarningSurface)
      }
    } footer: {
      if mode == .create {
        BusyButton(title: "I've written them down", busy: busy, enabled: seen, identifier: "phrase.written") {
          revealed = false
          onContinue()
        }
        Text("They hide again when you leave this screen.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .frame(minHeight: 32)
      } else {
        Button("Done", action: onContinue)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("phrase.done")
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { revealed = false }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
      captured = Self.screenCaptured()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
      screenshotWarning = revealed
    }
    .onDisappear { revealed = false }
  }

  /// Whether any screen showing Hasala is being recorded or mirrored.
  static func screenCaptured() -> Bool {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { $0.screen.isCaptured }
  }
}

/// "Your account is ready." (Paper "Saved → hands off to Connect Gmail").
struct AccountReadyView: View {
  var profile: AccountProfile?
  var onContinue: () -> Void

  var body: some View {
    AccountScreen(
      title: "Your account is ready.",
      subtitle: profile?.method == .passkey
        ? "Keep the paper safe, away from this iPhone. You can see the words again in Profile after Face ID."
        : "Keep the paper safe, away from this iPhone. It's the only copy: your words can't be shown again on this account.",
      wash: HColor.hueMintStart,
      centered: true
    ) {
      VStack(spacing: 16) {
        SuccessBadge().frame(maxWidth: .infinity)
        VStack(spacing: 0) {
          row(profile?.email ?? "", "Verified")
          Divider().padding(.leading, 34)
          row(profile?.method == .password ? "Password" : "Face ID passkey",
              profile?.method == .password ? "Saved on this iPhone" : "In iCloud Keychain")
          Divider().padding(.leading, 34)
          row("Recovery phrase", "On paper")
        }
        .padding(.vertical, 4)
        .listCard()
        NoteCard(systemImage: "envelope", title: "Next: your bank",
                 text: "Pick your bank, then connect Gmail. Hasala reads your bank's alert emails on this iPhone. Read-only, and only from your banks.")
      }
    } footer: {
      Button("Continue", action: onContinue)
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("ready.continue")
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(spacing: 12) {
      Circle().fill(HColor.statusSuccessForeground).frame(width: 6, height: 6).accessibilityHidden(true)
      Text(title).hType(.callout).foregroundStyle(HColor.textPrimary).lineLimit(1).truncationMode(.middle)
      Spacer()
      Text(value).hType(.subheadline).foregroundStyle(HColor.textSecondary)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 52)
    .accessibilityElement(children: .combine)
  }
}
