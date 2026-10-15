import HasalaDesign
import Observation
import SwiftUI

/// Unlock your data on a new iPhone (spec 04 §6.10): signed in, data sealed here. A
/// passkey with a PRF wrap unlocks in one glance; otherwise the 12 words do (S-14).
@MainActor
@Observable
final class UnlockModel {
  private let account: AccountService
  private let onUnlocked: () -> Void
  let passkeyCanUnlock: Bool
  var phraseText = ""
  var pastedChangeCount: Int?
  var enteringWords = false
  var busy = false
  var failure: AuthFailure?
  private(set) var unlocked = false

  init(account: AccountService, passkeyCanUnlock: Bool, onUnlocked: @escaping () -> Void) {
    self.account = account
    self.passkeyCanUnlock = passkeyCanUnlock
    self.onUnlocked = onUnlocked
  }

  func unlockWithPasskey() async {
    busy = true
    defer { busy = false }
    do {
      try await account.unlockWithPasskey()
      unlocked = true
    } catch .noCredential, .unsupported {
      // No PRF output: fall through to the words (S-28).
      failure = .badPhrase("Your passkey provider can't unlock Hasala on a new device. You'll use your recovery phrase instead.")
      enteringWords = true
    } catch {
      failure = error
    }
  }

  func unlockWithWords() async {
    switch PhraseRules.validate(phraseText) {
    case .failure(let f):
      failure = f
    case .success(let words):
      busy = true
      defer { busy = false }
      do {
        try await account.unlockWithPhrase(words)
        clearPastedPhrase(changeCount: pastedChangeCount)
        pastedChangeCount = nil
        phraseText = ""
        failure = nil
        unlocked = true
      } catch {
        failure = error
      }
    }
  }

  func openApp() { onUnlocked() }
}

struct UnlockView: View {
  @State private var model: UnlockModel
  var onSignOut: () -> Void

  init(model: UnlockModel, onSignOut: @escaping () -> Void) {
    _model = State(initialValue: model)
    self.onSignOut = onSignOut
  }

  /// The gate's entry point (plan B7.3): unlocking `session`'s data, with a passkey when
  /// the account's PRF wrap and this build allow it.
  init(session: AccountSession) {
    var passkeyCanUnlock = false
    if case .needsUnlock(let p) = session.phase { passkeyCanUnlock = p }
    self.init(
      model: UnlockModel(
        account: session.account, passkeyCanUnlock: passkeyCanUnlock && session.capabilities.contains(.signInPasskey),
        onUnlocked: { [weak session] in session?.unlocked() }),
      onSignOut: {
        Task {
          await session.account.signOut()
          session.signedOut()
        }
      })
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.unlocked {
          AccountScreen(title: "Welcome back", subtitle: "Your data is open on this iPhone again.",
                        wash: HColor.hueMintStart, centered: true) {
            SuccessBadge().frame(maxWidth: .infinity)
          } footer: {
            Button("Open Hasala") { model.openApp() }
              .buttonStyle(.pill(.primary, fill: true))
              .accessibilityIdentifier("unlock.open")
          }
        } else if model.enteringWords || !model.passkeyCanUnlock {
          words
        } else {
          choose
        }
      }
    }
  }

  private var choose: some View {
    AccountScreen(
      title: "Unlock your data",
      subtitle: "You're signed in. Use your passkey or your recovery phrase to unlock your data on this iPhone."
    ) {
      VStack(spacing: 12) {
        NoteCard(systemImage: "faceid", title: "Use Face ID (passkey)",
                 text: "Your passkey from iCloud Keychain opens your data in one glance.")
        NoteCard(systemImage: "doc.text", title: "Or your 12 words", text: "From the paper you wrote at signup.")
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: "Use Face ID (passkey)", busy: model.busy, identifier: "unlock.passkey") {
        Task { await model.unlockWithPasskey() }
      }
      LinkButton(title: "Enter my 12 words", identifier: "unlock.words") { model.enteringWords = true }
    }
  }

  private var words: some View {
    AccountScreen(
      title: "Enter your 12 words",
      subtitle: "You're signed in. Enter your recovery phrase to unlock your data on this iPhone.",
      onBack: model.passkeyCanUnlock ? { model.enteringWords = false } : nil
    ) {
      VStack(alignment: .leading, spacing: 12) {
        PhraseEntryField(text: $model.phraseText, pastedChangeCount: $model.pastedChangeCount)
        FailureBanner(failure: model.failure)
        if !model.passkeyCanUnlock {
          LockNote(text: "Your password signed you in. It can't unlock your data: that takes your 12 words.")
        }
      }
    } footer: {
      BusyButton(title: "Unlock", busy: model.busy, enabled: !model.phraseText.isEmpty, identifier: "unlock.submit") {
        Task { await model.unlockWithWords() }
      }
      LinkButton(title: "Sign out", identifier: "unlock.signOut", action: onSignOut)
    }
  }
}
