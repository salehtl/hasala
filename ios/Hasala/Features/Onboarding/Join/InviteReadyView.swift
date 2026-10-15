import HasalaDesign
import HasalaModels
import SwiftUI

/// "Your invite is ready" (Paper E5B-0; spec 07 S3): the invite's universal link opened the
/// app with the code filled in. It is never submitted on its own: "Create my account" goes
/// on to About you, "Use a different code" to the code field (with this code in it).
///
/// The link carries the code and a key, not the address the invite went to or how long it
/// lasts, so the card says where the code came from instead of Paper's "For
/// maya@example.com" and "Saved until Sunday 25 October", and the copy promises no code only
/// for the address the invite went to (the key proves that one, spec 04 §13.5).
struct InviteReadyView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    let model = store.signup
    AccountScreen(
      title: "Your invite is ready",
      subtitle: "Your link opened it and filled in the code. Setting up takes about five minutes.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        inviteCard(model)
        nextSteps
        FailureBanner(failure: model.failure)
      }
    } footer: {
      BusyButton(title: "Create my account", busy: model.busy, enabled: model.inviteCode != nil,
                 identifier: "inviteReady.create") {
        model.submitInvite()
      }
      LinkButton(title: "Use a different code", identifier: "inviteReady.otherCode") { model.go(.invite) }
    }
  }

  private func inviteCard(_ model: SignupModel) -> some View {
    HStack(spacing: 14) {
      AppIconTile(size: 56, radius: 13, detailed: false)
        .shadow(color: HColor.blue950.opacity(0.26), radius: 11, y: 10)
      VStack(alignment: .leading, spacing: 2) {
        Text("Your invite")
          .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
          .foregroundStyle(HColor.textPrimary)
        Text(model.inviteCode?.grouped ?? InviteCode.group(model.normalizedInvite))
          .font(.system(.subheadline, design: .monospaced))
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Code \(model.normalizedInvite.map(String.init).joined(separator: " "))")
        HStack(spacing: 6) {
          Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7)
          Text("Filled in from your invite link")
            .hType(.footnote.weight(.semibold))
            .foregroundStyle(HColor.statusSuccessForeground)
        }
        .padding(.top, 4)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(20)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("inviteReady.card")
  }

  /// Paper "Card · What happens next": the three steps of creating the account.
  private var nextSteps: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("What happens next")
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
        .foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      NumberedStep(number: 1, text: "Your name, and the email your invite went to")
      NumberedStep(number: 2, text: "Sign in with Face ID, or a password")
      NumberedStep(number: 3, text: "Write down 12 words, on paper")
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}
