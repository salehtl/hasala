import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

// Paper P2.1 "Join and create an account" (spec 07 §4): enter your invite code (pasted, not
// found), about you, how you sign in, create a password. "Your invite is ready" and "Check
// your email" are in `Join/`. Everything typed lives in the onboarding store's
// `SignupModel`, so Back and Forward never clear a field (plan B3).

/// Enter your invite code (Paper E47-0, E6F-0; spec 07 S2, S4). The server's code is 24
/// letters and numbers, so it is one grouped field in Paper's field style rather than
/// Paper's "HSL" and four cells (plan decision 3). A line under it says where the code came
/// from, or that it wasn't found; "Other reasons" follows a code that wasn't found.
struct InviteCodeView: View {
  @Bindable var model: SignupModel
  @State private var focused = false

  private var notFound: Bool { model.failure == .notInvited }

  var body: some View {
    AccountScreen(
      title: "Enter your invite code",
      subtitle: "It's in your invite email from Hasala. You only need it once.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        field
        // Paper's "Not found" (E6F) swaps where to find the code for why it may not work.
        if !notFound {
          InfoCard(icon: .envelope, hue: .sky, title: "Look for \u{201C}Your Hasala invite\u{201D}",
                   detail: "From no-reply@hasala.app, sent to the email you used on the waitlist.", radius: HRadius.tile)
            .hTransition(.fade)
        } else {
          ReasonsCard(reasons: [
            ("Already used it?", "Each invite works once. If you made an account, sign in instead."),
            ("Past the date in your email?",
             "Expired invites go back to the list. Ask again at hasala.app and we'll send a new one."),
          ])
          .hTransition(.rise)
        }
      }
      .hAnimation(.rise, value: notFound)
    } actions: {
      Button(notFound ? "Try again" : "Continue") { model.submitInvite() }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(model.inviteCode == nil)
        .accessibilityIdentifier("invite.continue")
      WebLink(title: "No invite yet? Join the waitlist", url: "https://hasala.app", identifier: "invite.waitlist")
    }
  }

  /// Paper "InviteCodeField": the label, a white 64 box (radius 14) holding the grouped
  /// code, the red ring on a code that wasn't found, the blue ring while typing.
  private var field: some View {
    VStack(alignment: .leading, spacing: HSpacing.fieldLabelGap) {
      Text("Invite code")
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.textSecondary)
        .accessibilityHidden(true)
      // Groups the code as it is typed or pasted, and wraps instead of clipping at large
      // text sizes.
      InviteCodeField(text: $model.inviteText, focused: $focused, identifier: "invite.field") { link in
        model.applyInviteLink(link, pasteboardChange: UIPasteboard.general.changeCount)
      }
      .padding(.horizontal, HSpacing.fieldInsetInline)
      .padding(.vertical, 8)
      .frame(minHeight: HSpacing.codeCellHeight)
      .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
      .overlay { FieldRing(color: notFound ? HColor.fieldError : focused ? HColor.fieldFocus : .clear) }
      .hAnimation(.fade, value: focused)
      HStack(alignment: .top, spacing: 8) {
        status
        Spacer(minLength: 0)
        PasteButton(payloadType: String.self) { pasted in
          guard let text = pasted.first, !text.isEmpty else { return }
          Task { @MainActor in
            model.paste(text, pasteboardChange: UIPasteboard.general.changeCount)
          }
        }
        .labelStyle(.titleOnly)
        .buttonBorderShape(.capsule)
        .tint(HColor.surfacePrimary)
        .padding(.top, -6)
        .accessibilityIdentifier("invite.paste")
      }
      .padding(.top, 6)
    }
  }

  @ViewBuilder private var status: some View {
    if notFound, let message = AuthFailure.notInvited.message {
      JoinStatusLine(text: message, tone: .error)
    } else if let hint = model.inviteHint {
      JoinStatusLine(text: hint, tone: .error)
    } else if model.inviteFromLink, model.inviteCode != nil {
      JoinStatusLine(text: "From your invite link.", tone: .success)
    } else if model.invitePasted, model.inviteCode != nil {
      JoinStatusLine(text: "Pasted from your invite email.", tone: .success)
    }
  }
}

/// Create your account · 1 of 3 · About you (Paper E7J-0 with an invite link, JYI-0 with a
/// typed code; spec 07 S6a, S6b). The email is typed, because the app doesn't know where the
/// invite went; once a link or a code has confirmed it, the box carries Paper's "Confirmed"
/// chip (seen when the person comes Back here). The chip and the line under the box say what
/// Continue will do (`SignupModel.emailHelp`): a changed name or address may mean a new code.
struct AboutYouView: View {
  @Bindable var model: SignupModel
  var onSignIn: () -> Void

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    AccountScreen(
      title: "Create your account",
      subtitle: "Just a name and an email. No usernames.",
      steps: (1, 3),
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 12) {
          AccountField("Your name", help: "What Hasala calls you, in the app and in emails.", error: model.nameError) {
            WrappingTextField(placeholder: "", text: $model.displayName)
              .textContentType(.name)
              .textInputAutocapitalization(.words)
              .autocorrectionDisabled()
              .accessibilityIdentifier("about.name")
          }
          AccountField("Email", help: model.emailHelp, error: model.emailError) {
            WrappingTextField(placeholder: "you@example.com", text: $model.email)
              .textContentType(.username)
              .keyboardType(.emailAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("about.email")
          } trailing: {
            if model.emailConfirmed, !typeSize.isAccessibilitySize { ConfirmedChip() }
          }
          // At the accessibility sizes the address needs the box's width: the chip goes under it.
          if model.emailConfirmed, typeSize.isAccessibilitySize { ConfirmedChip() }
        }
        .id(Self.fieldsID)
        FailureBanner(failure: model.failure)
        GlyphNote(icon: .shieldCheck,
                  text: "We only email you about your account: codes, invites and security alerts. Never your money, never marketing.")
      }
    } actions: {
      BusyButton(title: "Continue", busy: model.busy, enabled: model.aboutYouReady, identifier: "about.continue") {
        Task { await model.submitAboutYou() }
      }
      LinkButton(title: "Already have an account? Sign in", identifier: "about.signIn", action: onSignIn)
    }
    .revealsOnKeyboard(Self.fieldsID)
  }

  private static let fieldsID = "about.fields"
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
      back: .system
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
              Text(resendCountdown(left))
                .hType(.subheadline)
                .foregroundStyle(HColor.textSecondary)
                .monospacedDigit()
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
        HintCard(icon: .envelope, text: "Not there? Check Spam or Promotions for an email from no-reply@hasala.app.")
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
      back: .system
    ) {
      VStack(spacing: 12) {
        choice(.passkey, icon: .faceID, hue: .sky, title: "Use Face ID (passkey)", recommended: true,
               text: "Nothing to remember or type. Your passkey is saved in iCloud Keychain, and it unlocks your data on a new iPhone.")
        choice(.password, icon: .password, hue: .other, title: "Use a password", recommended: false,
               text: "Signs you in anywhere you can type. It can't unlock your data on a new iPhone; your 12 words will do that job.")
        FailureBanner(failure: model.failure)
      }
    } actions: {
      BusyButton(title: model.method == .passkey ? "Continue with Face ID" : "Continue with a password",
                 busy: model.busy, identifier: "method.continue") {
        Task { await model.continueWithMethod() }
      }
      WebLink(title: "What's a passkey?", url: "https://support.apple.com/102195", identifier: "method.whatsAPasskey")
    }
  }

  private func choice(_ m: SignInMethod, icon: HIcon, hue: Hue, title: String, recommended: Bool, text: String)
    -> some View
  {
    SelectionCard(icon: icon, hue: hue, chip: recommended ? "Recommended" : nil, title: title, detail: text,
                  selected: model.method == m, identifier: "method.\(m.rawValue)") {
      model.method = m
      model.failure = nil
    }
  }
}

/// Create your account · 2 of 3 · Password (Paper EQ6-0 too short, EZU-0 strong and
/// confirmed; spec 07 S10). The rules tick as they pass and nothing shouts while the person
/// types; "Create account" waits until the password could pass and the two match.
struct CreatePasswordView: View {
  @Bindable var model: SignupModel

  var body: some View {
    AccountScreen(
      title: "Create a password",
      subtitle: "12 characters or more. A short phrase you'll remember works well.",
      steps: (2, 3),
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 12) {
          LabeledField(label: "Password") {
            // A UIKit field: SwiftUI's can't carry Hasala's password rules for AutoFill.
            RuledNewPasswordField(placeholder: "12 characters or more", text: $model.newPassword, secure: !model.passwordShown,
                                  identifier: "password.new")
          } accessory: {
            ShowHidePill(visible: $model.passwordShown)
          }
          if !model.newPassword.isEmpty {
            PasswordStrengthCard(assessment: model.passwordAssessment)
              .hTransition(.rise)
          }
          VStack(alignment: .leading, spacing: 8) {
            LabeledField(label: "Type it again", error: mismatch ? "Passwords don't match." : nil) {
              RuledNewPasswordField(placeholder: "Confirm password", text: $model.confirmPassword, secure: true,
                                    identifier: "password.confirm")
            }
            if model.passwordsMatch {
              StatusLine(text: "Passwords match.", tone: .success)
                .padding(.top, 2)
            }
          }
          .padding(.top, 4)
        }
        .id(Self.fieldsID)
        NoteRow(icon: .lock,
                text: "Your password signs you in, but it can't unlock your data on a new iPhone. The 12 words in the next step do that.")
      }
      .hAnimation(.rise, value: model.newPassword.isEmpty)
    } actions: {
      BusyButton(title: "Create account", busy: model.busy, enabled: model.passwordReady,
                 identifier: "password.create") {
        model.submitPassword()
      }
      LinkButton(title: "Use Face ID instead", identifier: "password.useFaceID") {
        model.method = .passkey
        model.back()
      }
    }
    .revealsOnKeyboard(Self.fieldsID)
  }

  private static let fieldsID = "password.fields"

  /// Said only once the second field is as long as the first: never while still typing.
  private var mismatch: Bool {
    !model.confirmPassword.isEmpty && !model.passwordsMatch && model.confirmPassword.count >= model.newPassword.count
  }
}

/// "Resend code in 0:42": the seconds left before another code can be sent, as minutes and
/// seconds (a full minute reads "1:00", never "0:60").
func resendCountdown(_ secondsLeft: Int) -> String {
  let left = max(0, secondsLeft)
  return "Resend code in \(left / 60):\(String(format: "%02d", left % 60))"
}
