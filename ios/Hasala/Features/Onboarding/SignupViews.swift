import HasalaDesign
import SwiftUI
import UIKit

// Paper page 14, section 14.1: invite code, about you, verify email, how you sign in,
// create a password (spec 04 §6.2 signup steps 2-6).

struct InviteCodeView: View {
  @Bindable var model: SignupModel
  @State private var focused = false

  var body: some View {
    AccountScreen(
      title: "Enter your invite code",
      subtitle: "It's in your invite email from Hasala. You only need it once.",
      onBack: model.back
    ) {
      VStack(alignment: .leading, spacing: 12) {
        LabeledField(label: "Invite code", error: model.inviteHint, focused: focused) {
          // Groups the code as it is typed or pasted, and wraps instead of clipping at
          // large text sizes.
          InviteCodeField(text: $model.inviteText, focused: $focused, identifier: "invite.field") { link in
            model.applyInviteLink(link)
          }
        }
        HStack {
          Spacer()
          Button {
            if let text = UIPasteboard.general.string { model.paste(text) }
          } label: {
            Label("Paste", systemImage: "doc.on.clipboard").hType(.buttonSmall)
          }
          .foregroundStyle(HColor.textLink)
          .padding(.horizontal, 14)
          .frame(minHeight: 44)
          .background(HColor.actionAccentSubtle, in: Capsule())
          .accessibilityIdentifier("invite.paste")
        }
        if model.failure == .notInvited {
          FailureBanner(failure: .notInvited)
        } else if model.inviteFromLink, model.inviteCode != nil {
          StatusLine(text: "From your invite link.", tone: .success)
        } else if model.invitePasted, model.inviteCode != nil {
          StatusLine(text: "Pasted from your invite email.", tone: .success)
        }
        NoteCard(systemImage: "envelope", title: "Look for \u{201C}Your Hasala invite\u{201D}",
                 text: "From no-reply@hasala.app, sent to the email you used on the waitlist.")
      }
    } footer: {
      Button("Continue") { model.submitInvite() }
        .buttonStyle(.pill(model.inviteCode != nil ? .primary : .tertiary, fill: true))
        .disabled(model.inviteCode == nil)
        .accessibilityIdentifier("invite.continue")
      WebLink(title: "No invite yet? Join the waitlist", url: "https://hasala.app", identifier: "invite.waitlist")
    }
  }
}

struct AboutYouView: View {
  @Bindable var model: SignupModel
  var onSignIn: () -> Void

  var body: some View {
    AccountScreen(
      title: "Create your account",
      subtitle: "Just a name and an email. No usernames.",
      steps: (1, 3),
      onBack: model.back
    ) {
      VStack(alignment: .leading, spacing: 16) {
        LabeledField(label: "Your name",
                     footer: "We use your name to greet you in our emails. Our server keeps it with your email address.",
                     error: model.nameError) {
          TextField("Your name", text: $model.displayName)
            .textContentType(.name)
            .textInputAutocapitalization(.words)
            .accessibilityIdentifier("about.name")
        }
        LabeledField(label: "Email",
                     footer: model.inviteFromLink
                       ? "If it's the address your invite went to, you won't need a code."
                       : "We'll send a code to confirm it. Security alerts go here too.",
                     error: model.emailError) {
          EmailInput(text: $model.email, identifier: "about.email")
        }
        FailureBanner(failure: model.failure)
        NoteCard(systemImage: "checkmark.shield",
                 text: "We only email you about your account: codes, invites and security alerts. Never your money, never marketing.")
      }
    } footer: {
      BusyButton(title: "Continue", busy: model.busy, enabled: model.aboutYouReady, identifier: "about.continue") {
        Task { await model.submitAboutYou() }
      }
      LinkButton(title: "Already have an account? Sign in", identifier: "about.signIn", action: onSignIn)
    }
  }
}

/// Six-box email code entry, shared by signup, forgot password and recovery.
struct CodeEntryView: View {
  var title = "Check your email"
  var email: String
  var steps: (current: Int, of: Int)?
  @Binding var code: String
  var busy: Bool
  var failure: AuthFailure?
  var sentAt: Date?
  var onBack: () -> Void
  var onSubmit: () -> Void
  var onResend: () -> Void
  var onChangeEmail: (() -> Void)?

  var body: some View {
    AccountScreen(
      title: title,
      subtitle: "We sent a 6-digit code to \(email). It works for 10 minutes.",
      steps: steps,
      onBack: onBack
    ) {
      VStack(alignment: .leading, spacing: 16) {
        CodeBoxes(code: $code, error: failure != nil)
          .onChange(of: code) { _, new in if new.count == 6 { onSubmit() } }
        if let failure {
          FailureBanner(failure: failure)
        }
        HStack {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, 60 - Int(context.date.timeIntervalSince(sentAt ?? .distantPast)))
            if left > 0 {
              Text("Resend code in 0:\(String(format: "%02d", left))")
                .hType(.subheadline)
                .foregroundStyle(HColor.textSecondary)
            } else {
              InlineTextButton(title: "Resend code", identifier: "code.resend", action: onResend)
            }
          }
          Spacer()
          if let onChangeEmail {
            InlineTextButton(title: "Change email", identifier: "code.changeEmail", action: onChangeEmail)
          }
        }
        if busy { ProgressView().frame(maxWidth: .infinity) }
        NoteCard(systemImage: "envelope",
                 text: "Not there? Check Spam or Promotions for an email from no-reply@hasala.app.",
                 tint: HColor.surfacePrimary.opacity(0.7))
        LockNote(text: "Hasala will never ask for your recovery phrase, your password or a code in an email, a notification, a phone call or on a website. Only type them into the Hasala app.",
                 systemImage: "exclamationmark.shield")
      }
    }
  }
}

struct SignInMethodView: View {
  @Bindable var model: SignupModel

  var body: some View {
    AccountScreen(
      title: "How do you want to sign in?",
      subtitle: model.ticket?.emailProven == true
        ? "Your link opened it and confirmed your email. Now pick how you'll get back in. You can add the other way later."
        : "Email verified. Now pick how you'll get back in. You can add the other way later.",
      steps: (2, 3),
      onBack: model.back
    ) {
      VStack(spacing: 12) {
        choice(.passkey, symbol: "faceid", title: "Use Face ID (passkey)", recommended: true,
               text: "Nothing to remember or type. Your passkey is saved in iCloud Keychain, and it unlocks your data on a new iPhone.")
        choice(.password, symbol: "ellipsis.rectangle", title: "Use a password", recommended: false,
               text: "Signs you in anywhere you can type. It can't unlock your data on a new iPhone; your 12 words will do that job.")
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: model.method == .passkey ? "Continue with Face ID" : "Continue with a password",
                 busy: model.busy, identifier: "method.continue") {
        Task { await model.continueWithMethod() }
      }
      WebLink(title: "What's a passkey?", url: "https://support.apple.com/102195", identifier: "method.whatsAPasskey")
    }
  }

  private func choice(_ m: SignInMethod, symbol: String, title: String, recommended: Bool, text: String) -> some View {
    let selected = model.method == m
    return Button {
      model.method = m
      model.failure = nil
    } label: {
      HStack(alignment: .top, spacing: 14) {
        IconDisc(systemImage: symbol, tint: selected ? HColor.actionAccentSubtle : HColor.surfaceSecondary,
                 ink: selected ? HColor.actionAccent : HColor.iconPrimary)
        VStack(alignment: .leading, spacing: 6) {
          if recommended {
            Text("Recommended")
              .hType(.caption1)
              .foregroundStyle(HColor.statusSuccessForeground)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(HColor.statusSuccessSurface, in: Capsule())
          }
          Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
          Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(selected ? HColor.actionAccent : HColor.iconTertiary)
          .accessibilityHidden(true)
      }
      .padding(18)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous)
          .strokeBorder(selected ? HColor.actionAccent : .clear, lineWidth: 2)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("method.\(m.rawValue)")
  }
}

struct CreatePasswordView: View {
  @Bindable var model: SignupModel

  var body: some View {
    AccountScreen(
      title: "Create a password",
      subtitle: "12 characters or more. A short phrase you'll remember works well.",
      steps: (2, 3),
      onBack: model.back
    ) {
      NewPasswordBlock(password: $model.newPassword, confirm: $model.confirmPassword,
                       assessment: model.passwordAssessment, matches: model.passwordsMatch)
    } footer: {
      BusyButton(title: "Create account", busy: model.busy, enabled: model.passwordReady,
                 identifier: "password.create") {
        model.submitPassword()
      }
      LinkButton(title: "Use Face ID instead", identifier: "password.useFaceID") {
        model.method = .passkey
        model.back()
      }
    }
  }
}
