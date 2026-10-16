import HasalaDesign
import Observation
import SwiftUI

/// Unlock your data on a new iPhone (spec 04 §6.10; Paper P2.3 G80, K34, GDD, GJJ, GL7):
/// signed in, data sealed here. A passkey with a PRF wrap unlocks in one glance; otherwise
/// the 12 words do (S-14). A password never does.
@MainActor
@Observable
final class UnlockModel {
  /// What opens the data here: the passkey's PRF wrap, or the 12 words.
  enum Way: Equatable { case passkey, words }

  /// Where the unlock is: choosing a way, opening the data, or open.
  enum Stage: Equatable {
    case choosing
    case unlocking(Way)
    case unlocked
  }

  /// The pages pushed over the choice: the words, and the honest end.
  enum Route: Hashable { case words, honestEnd }

  let account: AccountService
  private let onUnlocked: () -> Void
  let passkeyCanUnlock: Bool
  var path: [Route] = []
  private(set) var stage: Stage = .choosing
  var phraseText = ""
  var pastedChangeCount: Int?
  var busy = false
  var failure: AuthFailure?
  /// The failure came from the words (it shows on the entry page, not the choice).
  private(set) var failedOnWords = false
  /// How this iPhone was unlocked (Welcome back offers a passkey after the words).
  private(set) var unlockedWith: Way?
  /// "Add a passkey" on Welcome back: the confirmation is up.
  var addingPasskey = false
  var confirmPassword = ""
  private(set) var passkeyAdded = false

  init(account: AccountService, passkeyCanUnlock: Bool, onUnlocked: @escaping () -> Void) {
    self.account = account
    self.passkeyCanUnlock = passkeyCanUnlock
    self.onUnlocked = onUnlocked
  }

  var unlocked: Bool { stage == .unlocked }
  var capabilities: AccountCapabilities { account.capabilities }
  var profile: AccountProfile? { account.profile }

  /// "Enter my 12 words" / "Enter words".
  func enterWords() {
    failure = nil
    failedOnWords = false
    path = [.words]
  }

  /// "I don't have my words" / "I don't have either".
  func noWords() {
    failure = nil
    path = [.honestEnd]
  }

  func unlockWithPasskey() async {
    busy = true
    failure = nil
    stage = .unlocking(.passkey)
    defer { busy = false }
    do {
      try await account.unlockWithPasskey()
      unlockedWith = .passkey
      stage = .unlocked
    } catch .cancelled {
      // The person closed Face ID: back to the choice, nothing to say.
      stage = .choosing
    } catch .noCredential, .unsupported {
      // No PRF output: the words instead (S-28).
      stage = .choosing
      failure = .badPhrase("Your passkey provider can't unlock Hasala on a new device. Use your recovery phrase instead.")
      failedOnWords = true
      path = [.words]
    } catch {
      stage = .choosing
      failedOnWords = false
      failure = error
    }
  }

  /// The words are checked here first (length, list, checksum), then opened by the
  /// service; a refusal goes back to the entry with the words kept.
  func unlockWithWords() async {
    switch PhraseRules.validate(phraseText) {
    case .failure(let f):
      failure = f
      failedOnWords = true
    case .success(let words):
      busy = true
      failure = nil
      // The progress replaces the entry where it stands, without a pop that looks like Back.
      var quiet = Transaction()
      quiet.disablesAnimations = true
      withTransaction(quiet) {
        path = []
        stage = .unlocking(.words)
      }
      defer { busy = false }
      do {
        try await account.unlockWithPhrase(words)
        clearPastedPhrase(changeCount: pastedChangeCount)
        pastedChangeCount = nil
        phraseText = ""
        unlockedWith = .words
        stage = .unlocked
      } catch {
        stage = .choosing
        failure = error
        failedOnWords = true
        path = [.words]
      }
    }
  }

  /// Welcome back offers a passkey to a password account that opened with its words, in a
  /// build that can add one (Paper GL7 "Offers a passkey").
  var offersPasskey: Bool {
    capabilities.contains(.addPasskey) && unlockedWith == .words && profile?.method != .passkey && !passkeyAdded
  }

  /// "Add a passkey": its step-up is the password and this iPhone's new key (P2.6).
  func addPasskey() async {
    let pw = confirmPassword
    busy = true
    defer { busy = false }
    do {
      try await account.perform(.addPasskey, password: pw)
      confirmPassword = ""
      passkeyAdded = true
      addingPasskey = false
      failure = nil
    } catch .cancelled {
      // Face ID or the passkey sheet closed: the sheet stays.
    } catch {
      confirmPassword = ""
      failure = error
    }
  }

  func openApp() { onUnlocked() }
}

struct UnlockView: View {
  @State private var model: UnlockModel
  var onSignOut: () -> Void
  @FocusState private var typing: Bool

  /// A password reset another iPhone approved led here (Paper GUM: "You're in. Your data
  /// is still locked.").
  @Environment(OnboardingStore.self) private var store: OnboardingStore?

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

  private var afterReset: Bool { store?.signIn.resetApproved ?? false }

  var body: some View {
    NavigationStack(path: $model.path) {
      root
        .navigationDestination(for: UnlockModel.Route.self) { route in
          switch route {
          case .words: words
          case .honestEnd:
            HonestEndScreen(
              context: .unlock, onFoundWords: { model.enterWords() }, onSignOut: onSignOut)
          }
        }
    }
    #if HASALA_MOCKS
      .task { await ScreenLaunch.applyUnlockLaunch(model) }
    #endif
  }

  @ViewBuilder private var root: some View {
    switch model.stage {
    case .choosing: choose
    case .unlocking(let method): unlocking(method)
    case .unlocked: welcomeBack
    }
  }

  // MARK: Choose (G80, K34, GUM)

  private var signedInAs: String {
    guard let email = model.profile?.email, !email.isEmpty else { return "You're signed in." }
    return "You're signed in as \(email)."
  }

  private var choose: some View {
    HeroAccountScreen(
      hero: HeroDisc(icon: .lock, hue: .sand),
      title: afterReset ? "You're in. Your data is still locked." : "Unlock your data",
      subtitle: afterReset
        ? "Your other iPhone let you in, but it can't hand over your data. Your 12 words open it on this iPhone. A new password never can."
        : model.passkeyCanUnlock
          ? "\(signedInAs) Your budget is still sealed. Open it on this iPhone with one of these."
          : "\(signedInAs) Your budget is still sealed. Your 12 words open it on this iPhone."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if model.passkeyCanUnlock && !afterReset {
          OptionCard(icon: .faceID, hue: .sky, chip: "Fastest", title: "Use your passkey",
                     detail: "If it synced to this iPhone through iCloud Keychain, Face ID opens everything.",
                     buttonTitle: "Unlock with Face ID", buttonKind: .primary, buttonIcon: .faceID,
                     busy: model.busy, identifier: "unlock.passkey") {
            Task { await model.unlockWithPasskey() }
          }
          OptionCard(icon: .paper, hue: .sand, title: "Enter your recovery phrase",
                     detail: "From the paper you wrote when you joined.", buttonTitle: "Enter words",
                     identifier: "unlock.words") { model.enterWords() }
        } else {
          OptionCard(icon: .paper, hue: .sand, title: "Have your paper ready",
                     detail: "The 12 words you wrote down when you joined. Once per iPhone.",
                     buttonTitle: "Enter my 12 words", buttonKind: .primary, identifier: "unlock.words") {
            model.enterWords()
          }
        }
        if !model.failedOnWords { FailureBanner(failure: model.failure) }
        if !afterReset {
          NoteRow(icon: .shield,
                  text: "A password can't do this, on purpose. Someone with your password still can't open your budget.")
        }
      }
    } footer: {
      SecondaryLink(title: model.passkeyCanUnlock && !afterReset ? "I don't have either" : "I don't have my words",
                    identifier: "unlock.noWords") { model.noWords() }
    }
  }

  // MARK: Enter 12 words (GDD)

  private var words: some View {
    let state = PhraseEntryState(model.phraseText)
    return AccountScreen(
      title: "Enter your recovery phrase",
      subtitle: "In the order on your paper. \(state.finished) of 12 so far.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        PhraseEntryGrid(text: $model.phraseText, pastedChangeCount: $model.pastedChangeCount, focused: $typing) {
          Task { await model.unlockWithWords() }
        }
        if model.failedOnWords { FailureBanner(failure: model.failure) }
      }
      .id(PhraseEntryGrid.revealID)
      .accountContentTop(16)
    } footer: {
      // Return opens with the twelfth word (Paper draws no button); the button shows once
      // the keyboard is down.
      if typing, !model.busy {
        PhraseSuggestions(text: $model.phraseText)
      } else {
        BusyButton(title: "Unlock", busy: model.busy, enabled: state.isComplete, identifier: "unlock.submit") {
          Task { await model.unlockWithWords() }
        }
      }
    }
    .revealsPhraseEntry(model.phraseText)
  }

  // MARK: Unlocking (GJJ)

  private func unlocking(_ method: UnlockModel.Way) -> some View {
    ProgressCelebrationScreen(
      title: "Unlocking your data",
      subtitle: "Keep Hasala open. It takes about a minute, and everything is opened here on this iPhone."
    ) {
      // The service reports no progress: the words are checked here before it starts, the
      // rest is under way together.
      StatusListCard(rows: method == .words
        ? [
          StatusListRow(title: "Words checked", value: "Done", state: .done),
          StatusListRow(title: "Downloading sealed copy", value: "Now", state: .active),
          StatusListRow(title: "Opening it on this iPhone", value: "Next", state: .pending),
        ]
        : [
          StatusListRow(title: "Your passkey", value: "Now", state: .active),
          StatusListRow(title: "Downloading sealed copy", value: "Next", state: .pending),
          StatusListRow(title: "Opening it on this iPhone", value: "Next", state: .pending),
        ])
    } foot: {
      InfoCard(icon: .shieldCheck, hue: .mint, title: "Sealed all the way here",
               detail: "We only ever hold the locked copy. It's opened here, on this iPhone, and the key never leaves it.")
    }
    .accessibilityIdentifier("unlock.unlocking")
  }

  // MARK: Welcome back (GL7)

  private var welcomeBack: some View {
    let name = model.profile?.firstName ?? ""
    return CelebrationScreen(
      badge: .check,
      title: name.isEmpty ? "Welcome back." : "Welcome back, \(name).",
      subtitle: "Everything is here and unlocked on this iPhone. We emailed you about this new sign-in."
    ) {
      EmptyView()
    } footer: {
      if model.offersPasskey {
        InfoCard(icon: .faceID, hue: .sky, title: "Add a passkey to this iPhone",
                 detail: "Next time Face ID signs you in and unlocks everything, no paper needed.")
          .padding(.bottom, 12)
        Button("Add a passkey") {
          model.confirmPassword = ""
          model.failure = nil
          model.addingPasskey = true
        }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("unlock.addPasskey")
        Button("Go to Home") { model.openApp() }
          .buttonStyle(.pill(.tertiary, fill: true))
          .accessibilityIdentifier("unlock.open")
      } else {
        Button("Go to Home") { model.openApp() }
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("unlock.open")
      }
    }
    .sheet(isPresented: $model.addingPasskey) {
      ConfirmItsYouSheet(
        request: ConfirmRequest(
          title: "Add a passkey", factor: .password,
          bullets: ["iOS asks where to save it next", "Then Face ID signs you in and unlocks your data"]),
        password: $model.confirmPassword, busy: model.busy, failure: model.failure,
        onConfirm: { Task { await model.addPasskey() } },
        onClose: { model.addingPasskey = false })
    }
  }
}
