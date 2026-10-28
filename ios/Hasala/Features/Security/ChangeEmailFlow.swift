import HasalaDesign
import Observation
import SwiftUI

/// Changing the account's address (Paper P2.5 LPY, LRC), after "Confirm it's you": the
/// new address, then a code from each of the two addresses, checked together. Nothing
/// changes until both match.
@MainActor
@Observable
final class ChangeEmailModel {
  enum Step: Hashable { case codes }

  let account: AccountService
  private(set) var ticket: EmailChangeTicket
  var path: [Step] = []
  var newEmail = ""
  var currentCode = ""
  var newCode = ""
  var busy = false
  var failure: AuthFailure?
  /// The step the failure belongs to (the address, or the codes).
  private(set) var failedOnCodes = false

  init(account: AccountService, ticket: EmailChangeTicket) {
    self.account = account
    self.ticket = ticket
  }

  /// A new address, not the one the account has.
  var newEmailReady: Bool {
    guard let norm = AccountFields.email(newEmail) else { return false }
    return norm != ticket.currentEmail
  }

  var codesReady: Bool { currentCode.count == 6 && newCode.count == 6 }

  /// "Send both codes".
  func sendCodes() async -> Bool {
    guard newEmailReady else { return false }
    busy = true
    defer { busy = false }
    do {
      ticket = try await account.sendEmailChangeCodes(ticket, to: newEmail)
      currentCode = ""
      newCode = ""
      failure = nil
      failedOnCodes = false
      return true
    } catch {
      failure = error
      failedOnCodes = !path.isEmpty
      return false
    }
  }

  /// "Change email": both codes together. A wrong one keeps the digits to compare.
  func finish() async -> Bool {
    guard codesReady else { return false }
    busy = true
    defer { busy = false }
    do {
      try await account.finishEmailChange(ticket, currentCode: currentCode, newCode: newCode)
      failure = nil
      return true
    } catch {
      failure = error
      failedOnCodes = true
      return false
    }
  }

  /// Typing again clears a wrong code's ring and line.
  func codesEdited() {
    if failedOnCodes, case .codeWrong = failure { failure = nil }
  }
}

/// The change-email cover: its own stack, so the two steps keep the account template's
/// system back (decision 7). `onDone` gets the new address, or nil when cancelled.
struct ChangeEmailFlow: View {
  @State private var model: ChangeEmailModel
  var onDone: (String?) -> Void

  init(account: AccountService, ticket: EmailChangeTicket, onDone: @escaping (String?) -> Void) {
    _model = State(initialValue: ChangeEmailModel(account: account, ticket: ticket))
    self.onDone = onDone
  }

  var body: some View {
    NavigationStack(path: $model.path) {
      NewAddressStep(model: model, onCancel: { onDone(nil) })
        .navigationDestination(for: ChangeEmailModel.Step.self) { _ in
          CodesStep(model: model, onCancel: { onDone(nil) }) {
            onDone(model.ticket.newEmail)
          }
        }
    }
    #if HASALA_MOCKS
      .task { await ScreenLaunch.applyEmailChangeLaunch(model) }
    #endif
  }
}

/// Paper LPY "Change your email" (1 of 2).
private struct NewAddressStep: View {
  @Bindable var model: ChangeEmailModel
  var onCancel: () -> Void

  var body: some View {
    AccountScreen(
      title: "Change your email",
      subtitle: "You've confirmed it's you. Where should codes and alerts go now?",
      steps: (1, 2), back: .action(onCancel)
    ) {
      VStack(alignment: .leading, spacing: 16) {
        ReadOnlyField(label: "Current email", value: model.ticket.currentEmail)
        AccountField("New email", help: "Codes and security alerts go here once you confirm it.",
                     error: model.failedOnCodes ? nil : model.failure?.message) {
          EmailInput(text: $model.newEmail, identifier: "changeEmail.new")
        }
        CardNote(icon: .envelope,
                 text: "We'll send a code to both addresses, so the old one knows and the new one is really yours. Your passkeys, password and 12 words don't change.")
      }
    } footer: {
      BusyButton(title: "Send both codes", busy: model.busy, enabled: model.newEmailReady,
                 identifier: "changeEmail.send") {
        Task { if await model.sendCodes() { model.path = [.codes] } }
      }
      SecondaryLink(title: "Cancel", identifier: "changeEmail.cancel", action: onCancel)
    }
  }
}

/// Paper LRC "Enter both codes" (2 of 2).
private struct CodesStep: View {
  @Bindable var model: ChangeEmailModel
  var onCancel: () -> Void
  var onChanged: () -> Void
  @FocusState private var focus: Field?

  enum Field: Hashable { case current, new }

  var body: some View {
    AccountScreen(
      title: "Enter both codes",
      subtitle: "One went to each address. They work for 10 minutes; 5 tries, then a pause.",
      steps: (2, 2), back: .system
    ) {
      VStack(alignment: .leading, spacing: 22) {
        CodeGroup(label: "From \(model.ticket.currentEmail) ·\u{00A0}current", code: $model.currentCode,
                  sentAt: model.ticket.sentAt, wrong: wrong, focused: $focus, field: .current,
                  identifier: "changeEmail.currentCode") { resend() }
        CodeGroup(label: "From \(model.ticket.newEmail ?? "") ·\u{00A0}new", code: $model.newCode,
                  sentAt: model.ticket.sentAt, wrong: wrong, focused: $focus, field: .new,
                  identifier: "changeEmail.newCode") { resend() }
        if model.failedOnCodes, let message = model.failure?.message {
          FieldErrorLine(text: message, warning: model.failure == .codeExpired)
        }
        CardNote(icon: .shieldCheck,
                 text: "Nothing changes until both codes match. Your passkeys, password and 12 words stay as they are.")
      }
      .onChange(of: model.currentCode) { _, new in
        model.codesEdited()
        if new.count == 6, model.newCode.count < 6 { focus = .new }
      }
      .onChange(of: model.newCode) { _, _ in model.codesEdited() }
    } footer: {
      BusyButton(title: "Change email", busy: model.busy, enabled: model.codesReady, identifier: "changeEmail.confirm") {
        Task { if await model.finish() { onChanged() } }
      }
      SecondaryLink(title: "Cancel", identifier: "changeEmail.codesCancel", action: onCancel)
    }
    .onAppear { focus = model.currentCode.count < 6 ? .current : .new }
  }

  private var wrong: Bool {
    guard model.failedOnCodes, case .codeWrong = model.failure else { return false }
    return true
  }

  private func resend() {
    Task { _ = await model.sendCodes() }
  }
}

/// A code group (Paper LRC "CodeGroup"): the address it came from, its status ("Done" once
/// six digits are in, else the resend countdown), and six boxes over one hidden field.
private struct CodeGroup: View {
  var label: String
  @Binding var code: String
  var sentAt: Date?
  var wrong: Bool
  var focused: FocusState<CodesStep.Field?>.Binding
  var field: CodesStep.Field
  var identifier: String
  var onResend: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(label)
          .hType(.footnote.weight(.semibold))
          .foregroundStyle(HColor.textSecondary)
          .lineLimit(2)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        status
      }
      CodeBoxes6(code: $code, wrong: wrong, focused: focused, field: field, identifier: identifier, label: label)
    }
  }

  @ViewBuilder private var status: some View {
    if code.count == 6 {
      HStack(spacing: 6) {
        Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7)
        Text("Done").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.statusSuccessForeground)
      }
      .accessibilityElement(children: .combine)
    } else {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let left = sentAt.map { max(0, 60 - context.date.timeIntervalSince($0)) } ?? 0
        if left > 0 {
          Text("Resend in \(ResendRow.clock(left))").hType(.footnote).foregroundStyle(HColor.textSecondary)
        } else {
          Button("Resend", action: onResend)
            .hType(.footnote.weight(.semibold))
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: 44)
        }
      }
    }
  }
}

/// Six 56-tall boxes across the content width (Paper LRC "CodeBoxes"), drawn over one
/// hidden `.oneTimeCode` field: the next box rings inside and shows the caret; a wrong code
/// rings every box and keeps the digits.
private struct CodeBoxes6: View {
  @Binding var code: String
  var wrong: Bool
  var focused: FocusState<CodesStep.Field?>.Binding
  var field: CodesStep.Field
  var identifier: String
  var label: String

  var body: some View {
    ZStack {
      TextField("", text: Binding(get: { code }, set: { code = String($0.filter(\.isNumber).prefix(6)) }))
        .textContentType(.oneTimeCode)
        .keyboardType(.numberPad)
        .focused(focused, equals: field)
        .foregroundStyle(.clear)
        .tint(.clear)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilityValue("\(code.count) of 6 digits")
      HStack(spacing: 8) {
        ForEach(0..<6, id: \.self) { box($0) }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
    .onTapGesture { focused.wrappedValue = field }
    .environment(\.layoutDirection, .leftToRight)
  }

  private func box(_ i: Int) -> some View {
    let digit = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
    let next = focused.wrappedValue == field && !wrong && i == code.count && code.count < 6
    return ZStack {
      Text(digit)
        .font(.system(size: 26, weight: .semibold, design: .rounded))
        .foregroundStyle(HColor.textPrimary)
      if next {
        RoundedRectangle(cornerRadius: 1).fill(HColor.actionAccent).frame(width: 2, height: 26)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 56)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: HRadius.field, style: .continuous)
        .strokeBorder(wrong ? HColor.fieldError : HColor.fieldFocus, lineWidth: 2)
        .opacity(wrong || next ? 1 : 0)
    }
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
  }
}

/// A field that can't be edited (Paper LPY "Current email"): the quaternary fill and the
/// value in secondary.
struct ReadOnlyField: View {
  var label: String
  var value: String

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.fieldLabelGap) {
      Text(label).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textSecondary)
      Text(value)
        .hType(HType(size: 17, leading: 22, weight: .regular, textStyle: .body))
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, HSpacing.fieldInsetInline)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: HSpacing.fieldMinHeight, alignment: .leading)
        .background(HColor.fieldSurfaceReadonly, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
    }
    .accessibilityElement(children: .combine)
  }
}
