import HasalaDesign
import HasalaModels
import SwiftUI

/// "Let's lock it down" (Paper P2.5 IF5 "Secure your account"; spec 04 §6.12): the steps,
/// in order, after something on the account wasn't the person. Sign out everywhere first;
/// the rest are done once signed in again. A sheet after "No, that's not me" on a reset
/// approval, or pushed from Sign-in & security.
struct LockdownView: View {
  enum Context {
    /// "No, that's not me" on a password reset another iPhone asked for.
    case afterApproval
    /// "Something not right? Lock it down" on Sign-in & security.
    case fromSecurity
  }

  @Bindable var model: SecurityModel
  var context: Context = .afterApproval
  @State private var asking = false

  var body: some View {
    AccountScreen(
      title: "Let's lock it down",
      subtitle: context == .afterApproval
        ? "You told us the password reset wasn't you. Do these now, in order."
        : "If something on your account doesn't look right, do these now, in order.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        checklist
        HStack(alignment: .top, spacing: 10) {
          HIconView(.lock, size: 18, color: Hue.sky.ink)
          Text("A password sign-in can't open your data without your passkey or your 12 words.")
            .hType(.footnote.weight(.medium))
            .foregroundStyle(Hue.sky.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(HColor.statusInfoSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        if model.confirming == nil { FailureBanner(failure: model.failure) }
      }
    } footer: {
      if model.capabilities.contains(.signOutEverywhere) {
        BusyButton(title: "Sign out everywhere", busy: model.busy, identifier: "lockdown.signOutAll") { asking = true }
      }
      WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "lockdown.talk")
    }
    .confirmSheet(model, host: .lockdown)
    .alert("Sign out everywhere?", isPresented: $asking) {
      Button("Cancel", role: .cancel) {}
      Button("Sign out all", role: .destructive) { Task { await model.request(.signOutEverywhere, host: .lockdown) } }
    } message: {
      Text("Every device signs out, this one too. Your data stays on each, and your sealed backup stays, ready for your next sign-in.")
    }
  }

  /// Paper "NumberedChecklist": the first step is the one to do now.
  private var checklist: some View {
    HListCard {
      step(1, "Sign out everywhere", "Ends every session, including the one you don't know.")
      HDivider(inset: .none).padding(.leading, 54)
      step(2, "Remove what you don't recognise", "Unknown passkeys and devices, in Sign-in & security.")
      HDivider(inset: .none).padding(.leading, 54)
      step(3, "Change your password", "If you have one. Also change it on your email account.")
      HDivider(inset: .none).padding(.leading, 54)
      step(4, "Make a new recovery phrase", "Only if someone may have seen your paper.")
    }
  }

  @ScaledMetric(relativeTo: .callout) private var lane: CGFloat = 22

  private func step(_ n: Int, _ title: String, _ text: String) -> some View {
    let current = n == 1
    return HStack(alignment: .top, spacing: 12) {
      Text("\(n)")
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(current ? HColor.white : HColor.textPrimary)
        .frame(width: 26, height: 26)
        .background(current ? HColor.actionAccent : HColor.surfacePrimary, in: Circle())
        .overlay { Circle().strokeBorder(HColor.neutral300, lineWidth: 1.5).opacity(current ? 0 : 1) }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text(text).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Step \(n): \(title). \(text)")
  }
}
