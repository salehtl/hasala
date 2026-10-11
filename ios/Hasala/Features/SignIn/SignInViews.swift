import CoreImage.CIFilterBuiltins
import HasalaDesign
import SwiftUI
import UIKit

// Paper page 14, sections 14.3-14.4: sign in (passkey first, then email and password),
// forgot password on a new iPhone, access recovery and the honest end.

struct SignInView: View {
  @Bindable var model: SignInModel
  var onBack: () -> Void
  var onForgot: () -> Void
  var onRecover: () -> Void
  var onJoin: () -> Void

  var body: some View {
    AccountScreen(title: "Welcome back", subtitle: "Sign in to Hasala.", onBack: onBack) {
      VStack(alignment: .leading, spacing: 14) {
        BusyButton(title: "Sign in with Face ID", busy: model.busy && model.password.isEmpty,
                   identifier: "signIn.passkey") {
          Task { await model.signInWithPasskey() }
        }
        Text("Uses the passkey in your iCloud Keychain.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .frame(maxWidth: .infinity)
        HStack(spacing: 10) {
          Rectangle().fill(HColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
          Text("or use your email").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textSecondary)
            .fixedSize()
          Rectangle().fill(HColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
        }
        LabeledField(label: "Email") {
          EmailInput(text: $model.email, identifier: "signIn.email")
        }
        VStack(alignment: .leading, spacing: HSpacing.fieldLabelGap) {
          HStack {
            Text("Password").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textSecondary)
            Spacer()
            InlineTextButton(title: "Forgot password?", identifier: "signIn.forgot", action: onForgot)
          }
          PasswordInput(placeholder: "Your password", text: $model.password, isNew: false,
                        identifier: "signIn.password")
            .hType(.body)
            .padding(.leading, HSpacing.fieldInsetInline)
            .padding(.trailing, 8)
            .frame(minHeight: HSpacing.fieldMinHeight)
            .background(HColor.fieldSurfaceOnGrouped,
                        in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        }
        BusyButton(title: "Sign in with password", busy: model.busy && !model.password.isEmpty, kind: .tertiary,
                   enabled: model.passwordSignInReady, identifier: "signIn.withPassword") {
          Task { await model.signInWithPassword() }
        }
        if model.failure == .orphanedPasskey {
          FailureBanner(failure: model.failure)
          HStack {
            Button("I have an invite", action: onJoin).buttonStyle(.pill(.secondary, size: .medium))
            Button("Try again") { Task { await model.signInWithPasskey() } }
              .buttonStyle(.pill(.tertiary, size: .medium))
          }
        } else if model.failure == .noCredential {
          FailureBanner(failure: model.failure)
          Text("Use your email instead.").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        } else {
          FailureBanner(failure: model.failure)
        }
        LinkButton(title: "Can't get in at all? Recover your account", identifier: "signIn.recover", action: onRecover)
          .padding(.top, 24)
      }
    } footer: {
      EmptyView()
    }
  }
}

// MARK: - Forgot password (C9 side N)

struct ForgotEmailView: View {
  @Bindable var model: SignInModel
  var onBack: () -> Void
  var onNext: () -> Void

  var body: some View {
    AccountScreen(
      title: "Forgot your password?",
      subtitle: "To reset your password, use your recovery phrase or approve it on an iPhone where you're signed in. A code from your email alone can't reset it.",
      steps: (1, 4), onBack: onBack
    ) {
      VStack(alignment: .leading, spacing: 12) {
        LabeledField(label: "Your account's email", footer: "We'll send a code to this address first.") {
          EmailInput(text: $model.resetEmail, identifier: "forgot.email")
        }
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: "Send a code", busy: model.busy, enabled: AccountFields.email(model.resetEmail) != nil,
                 identifier: "forgot.send") {
        Task { if await model.submitResetEmail() { onNext() } }
      }
    }
  }
}

struct ForgotCheckView: View {
  var model: SignInModel
  var onBack: () -> Void
  var onApprove: () -> Void
  var onWords: () -> Void
  var onNeither: () -> Void

  var body: some View {
    AccountScreen(
      title: "One more check",
      subtitle: "The code worked. To change your password we also need one of these.",
      steps: (3, 4), onBack: onBack
    ) {
      VStack(spacing: 12) {
        if model.canApproveOnOtherPhone {
          card(symbol: "iphone", title: "Approve on your other iPhone",
               text: "Your other iPhone is still signed in. Say yes there with Face ID.",
               button: "Send a request", primary: true, id: "forgot.approve", action: onApprove)
        }
        card(symbol: "doc.text", title: "Enter your 12 words",
             text: "From your paper. They unlock your data on this iPhone too.",
             button: "Enter words", primary: !model.canApproveOnOtherPhone, id: "forgot.words", action: onWords)
        LockNote(text: "Why not just the code? The company that delivers our email also carries our web traffic, so a code alone can't be the proof.",
                 systemImage: "checkmark.shield")
      }
    } footer: {
      LinkButton(title: "I have neither", identifier: "forgot.neither", action: onNeither)
    }
  }

  private func card(symbol: String, title: String, text: String, button: String, primary: Bool, id: String,
                    action: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        IconDisc(systemImage: symbol)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
          Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Button(button, action: action)
        .buttonStyle(.pill(primary ? .primary : .secondary, fill: true))
        .accessibilityIdentifier(id)
    }
    .padding(18)
    .listCard()
  }
}

struct ForgotNewPasswordView: View {
  @Bindable var model: SignInModel
  var onBack: () -> Void
  var onNext: () -> Void

  var body: some View {
    AccountScreen(title: "Choose a new password", subtitle: "12 characters or more.", steps: (4, 4), onBack: onBack) {
      VStack(alignment: .leading, spacing: 12) {
        NewPasswordBlock(password: $model.newPassword, confirm: $model.confirmPassword,
                         assessment: model.newPasswordAssessment,
                         matches: !model.confirmPassword.isEmpty && model.confirmPassword == model.newPassword)
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: "Ask my other iPhone", busy: model.busy, enabled: model.newPasswordReady,
                 identifier: "forgot.request") {
        Task { if await model.requestApproval() { onNext() } }
      }
    }
  }
}

/// Waiting for the other iPhone, with the reset code as a QR and 16 characters
/// (spec 04 §6.1.4; S-33).
struct ForgotWaitingView: View {
  var model: SignInModel
  var onBack: () -> Void
  var onWords: () -> Void

  var body: some View {
    AccountScreen(
      title: "Approve on your other iPhone",
      subtitle: "On your other iPhone, open Hasala and scan this code. Never show it to anyone else.",
      onBack: onBack
    ) {
      VStack(spacing: 16) {
        if let code = model.reset?.resetCode, let image = QRCode.image(for: "hasala-reset:1:\(code)") {
          Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 200, height: 200)
            .padding(16)
            .background(HColor.white, in: RoundedRectangle(cornerRadius: HRadius.card))
            .accessibilityLabel("Reset code as a QR code")
        }
        Text(model.resetCodeGroups)
          .font(.system(.title3, design: .monospaced).weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
          .environment(\.layoutDirection, .leftToRight)
          .accessibilityIdentifier("forgot.resetCode")
        HStack(spacing: 10) {
          ProgressView()
          Text("Waiting for your other iPhone…").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
        FailureBanner(failure: model.failure)
      }
      .frame(maxWidth: .infinity)
    } footer: {
      LinkButton(title: "Use my 12 words instead", identifier: "forgot.useWords", action: onWords)
    }
    .task { await model.waitForApproval() }
  }
}

enum QRCode {
  /// A QR image of `text`, correction level M (spec 04 §6.1.4).
  static func image(for text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
      let cg = CIContext().createCGImage(out, from: out.extent)
    else { return nil }
    return UIImage(cgImage: cg)
  }
}

// MARK: - Access recovery (C4): words first, then the code

struct RecoverIntroView: View {
  var onBack: () -> Void
  var onStart: () -> Void
  var onNoWords: () -> Void

  var body: some View {
    AccountScreen(
      title: "Recover your account",
      subtitle: "Lost your passkey or password? Use your recovery phrase and a code we email you.",
      onBack: onBack
    ) {
      VStack(spacing: 12) {
        NoteCard(systemImage: "doc.text", title: "Your 12 words", text: "From the paper you wrote at signup.")
        NoteCard(systemImage: "envelope", title: "Your email", text: "We'll send a code to your account's address.")
        NoteCard(systemImage: "iphone", title: "Then a new way to sign in",
                 text: "Hasala will make a new passkey or password on this iPhone and let your other devices know.")
      }
    } footer: {
      Button("Start", action: onStart).buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("recover.start")
      LinkButton(title: "I don't have my words", identifier: "recover.noWords", action: onNoWords)
    }
  }
}

/// Twelve words typed into one field, with word-list suggestions (Paper "Enter 12 words").
struct PhraseEntryField: View {
  @Binding var text: String
  /// The pasteboard's `changeCount` when a paste landed here (nil until one does).
  @Binding var pastedChangeCount: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("orbit canvas lemon …", text: $text, axis: .vertical)
        .lineLimit(4...6)
        .textContentType(nil)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .keyboardType(.asciiCapable)
        .hType(.body)
        .padding(16)
        .frame(minHeight: 120, alignment: .topLeading)
        .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityIdentifier("phraseEntry.field")
        .accessibilityLabel("Your 12 words")
        .onChange(of: text) { old, new in
          // A jump of many characters at once is a paste (a suggestion adds one word).
          // Only `changeCount` is read: reading the contents would show iOS's paste prompt.
          if new.count - old.count >= 12 { pastedChangeCount = UIPasteboard.general.changeCount }
        }
      let count = text.split(whereSeparator: \.isWhitespace).count
      HStack {
        Text("\(count) of 12 words").hType(.footnote).foregroundStyle(HColor.textSecondary)
        Spacer()
      }
      let suggestions = PhraseRules.suggestions(for: lastWord)
      if !suggestions.isEmpty, !PhraseRules.isWord(lastWord) {
        HStack(spacing: 8) {
          ForEach(suggestions, id: \.self) { w in
            Button(w) { complete(w) }
              .hType(.rowTitle)
              .foregroundStyle(HColor.textPrimary)
              .padding(.horizontal, 14)
              .frame(minHeight: 40)
              .background(HColor.surfacePrimary, in: Capsule())
          }
        }
      }
    }
  }

  private var lastWord: String {
    guard let last = text.last, !last.isWhitespace else { return "" }
    return text.split(whereSeparator: \.isWhitespace).last.map { String($0).lowercased() } ?? ""
  }

  private func complete(_ w: String) {
    var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    if !words.isEmpty { words.removeLast() }
    words.append(w)
    text = words.joined(separator: " ") + " "
  }
}

struct RecoverWordsView: View {
  @Bindable var model: SignInModel
  var onBack: () -> Void
  var onNext: () -> Void

  var body: some View {
    AccountScreen(title: "Enter your 12 words", subtitle: "In order, from your paper.", steps: (1, 3), onBack: onBack) {
      VStack(alignment: .leading, spacing: 12) {
        PhraseEntryField(text: $model.phraseText, pastedChangeCount: $model.pastedPhraseChangeCount)
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: "Continue", busy: model.busy, enabled: !model.phraseText.isEmpty, identifier: "recover.words") {
        Task {
          if await model.submitRecoveryWords() {
            clearPastedPhrase(changeCount: model.pastedPhraseChangeCount)
            model.pastedPhraseChangeCount = nil
            onNext()
          }
        }
      }
    }
  }
}

/// After a pasted phrase is accepted, clear the pasteboard if it still holds that paste
/// (spec 04 §6.7). Nothing is read from it: an unchanged `changeCount` means the same
/// contents, and writing never shows iOS's paste prompt. A typed phrase leaves the
/// pasteboard alone.
@MainActor
func clearPastedPhrase(changeCount: Int?) {
  guard let changeCount else { return }
  let pb = UIPasteboard.general
  if pb.changeCount == changeCount { pb.items = [] }
}

struct RecoverMethodView: View {
  @Bindable var model: SignInModel
  var onBack: () -> Void
  var onPassword: () -> Void
  var onResult: (SignInModel.RecoveryResult) -> Void

  var body: some View {
    AccountScreen(
      title: "A new way to sign in",
      subtitle: "Hasala will make a new passkey or password on this iPhone and let your other devices know.",
      steps: (3, 3), onBack: onBack
    ) {
      VStack(spacing: 12) {
        NoteCard(systemImage: "faceid", title: "Use Face ID (passkey)", text: "Recommended. Nothing to remember or type.")
        NoteCard(systemImage: "ellipsis.rectangle", title: "Use a password", text: "12 characters or more.")
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: "Continue with Face ID", busy: model.busy, identifier: "recover.passkey") {
        Task { onResult(await model.finishRecovery(.passkey)) }
      }
      LinkButton(title: "Use a password instead", identifier: "recover.password", action: onPassword)
    }
  }
}

struct RecoverPasswordView: View {
  @Bindable var model: SignInModel
  var onBack: () -> Void
  var onResult: (SignInModel.RecoveryResult) -> Void

  var body: some View {
    AccountScreen(title: "Create a password", subtitle: "12 characters or more.", steps: (3, 3), onBack: onBack) {
      VStack(alignment: .leading, spacing: 12) {
        NewPasswordBlock(password: $model.newPassword, confirm: $model.confirmPassword,
                         assessment: model.newPasswordAssessment,
                         matches: !model.confirmPassword.isEmpty && model.confirmPassword == model.newPassword)
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: "Finish", busy: model.busy, enabled: model.newPasswordReady, identifier: "recover.finish") {
        Task { onResult(await model.finishRecovery(.password(model.newPassword))) }
      }
    }
  }
}

/// No words and no passkey (Paper "Recover account · No words, no passkey").
struct HonestEndView: View {
  var onBack: () -> Void

  var body: some View {
    AccountScreen(
      title: "We can't unlock it without them",
      subtitle: "If you lose these words and every passkey, your data can't be unlocked on a new iPhone. Not even by us.",
      onBack: onBack
    ) {
      VStack(spacing: 12) {
        NoteCard(systemImage: "iphone", title: "Still have an iPhone with Hasala open?",
                 text: "Your data is still there. Open Hasala on it, then go to Profile › Sign-in & security to make new words or add a passkey.")
        NoteCard(systemImage: "person.2", title: "Talk to a person",
                 text: "We can't recover your data, but we can help you start a new account.")
      }
    } footer: {
      Link("Get help", destination: URL(string: "https://hasala.app/support")!)
        .buttonStyle(.pill(.primary, fill: true))
    }
  }
}
