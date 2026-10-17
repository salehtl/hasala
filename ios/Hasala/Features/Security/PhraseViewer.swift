import HasalaDesign
import SwiftUI
import UIKit

/// "View your 12 words" (Paper P2.5 ICI), after "Confirm it's you": a full-screen cover on
/// the account template, built on the shared `PhraseGrid` (not onboarding's phrase screen),
/// with the amber no-screenshots callout, Done, and the note that viewing them emailed you.
///
/// The privacy rules are onboarding's (spec 04 §6.7; c2 §12): hidden until tapped; hidden
/// again when the app leaves the foreground, when the cover goes, and while the screen is
/// recorded or mirrored (then not drawn at all, and the veil says why); a screenshot is
/// called out; nothing can be copied; the grid is `.privacySensitive()`. Closing the cover
/// drops the words from memory (`SecurityModel.closePhrase`).
struct PhraseViewer: View {
  @Bindable var model: SecurityModel

  @Environment(\.scenePhase) private var scenePhase
  @State private var captured = screenIsCaptured()
  @State private var screenshotWarning = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Your recovery phrase")
              .hType(.title1)
              .foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            Text("Shown after Face ID. Check them against your paper, then close.")
              .hType(.body)
              .foregroundStyle(HColor.textOnWashSecondary)
          }
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 16)
          VStack(alignment: .leading, spacing: 10) {
            PhraseGrid(words: model.viewedPhrase ?? [], revealed: $model.phraseRevealed, masked: captured)
            if screenshotWarning {
              FailureBanner(failure: .badPhrase("That screenshot holds your recovery phrase. Delete it from Photos, and from Recently Deleted."))
            }
            WarningCallout(icon: .cameraSlash,
                           text: "No screenshots or copying. Photos sync to the cloud, and other apps can read your clipboard.")
          }
          .padding(.top, 12)
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 16)
      }
      .scrollBounceBehavior(.basedOnSize)
      .scrollEdgeEffectStyle(.soft, for: .bottom)
      .safeAreaBar(edge: .bottom) {
        AccountDock {
          Button("Done") { close() }
            .buttonStyle(.pill(.primary, fill: true))
            .accessibilityIdentifier("phrase.done")
          ActionNote(text: "We've emailed you that they were viewed.")
        }
      }
      .background(alignment: .top) {
        AmbientWash(.setup).ignoresSafeArea(edges: .top)
      }
      .background(HColor.surfaceSecondary)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          // Paper ICI's glass Close draws its cross in ink, not the accent.
          Button(role: .close) { close() }
            .tint(HColor.appleLabelsVibrantPrimary)
            .accessibilityIdentifier("phrase.close")
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { model.phraseRevealed = false }
    }
    .onAppear { noteCapture() }
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
      noteCapture()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
      screenshotWarning = model.phraseRevealed
    }
    // However the cover goes (Done, Close, the session ending under it), the words go
    // with it.
    .onDisappear { model.closePhrase() }
  }

  private func close() {
    model.phraseRevealed = false
    model.closePhrase()
  }

  /// Captured, the words hide and stay hidden until capture stops.
  private func noteCapture() {
    captured = screenIsCaptured()
    if captured { model.phraseRevealed = false }
  }
}
