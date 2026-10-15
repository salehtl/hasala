import HasalaDesign
import HasalaModels
import SwiftUI

/// Create your account · 1 of 3 · Check your email (Paper EDW-0, EID-0, EKX-0; spec 07 S7a–c),
/// on the typed-code path only. Six cells over one `.oneTimeCode` field, so "From Mail" and a
/// paste fill all six; checked on the sixth digit, with no button.
///
/// Wrong: every cell gets the error ring and keeps its digit, so the code can be compared
/// with the email, and one line says what to try and how many tries are left; typing again
/// clears it. Expired (the server said so, or 10 minutes passed): the cells empty onto the
/// wash, the keyboard goes, and "Send a new code" takes the button's place. "Change email"
/// is always there.
struct VerifyEmailView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  /// Moves on when the code's ten minutes run out, so the screen turns to "expired" on its own.
  @State private var now = Date.now

  var body: some View {
    let model = store.signup
    let state = model.codeState(now: now)
    AccountScreen(
      title: "Check your email",
      subtitle: "We sent a 6-digit code to \(model.email). It works for 10 minutes.",
      steps: (1, 3),
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        cells(model, state: state)
        lines(model, state: state)
      }
      .hAnimation(.stateSwap, value: state)
    } footer: {
      if state == .expired {
        BusyButton(title: "Send a new code", busy: model.busy, identifier: "code.sendNew") {
          Task { await model.resendCode() }
        }
        LinkButton(title: "Change email", identifier: "code.changeEmail") { model.back() }
      }
    }
    .onChange(of: model.code) { _, code in
      if code.count == 6 { Task { await model.submitCode() } }
    }
    .task(id: model.ticket?.startedAt) {
      // When this ticket's code expires, look again.
      guard let sent = model.ticket?.startedAt else { return }
      let left = sent.addingTimeInterval(10 * 60 + 1).timeIntervalSinceNow
      if left > 0 { try? await Task.sleep(for: .seconds(left)) }
      if !Task.isCancelled { now = .now }
    }
  }

  @ViewBuilder private func cells(_ model: SignupModel, state: CodeCells.State) -> some View {
    CodeCells(code: Bindable(model).code, state: state, identifier: "code.field")
      // A fresh code starts a fresh field, with the keyboard up again.
      .id(model.codeSentAt)
      .overlay {
        // After a wrong code the field is empty for the next try; the digits that were
        // refused stay drawn, ringed, until the first new one.
        if state == .wrong, model.code.isEmpty, !model.wrongCode.isEmpty {
          WrongCodeCells(digits: model.wrongCode)
        }
      }
  }

  @ViewBuilder private func lines(_ model: SignupModel, state: CodeCells.State) -> some View {
    switch state {
    case .expired:
      JoinStatusLine(text: AuthFailure.codeExpired.message ?? "", tone: .warning)
      FailureBanner(failure: otherFailure(model))
    case .wrong, .typing:
      if state == .wrong, let message = model.failure?.message {
        JoinStatusLine(text: message, tone: .error)
      }
      FailureBanner(failure: otherFailure(model))
      resendRow(model)
      HintCard(icon: .envelope, text: "Not there? Check Spam or Promotions for an email from no-reply@hasala.app.")
    }
  }

  /// A failure that isn't about the code (offline, too many tries, an address in use).
  private func otherFailure(_ model: SignupModel) -> AuthFailure? {
    switch model.failure {
    case .codeWrong, .codeExpired, nil: nil
    case let other: other
    }
  }

  /// "Resend code in 0:42" counting down, then "Resend code"; "Change email" on the right.
  private func resendRow(_ model: SignupModel) -> some View {
    HStack {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let left = max(0, 60 - Int(context.date.timeIntervalSince(model.codeSentAt ?? .distantPast)))
        if model.busy {
          HStack(spacing: 8) {
            Spinner(size: 16)
            Text("Checking the code").hType(.subheadline).foregroundStyle(HColor.textSecondary)
          }
        } else if left > 0 {
          Text(resendCountdown(left))
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .monospacedDigit()
        } else {
          InlineTextButton(title: "Resend code", identifier: "code.resend") {
            Task { await model.resendCode() }
          }
        }
      }
      Spacer(minLength: 8)
      InlineTextButton(title: "Change email", identifier: "code.changeEmail") { model.back() }
    }
    .frame(minHeight: 44)
  }
}

/// The refused code, drawn where the cells are (two groups of three 52 × 64 cells, each with
/// the error ring), so it stays readable while the field under it is empty again.
private struct WrongCodeCells: View {
  let digits: String

  var body: some View {
    HStack(spacing: 0) {
      group(0..<3)
      Spacer(minLength: 18)
      group(3..<6)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func group(_ range: Range<Int>) -> some View {
    HStack(spacing: 8) {
      ForEach(range, id: \.self) { i in
        Text(i < digits.count ? String(digits[digits.index(digits.startIndex, offsetBy: i)]) : "")
          .font(.system(size: 28, weight: .semibold, design: .rounded))
          .foregroundStyle(HColor.textPrimary)
          .frame(width: HSpacing.codeCellWidth, height: HSpacing.codeCellHeight)
          .background(HColor.fieldSurfaceOnGrouped,
                      in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
          .overlay { FieldRing(color: HColor.fieldError) }
          .dynamicTypeSize(...DynamicTypeSize.accessibility1)
      }
    }
  }
}
