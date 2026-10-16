import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

// Paper P2.3–P2.4 (spec 08): sign in (Face ID first, then the email and password), forgot
// password on a new iPhone, access recovery and the honest end. Each screen shows only the
// failure that happened on it (`SignInModel.failure(on:)`).

/// "Welcome back" (Paper FPI; wrong password FWD): the passkey first, then "or use your
/// email" with the address and password, then recovery at the foot. A wrong password rings
/// the password box with one line under it; the email is not marked, since the answer
/// doesn't say which was wrong. What this build can't do becomes a support link.
struct SignInView: View {
  @Bindable var model: SignInModel
  /// What this build can do (`AccountSession.capabilities`): a missing sign-in method is
  /// not offered, and a missing reset or recovery becomes a support email link.
  var capabilities: AccountCapabilities = .all
  var onForgot: () -> Void
  var onRecover: () -> Void
  var onJoin: () -> Void

  @State private var passwordVisible = false
  @FocusState private var focus: Field?

  enum Field: Hashable { case email, password }

  private var passkey: Bool { capabilities.contains(.signInPasskey) }
  private var password: Bool { capabilities.contains(.signInPassword) }
  private var failure: AuthFailure? { model.failure(on: .signIn) }
  private var passwordFailure: AuthFailure? { model.lastTried == .password ? failure : nil }
  private var passkeyFailure: AuthFailure? { model.lastTried == .passkey ? failure : nil }

  var body: some View {
    AccountScreen(title: "Welcome back", subtitle: "Sign in to Hasala.", back: .system) {
      VStack(alignment: .leading, spacing: 12) {
        if passkey { passkeyGroup }
        if passkey && password { OrDivider(label: "or use your email") }
        if password { passwordFields }
      }
    } footer: {
      if capabilities.contains(.recoverAccess) {
        SecondaryLink(title: "Can't get in at all? Recover your account", identifier: "signIn.recover", action: onRecover)
      }
      if !capabilities.isSuperset(of: [.resetPassword, .recoverAccess]) {
        SupportLink(lead: "Trouble signing in?", identifier: "signIn.support")
      }
    }
  }

  private var passkeyGroup: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button("Sign in with Face ID") {
        focus = nil
        Task { await model.signInWithPasskey() }
      }
      .buttonStyle(.pill(.primary, fill: true, loading: model.signingIn == .passkey, leadingIcon: .faceID))
      .disabled(model.busy && model.signingIn != .passkey)
      .accessibilityIdentifier("signIn.passkey")
      Text("Uses the passkey in your iCloud Keychain.")
        .hType(.footnote)
        .foregroundStyle(HColor.textOnWashSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
      if passkeyFailure == .orphanedPasskey {
        FailureBanner(failure: passkeyFailure)
        HStack {
          Button("I have an invite", action: onJoin).buttonStyle(.pill(.secondary, size: .medium))
          Button("Try again") { Task { await model.signInWithPasskey() } }
            .buttonStyle(.pill(.tertiary, size: .medium))
        }
      } else if passkeyFailure == .noCredential {
        FailureBanner(failure: passkeyFailure)
        if password {
          Text("Use your email instead.").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
      } else {
        FailureBanner(failure: passkeyFailure)
      }
    }
  }

  @ViewBuilder private var passwordFields: some View {
    AccountField("Email", focused: focus == .email) {
      EmailInput(text: $model.email, identifier: "signIn.email")
        .focused($focus, equals: .email)
        .submitLabel(.next)
        .onSubmit { focus = .password }
    }
    passwordBox
    Button {
      focus = nil
      Task { await model.signInWithPassword() }
    } label: {
      // Paper draws this label in text-primary on the white pill (spec 08 §2.3).
      Text("Sign in with password")
        .foregroundStyle(model.passwordSignInReady ? HColor.textPrimary : HColor.textDisabled)
    }
    .buttonStyle(.pill(.onGrouped, fill: true, loading: model.signingIn == .password))
    .disabled(!model.passwordSignInReady || (model.busy && model.signingIn != .password))
    .accessibilityIdentifier("signIn.withPassword")
    if let other = passwordFailure, other != .wrongCredentials {
      FailureBanner(failure: other)
    }
  }

  /// The password box with "Forgot password?" in its label row (Paper FPI) and, after a
  /// wrong password, the error ring and line (FWD). The password itself is cleared after a
  /// failure (c2 §12 rule 7), so the box shows its placeholder under the ring.
  private var passwordBox: some View {
    VStack(alignment: .leading, spacing: HSpacing.fieldLabelGap) {
      HStack {
        Text("Password")
          .hType(.footnote.weight(.semibold))
          .foregroundStyle(HColor.textSecondary)
        Spacer(minLength: 8)
        if capabilities.contains(.resetPassword) {
          // A 44 target that keeps the label row at Paper's 20.
          InlineTextButton(title: "Forgot password?", identifier: "signIn.forgot", action: onForgot)
            .padding(.vertical, -12)
        }
      }
      HStack(spacing: 8) {
        Group {
          if passwordVisible {
            TextField("Your password", text: $model.password)
          } else {
            SecureField("Your password", text: $model.password)
          }
        }
        .textContentType(.password)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .hType(HType(size: 17, leading: 22, weight: .regular, textStyle: .body))
        .foregroundStyle(HColor.fieldText)
        .tint(HColor.actionAccent)
        .focused($focus, equals: .password)
        .submitLabel(.go)
        .onSubmit {
          // Return signs in, as the keyboard says.
          guard model.passwordSignInReady, !model.busy else { return }
          focus = nil
          Task { await model.signInWithPassword() }
        }
        .onChange(of: model.password) { _, _ in model.passwordEdited() }
        .accessibilityIdentifier("signIn.password")
        .accessibilityHint(wrongPassword.map { "Error: \($0)" } ?? "")
        // The label above is read as text (it shares its row with "Forgot password?", so
        // it can't be the field's name, and hidden it would be drawn text with no
        // element); the field reads its placeholder. It fills the box's height.
        .frame(maxWidth: .infinity, minHeight: HSpacing.fieldMinHeight, alignment: .leading)
        ShowHidePill(visible: $passwordVisible)
      }
      .padding(.leading, HSpacing.fieldInsetInline)
      .padding(.trailing, 8)
      .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
      .overlay {
        FieldRing(color: wrongPassword != nil ? HColor.fieldError : focus == .password ? HColor.fieldFocus : .clear)
      }
      // A tap anywhere in the box focuses the field, alongside the field's own tap.
      .contentShape(RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
      .simultaneousGesture(TapGesture().onEnded { focus = .password })
      if let wrongPassword {
        FieldErrorLine(text: wrongPassword)
          .padding(.top, 2)
          .accessibilityIdentifier("signIn.wrongPassword")
      }
    }
    .hAnimation(.fade, value: wrongPassword == nil)
  }

  /// FWD's line. Without an in-app reset (the beta), "or reset your password" would promise
  /// something this build doesn't do; the support link below says where to turn instead.
  private var wrongPassword: String? {
    guard passwordFailure == .wrongCredentials else { return nil }
    return capabilities.contains(.resetPassword)
      ? AuthFailure.wrongCredentials.message
      : "That email and password don't match. Try again."
  }
}

// MARK: - Forgot password (C9 side N)

/// Forgot password · 1 of 4 · "Reset your password" (Paper GQL). The same answer whether
/// or not an account has the address.
struct ForgotEmailView: View {
  @Bindable var model: SignInModel
  var onBack: () -> Void
  var onNext: () -> Void

  var body: some View {
    AccountScreen(
      title: "Reset your password", subtitle: "We'll email a 6-digit code to your account's address.",
      steps: (1, 4), back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        AccountField("Email", help: "If there's an account for this email, the code arrives within a minute.",
                     error: model.failure(on: .forgotEmail)?.message) {
          EmailInput(text: $model.resetEmail, identifier: "forgot.email")
        }
        .padding(.bottom, 8)
        CardNote(icon: .shieldCheck,
                 text: "A code alone can't reset it. Next we'll ask for your 12 words, or a yes from an iPhone where you're still signed in.")
      }
    } footer: {
      BusyButton(title: "Send code", busy: model.busy, enabled: AccountFields.email(model.resetEmail) != nil,
                 identifier: "forgot.send") {
        Task { if await model.submitResetEmail() { onNext() } }
      }
      SecondaryLink(title: "Back to sign in", identifier: "forgot.back", action: onBack)
    }
  }
}

/// Forgot password · 3 of 4 · "One more check" (Paper KH7): the other iPhone's yes, or the
/// 12 words. The first card shows only when another signed-in iPhone can answer.
struct ForgotCheckView: View {
  var model: SignInModel
  var onApprove: () -> Void
  var onWords: () -> Void
  var onNeither: () -> Void

  var body: some View {
    AccountScreen(
      title: "One more check",
      subtitle: "The code worked. To change your password we also need one of these.",
      steps: (3, 4), back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if model.canApproveOnOtherPhone {
          OptionCard(icon: .phone, hue: .sky, title: "Approve on your other iPhone",
                     detail: "Your other iPhone is still signed in. Say yes there with Face ID.",
                     buttonTitle: "Send a request", buttonKind: .primary, identifier: "forgot.approve",
                     action: onApprove)
        }
        OptionCard(icon: .paper, hue: .sand, title: "Enter your recovery phrase",
                   detail: "From your paper. They unlock your data on this iPhone too.", buttonTitle: "Enter words",
                   buttonKind: model.canApproveOnOtherPhone ? .secondary : .primary, identifier: "forgot.words",
                   action: onWords)
        NoteRow(icon: .shield,
                text: "Why not just the code? The company that delivers our email also carries our web traffic, so a code alone can't be the proof.")
      }
      .accountContentTop(20)
    } footer: {
      SecondaryLink(title: "I have neither", identifier: "forgot.neither", action: onNeither)
    }
  }
}

/// Forgot password · 4 of 4 · "Choose a new password" (Paper GS6). The service binds the
/// new password to the request (spec 04 §16.4), so it comes before the other iPhone's yes;
/// it takes effect once that yes arrives.
struct ForgotNewPasswordView: View {
  @Bindable var model: SignInModel
  var onCancel: () -> Void
  var onNext: () -> Void

  var body: some View {
    AccountScreen(
      title: "Choose a new password", subtitle: "12 characters or more, and different from your old one.",
      steps: (4, 4), back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        NewPasswordFields(password: $model.newPassword, confirm: $model.confirmPassword,
                          assessment: model.newPasswordAssessment)
        NoteRow(icon: .lock,
                text: "Saving signs out other sessions that used the old password, and we email you that it changed.")
        FailureBanner(failure: model.failure(on: .forgotNewPassword))
      }
    } footer: {
      BusyButton(title: "Save new password", busy: model.busy, enabled: model.newPasswordReady,
                 identifier: "forgot.request") {
        Task { if await model.requestApproval() { onNext() } }
      }
      SecondaryLink(title: "Cancel", identifier: "forgot.cancel", action: onCancel)
    }
  }
}

/// A new password, its strength and the repeat (Paper GS6, H43's password): the account
/// template's strength card and match line, without the signup block's intro.
struct NewPasswordFields: View {
  @Binding var password: String
  @Binding var confirm: String
  var assessment: PasswordAssessment

  private var matches: Bool { !confirm.isEmpty && confirm == password }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LabeledField(label: "Password") {
        PasswordInput(placeholder: "12 characters or more", text: $password, isNew: true, identifier: "password.new")
      }
      if !password.isEmpty {
        PasswordStrengthCard(assessment: assessment)
          .hTransition(.rise)
      }
      VStack(alignment: .leading, spacing: 8) {
        LabeledField(label: "Type it again",
                     error: !confirm.isEmpty && !matches && confirm.count >= password.count ? "Passwords don't match." : nil) {
          PasswordInput(placeholder: "Same password", text: $confirm, isNew: true, identifier: "password.confirm")
        }
        if matches {
          StatusLine(text: "Passwords match.", tone: .success)
        }
      }
      .padding(.top, 4)
    }
    .hAnimation(.rise, value: password.isEmpty)
  }
}

/// Forgot password · "Check your other iPhone" (Paper KIL): the code the other iPhone asks
/// for, a countdown while the request waits, and the words as the way out. Paper matches a
/// two-digit number; the service's reset code is 16 characters that the other iPhone types
/// (spec 04 §6.1.4), so the card shows those.
struct ForgotWaitingView: View {
  var model: SignInModel
  var onWords: () -> Void

  var body: some View {
    AccountScreen(
      title: "Check your other iPhone",
      subtitle: "Open Hasala on your other iPhone, type this code there, then confirm with Face ID.",
      steps: (4, 4), back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        matchCard
        HStack(alignment: .top, spacing: 12) {
          HIconView(.phone, size: 20, color: HColor.iconSecondary)
          Text("Nothing showing there? Open Hasala on that iPhone; the request waits at the top. It only says yes, and never sends your password or your data.")
            .hType(HType(size: 14, leading: 20, weight: .regular, textStyle: .subheadline))
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        FailureBanner(failure: model.failure(on: .forgotWaiting))
      }
      .accountContentTop(20)
    } footer: {
      SecondaryLink(title: "Use my 12 words instead", identifier: "forgot.useWords", action: onWords)
    }
    .task { await model.waitForApproval() }
  }

  /// Paper "MatchNumberCard": the overline, the code large, and the waiting pill with the
  /// time left.
  private var matchCard: some View {
    VStack(spacing: 6) {
      Text("Type this on your other iPhone")
        .hType(.overline)
        .foregroundStyle(HColor.textSecondary)
      Text(model.resetCodeGroups)
        .font(.system(.title, design: .monospaced).weight(.bold))
        .foregroundStyle(HColor.textPrimary)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityLabel(model.resetCodeGroups.map { String($0) }.joined(separator: " "))
        .accessibilityIdentifier("forgot.resetCode")
        .padding(.vertical, 6)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let left = model.approvalDeadline.map { max(0, $0.timeIntervalSince(context.date)) } ?? 0
        HStack(spacing: 8) {
          Circle().fill(HColor.statusInfoForeground).frame(width: 8, height: 8)
          Text(left > 0 ? "Waiting for a yes · \(ResendRow.clock(left)) left" : "Waiting for a yes")
            .hType(HType(size: 14, leading: 18, weight: .semibold, textStyle: .subheadline))
            .foregroundStyle(HColor.statusInfoForeground)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(HColor.statusInfoSurface, in: Capsule())
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.top, 28)
    .padding(.bottom, 24)
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

// MARK: - Access recovery (C4): the words first, then the code

/// "Recover your account" (Paper GYP): the two things it takes. The service asks for the
/// words first and sends the code to the account their key belongs to, so there is no email
/// field here (Paper's order is the email first).
struct RecoverIntroView: View {
  var onStart: () -> Void
  var onNoWords: () -> Void

  var body: some View {
    AccountScreen(
      title: "Recover your account",
      subtitle: "For when you can't sign in and your passkey is gone. You'll need both of these.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        NeedsCard {
          NeedRow(icon: .envelope, hue: .sky, title: "Your email inbox",
                  detail: "For a 6-digit code. On its own, it's not enough.")
          NeedRow(icon: .paper, hue: .sand, title: "Your 12-word recovery phrase",
                  detail: "It proves the account is yours and unlocks your data.")
        }
        WarningNote(text: "No one at Hasala can reset your words or open your data for you. That's what keeps it private.")
      }
    } footer: {
      Button("Enter my 12 words", action: onStart)
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("recover.start")
      SecondaryLink(title: "I don't have my 12 words", identifier: "recover.noWords", action: onNoWords)
    }
  }
}

/// Recover account · "Enter your recovery phrase" (Paper GZT): the entry grid; the code
/// goes out once the 12 are in.
struct RecoverWordsView: View {
  @Bindable var model: SignInModel
  var onNext: () -> Void
  @FocusState private var typing: Bool

  var body: some View {
    let state = PhraseEntryState(model.phraseText)
    AccountScreen(
      title: "Enter your recovery phrase",
      subtitle: "They prove the account is yours and unlock your data. \(state.finished) of 12 so far.",
      steps: (1, 3), back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        PhraseEntryGrid(text: $model.phraseText, pastedChangeCount: $model.pastedPhraseChangeCount, focused: $typing) {
          submit()
        }
        FailureBanner(failure: model.failure(on: .recoverWords))
      }
      .id(PhraseEntryGrid.revealID)
      .accountContentTop(16)
    } footer: {
      // Return sends the twelfth word (Paper draws no button); the button shows once the
      // keyboard is down, or while the code goes out.
      if typing, !model.busy {
        PhraseSuggestions(text: $model.phraseText)
      } else {
        BusyButton(title: "Send code", busy: model.busy, enabled: state.isComplete, identifier: "recover.words") {
          submit()
        }
      }
    }
    .revealsPhraseEntry(model.phraseText)
  }

  private func submit() {
    Task {
      if await model.submitRecoveryWords() {
        clearPastedPhrase(changeCount: model.pastedPhraseChangeCount)
        model.pastedPhraseChangeCount = nil
        onNext()
      }
    }
  }
}

/// Recover account · "Set a new way to sign in" (Paper H43): a passkey (recommended) or a
/// password. Then "You're back in" (H5V) in its place.
struct RecoverMethodView: View {
  @Bindable var model: SignInModel
  var onPassword: () -> Void
  var onResult: (SignInModel.RecoveryResult) -> Void
  @State private var choice: SignInMethod = .passkey

  var body: some View {
    if let method = model.recovered {
      BackInView(model: model, method: method)
    } else {
      AccountScreen(
        title: "Set a new way to sign in",
        subtitle: "Your old passkeys and password stop working, and other devices are signed out.",
        steps: (3, 3), back: .system
      ) {
        VStack(alignment: .leading, spacing: 12) {
          SelectionCard(icon: .faceID, hue: .sky, chip: "Recommended", title: "Use Face ID (passkey)",
                        detail: "Nothing to remember or type. Your passkey is saved in iCloud Keychain, and it unlocks your data on a new iPhone.",
                        selected: choice == .passkey, identifier: "recover.choosePasskey") { choice = .passkey }
          SelectionCard(icon: .password, hue: .other, title: "Use a password",
                        detail: "Signs you in anywhere you can type. It can't unlock your data on a new iPhone; your 12 words will do that job.",
                        selected: choice == .password, identifier: "recover.choosePassword") { choice = .password }
          FailureBanner(failure: model.failure(on: .recoverMethod))
        }
      } footer: {
        if choice == .passkey {
          BusyButton(title: "Continue with Face ID", busy: model.busy, identifier: "recover.passkey") {
            Task { onResult(await model.finishRecovery(.passkey)) }
          }
        } else {
          BusyButton(title: "Continue", busy: false, identifier: "recover.password", action: onPassword)
        }
        // As on join's "How do you want to sign in?" (Paper H43 "What's a passkey?").
        WebLink(title: "What's a passkey?", url: "https://support.apple.com/102195", identifier: "recover.whatsAPasskey")
      }
    }
  }
}

/// Recover account · a new password (H43 with "Use a password"), then "You're back in".
struct RecoverPasswordView: View {
  @Bindable var model: SignInModel
  var onResult: (SignInModel.RecoveryResult) -> Void

  var body: some View {
    if let method = model.recovered {
      BackInView(model: model, method: method)
    } else {
      AccountScreen(title: "Choose a password", subtitle: "12 characters or more.", steps: (3, 3), back: .system) {
        VStack(alignment: .leading, spacing: 12) {
          NewPasswordFields(password: $model.newPassword, confirm: $model.confirmPassword,
                            assessment: model.newPasswordAssessment)
          FailureBanner(failure: model.failure(on: .recoverPassword))
        }
      } footer: {
        BusyButton(title: "Finish", busy: model.busy, enabled: model.newPasswordReady, identifier: "recover.finish") {
          Task { onResult(await model.finishRecovery(.password(model.newPassword))) }
        }
      }
    }
  }
}

/// "You're back in" (Paper H5V): what changed, a word on the old phrase, then Home.
private struct BackInView: View {
  let model: SignInModel
  let method: SignInMethod

  var body: some View {
    let name = model.firstName
    let email = model.accountEmail
    CelebrationScreen(
      badge: .check,
      title: name.isEmpty ? "You're back in." : "You're back in, \(name).",
      subtitle: "Your data is unlocked on this iPhone. We've emailed \(email.isEmpty ? "you" : email) that your words were used."
    ) {
      StatusListCard(rows: [
        method == .passkey
          ? StatusListRow(title: "New passkey", value: "In iCloud Keychain", state: .done)
          : StatusListRow(title: "New password", value: "Set", state: .done),
        StatusListRow(title: "Old passkeys, password", value: "Removed", state: .done),
        StatusListRow(title: "Other devices", value: "Signed out", state: .done),
      ])
    } footer: {
      InfoCard(icon: .paper, hue: .sand, title: "Your 12 words still work",
               detail: "If someone else may have seen them, make new ones in Sign-in & security.")
        .padding(.bottom, 12)
      Button("Go to Home") { model.recoveryDone() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("recover.home")
    }
  }
}

// MARK: - Honest end

/// No words and no passkey (Paper H9F): say plainly that no one can open the data, then the
/// two real ways forward. Starting fresh has no ceremony yet, so it is offered only on the
/// unfinished surface; a Release build points to a person instead.
struct HonestEndScreen: View {
  enum Context {
    /// Signed out: from recovery or a forgotten password.
    case signedOut
    /// Signed in, data sealed: from "Unlock your data".
    case unlock
  }

  var context: Context
  var onFoundWords: () -> Void
  /// Unlock only: leave this iPhone signed out.
  var onSignOut: (() -> Void)?

  @Environment(AccountSession.self) private var session: AccountSession?
  @State private var failure: AuthFailure?

  private var startsFresh: Bool { BuildSurface.showsUnfinished }
  private var addsPasskeys: Bool { session?.capabilities.contains(.addPasskey) ?? false }

  var body: some View {
    AccountScreen(
      title: "Without your recovery phrase, we can't open your data",
      subtitle: "It was sealed with a key we never had. Without your words or a passkey, no one can open it, us included.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        NeedsCard {
          NeedRow(icon: .iPad, hue: .sky, title: "Another device still signed in?",
                  detail: addsPasskeys
                    ? "An iPad or old iPhone with Hasala open can add a passkey or show your words after Face ID."
                    : "An iPhone with Hasala open can show your words in Sign-in & security, after Face ID.")
          NeedRow(icon: .paper, hue: .sand, title: "Look again",
                  detail: "Check where you keep important papers. Any copy works, as long as the order is right.")
        }
        if startsFresh {
          WarningNote(text: "Starting fresh deletes the sealed copy of your old data after 7 days. Plans, rules and edits can't come back.")
        }
        FailureBanner(failure: failure)
      }
    } footer: {
      Button("I found my words", action: onFoundWords)
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("honest.foundWords")
      if startsFresh {
        // No start-fresh ceremony exists yet (spec 08 §8): the unfinished surface only.
        SecondaryLink(title: "Start fresh with this email", identifier: "honest.startFresh", role: .destructive) {
          failure = .notInThisBuild
        }
      } else {
        WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "honest.talk")
      }
      if let onSignOut {
        SecondaryLink(title: "Sign out", identifier: "unlock.signOut", action: onSignOut)
      }
    }
  }
}
