import HasalaDesign
import HasalaModels
import Observation
import SwiftUI

/// The approving iPhone (C9 side A; Paper P2.4 KJZ "Approve a password reset"; spec 04
/// §6.12): checks the code from the new iPhone, then this iPhone's key approves.
@MainActor
@Observable
final class ResetApprovalModel {
  private let account: AccountService
  let request: PendingReset
  var code = ""
  var busy = false
  var failure: AuthFailure?
  private(set) var approved = false

  init(account: AccountService, request: PendingReset) {
    self.account = account
    self.request = request
  }

  /// 16 characters of `A-Z2-7` once spaces and hyphens are dropped.
  var codeReady: Bool {
    let n = InviteCode.normalize(code)
    return n.count == 16 && InviteCode.isAlphabet(n)
  }

  func approve() async {
    guard codeReady else { return }
    busy = true
    defer { busy = false }
    do {
      try await account.approveReset(request, code: code)
      approved = true
      failure = nil
    } catch {
      failure = error
    }
  }
}

/// "Password reset" (Paper KJZ): a floating medium sheet over the app on the iPhone that is
/// still signed in. Paper matches a two-digit number; the reset code it binds to is the new
/// iPhone's 16 characters (spec 04 §6.1.4), so this sheet asks for them: the code is
/// compared in constant time before any Face ID prompt (`approveReset`), and a person who
/// can't read the new iPhone's screen can't approve it.
struct ResetApprovalSheet: View {
  @State private var model: ResetApprovalModel
  /// "No, that's not me": the presenter opens "Let's lock it down" once this sheet is gone.
  var onNotMe: () -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var codeFocused: Bool

  init(model: ResetApprovalModel, onNotMe: @escaping () -> Void) {
    _model = State(initialValue: model)
    self.onNotMe = onNotMe
  }

  var body: some View {
    FittedSheet(busy: model.busy) {
      VStack(spacing: 0) {
        header
        Group {
          if model.approved { approved } else { ask }
        }
        .padding(.top, 12)
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 22)
    }
  }

  private var header: some View {
    HStack {
      GlassIconButton(.close, label: "Close") { dismiss() }
        .accessibilityIdentifier("approval.close")
      Spacer(minLength: 8)
      Text("Password reset")
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
        .foregroundStyle(HColor.textPrimary)
      Spacer(minLength: 8)
      Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
    }
    .padding(.top, 21)
  }

  private var ask: some View {
    VStack(spacing: 14) {
      HeroDisc(icon: .faceID, hue: .sky, shadow: false)
      VStack(spacing: 6) {
        Text("Is this you on a new iPhone?")
          .hType(.section)
          .foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text("An iPhone asked \(model.request.askedAgo). It typed a code we sent to \(model.request.email).")
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      matchCard
      if let message = model.failure?.message {
        FieldErrorLine(text: message)
          .accessibilityIdentifier("approval.failure")
      }
      Button("Yes, approve with Face ID") {
        // The keyboard goes first, so the answer (the line) isn't hidden under it.
        codeFocused = false
        Task { await model.approve() }
      }
      .buttonStyle(.pill(.primary, fill: true, loading: model.busy, leadingIcon: .faceID))
      .disabled(!model.codeReady)
      .accessibilityIdentifier("approval.approve")
      SecondaryLink(title: "No, that's not me", identifier: "approval.notMe", role: .destructive) {
        onNotMe()
        dismiss()
      }
    }
  }

  /// Paper "Match and effect": what the new iPhone shows (here, typed), then what saying
  /// yes does.
  private var matchCard: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("The new iPhone shows a code").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          Text("Type it here. Only say yes if it matches.").hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        TextField("ABCD EFGH IJKL MNOP", text: $model.code)
          .font(.system(.body, design: .monospaced).weight(.semibold))
          .keyboardType(.asciiCapable)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
          .focused($codeFocused)
          .padding(.horizontal, 14)
          .frame(minHeight: 48)
          .background(HColor.fieldSurface, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
          .overlay { FieldRing(color: model.failure == .codeMismatch ? HColor.fieldError : codeFocused ? HColor.fieldFocus : .clear) }
          // A tap anywhere in the box focuses the field, alongside the field's own tap.
          .contentShape(RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
          .simultaneousGesture(TapGesture().onEnded { codeFocused = true })
          .environment(\.layoutDirection, .leftToRight)
          .accessibilityLabel("The code on your new iPhone")
          .accessibilityIdentifier("approval.code")
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      HDivider(inset: .text16)
      HStack(alignment: .top, spacing: 10) {
        Circle().fill(HColor.textSecondary).frame(width: 7, height: 7).padding(.top, 7)
        Text("It can set a new password. Your data stays sealed there.")
          .hType(.subheadline)
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .accessibilityElement(children: .combine)
    }
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
  }

  /// Not on a board: the sheet says it's done in its own words, then closes.
  private var approved: some View {
    VStack(spacing: 14) {
      HeroDisc(icon: .check, hue: .mint, shadow: false)
      VStack(spacing: 6) {
        Text("Approved")
          .hType(.section)
          .foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text("Your other iPhone can set a new password now. Your data stays sealed there until it's unlocked.")
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      Button("Done") { dismiss() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("approval.done")
    }
  }
}
