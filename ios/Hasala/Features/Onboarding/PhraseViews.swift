import HasalaDesign
import SwiftUI
import UIKit

// Paper page 14, section 14.2: the recovery phrase (spec 04 §6.7; copy S-08-S-13).

struct PhraseIntroView: View {
  var model: SignupModel

  var body: some View {
    AccountScreen(
      title: "12 words, your spare key",
      subtitle: "These 12 words were made on this iPhone. They unlock your data on a new iPhone, even if you lose every device and passkey, once you sign in there with your password or with a code we email you. A password only signs you in. Our server keeps the words only in a locked form it can't open.",
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
/// screen is captured (spec 04 §6.7).
struct PhraseShowView: View {
  @Binding var revealed: Bool
  var words: [String]
  var mode: Mode = .create
  var onBack: (() -> Void)?
  /// "I've written them down" (create) or "Done" (view).
  var onContinue: () -> Void

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
        if screenshotWarning {
          FailureBanner(failure: .badPhrase("That screenshot holds your recovery phrase. Delete it from Photos, and from Recently Deleted."))
        }
        NoteCard(systemImage: "camera.badge.ellipsis",
                 text: "No screenshots or copying. Photos sync to the cloud, and other apps can read your clipboard.",
                 tint: HColor.statusWarningSurface)
      }
    } footer: {
      if mode == .create {
        Button("I've written them down") {
          revealed = false
          onContinue()
        }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("phrase.written")
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

/// "Check 4 of your words": tap the right word for each slot (Paper "Check 4 random
/// words" / "wrong word"). Unlimited retries; a wrong word is taken back by tapping it.
struct PhraseConfirmView: View {
  @Bindable var model: SignupModel

  var body: some View {
    AccountScreen(
      title: "Check 4 of your words",
      subtitle: "Picked at random. Use your paper, not your memory. \(model.confirmedCount) of 4 done.",
      steps: (3, 3),
      onBack: model.back
    ) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(spacing: 8) {
          ForEach(0..<4, id: \.self) { i in slot(i) }
        }
        .padding(12)
        .listCard()
        if let w = model.wrongSlot {
          StatusLine(text: "That isn't word \(model.askedPositions[w] + 1). Check your paper, then tap the word to take it back.",
                     tone: .error)
        }
        FlowChips(words: model.choices, isUsed: model.isPlaced) { model.place($0) }
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: "Confirm", busy: model.busy, enabled: model.phraseConfirmed, identifier: "phrase.confirm") {
        Task { await model.finish() }
      }
      LinkButton(title: "Show my words again", identifier: "phrase.again") { model.showWordsAgain() }
    }
  }

  private func slot(_ i: Int) -> some View {
    let state = model.slotState(i)
    let word = model.placed[i]
    return Button {
      model.takeBack(i)
    } label: {
      HStack(spacing: 16) {
        Text("Word \(model.askedPositions.indices.contains(i) ? model.askedPositions[i] + 1 : 0)")
          .hType(.footnote.weight(.semibold))
          .foregroundStyle(state == .wrong ? HColor.statusErrorForeground : HColor.textSecondary)
          .frame(width: 64, alignment: .leading)
        Text(word ?? "")
          .hType(.headline)
          .foregroundStyle(state == .wrong ? HColor.statusErrorForeground : HColor.textPrimary)
        Spacer()
        if state == .right {
          Image(systemName: "checkmark").foregroundStyle(HColor.actionAccent).accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 46)
      .background(background(state), in: RoundedRectangle(cornerRadius: HRadius.control, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: HRadius.control, style: .continuous)
          .strokeBorder(state == .wrong ? HColor.statusErrorForeground : .clear, lineWidth: 1.5)
      }
    }
    .buttonStyle(.plain)
    .disabled(word == nil)
    .accessibilityLabel("Word \(model.askedPositions.indices.contains(i) ? model.askedPositions[i] + 1 : 0)")
    .accessibilityValue(word.map { "\($0), \(state == .wrong ? "wrong" : "right")" } ?? "empty")
    .accessibilityIdentifier("phrase.slot.\(i)")
  }

  private func background(_ s: SignupModel.SlotState) -> Color {
    switch s {
    case .empty: HColor.surfaceSecondary
    case .right: HColor.actionAccentSubtle
    case .wrong: HColor.statusErrorSurface
    }
  }
}

/// Word chips that wrap onto lines.
struct FlowChips: View {
  var words: [String]
  var isUsed: (String) -> Bool
  var onTap: (String) -> Void

  var body: some View {
    WrapLayout(spacing: 8) {
      ForEach(words, id: \.self) { w in
        let used = isUsed(w)
        Button(w) { onTap(w) }
          .hType(.rowTitle)
          .foregroundStyle(used ? HColor.textDisabled : HColor.textPrimary)
          .padding(.horizontal, 16)
          .frame(minHeight: 44)
          .background(used ? HColor.appleFillsTertiary : HColor.surfacePrimary, in: Capsule())
          .disabled(used)
          .accessibilityIdentifier("chip.\(w)")
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/// A simple wrapping layout (left to right, then down).
struct WrapLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += row + spacing
        row = 0
      }
      x += size.width + spacing
      maxX = max(maxX, x - spacing)
      row = max(row, size.height)
    }
    return CGSize(width: width.isFinite ? width : maxX, height: y + row)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += row + spacing
        row = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      row = max(row, size.height)
    }
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
