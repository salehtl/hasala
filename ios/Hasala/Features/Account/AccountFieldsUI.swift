import HasalaDesign
import SwiftUI

/// Six code boxes over one hidden `.oneTimeCode` field (spec 04 §6.1.4; Paper "Verify
/// email"). iOS may offer the code from Mail; the user still enters it here.
struct CodeBoxes: View {
  @Binding var code: String
  var error = false
  var identifier = "code.field"
  @FocusState private var focused: Bool

  var body: some View {
    ZStack {
      TextField("6-digit code", text: Binding(get: { code }, set: { code = String($0.filter(\.isNumber).prefix(6)) }))
        .textContentType(.oneTimeCode)
        .keyboardType(.numberPad)
        .focused($focused)
        .foregroundStyle(.clear)
        .tint(.clear)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("Code")
        .accessibilityValue(code.isEmpty ? "empty" : code.map(String.init).joined(separator: " "))
      HStack(spacing: 8) {
        ForEach(0..<6, id: \.self) { i in
          let ch = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
          Text(ch)
            .font(.system(.title, design: .rounded).weight(.semibold))
            .foregroundStyle(HColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: HRadius.field, style: .continuous)
                .strokeBorder(
                  error ? HColor.fieldError : (focused && i == min(code.count, 5) ? HColor.fieldFocus : .clear),
                  lineWidth: 2)
            }
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
    .onTapGesture { focused = true }
    .onAppear { focused = true }
  }
}

/// A password field with a Show / Hide toggle (Paper "Sign in · Face ID first"). `isNew`
/// picks `.newPassword` (with Hasala's password rules for AutoFill) over `.password`.
struct PasswordInput: View {
  var placeholder: String
  @Binding var text: String
  var isNew: Bool
  var identifier: String
  @State private var visible = false

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if visible {
          TextField(placeholder, text: $text)
        } else {
          SecureField(placeholder, text: $text)
        }
      }
      .textContentType(isNew ? .newPassword : .password)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .accessibilityIdentifier(identifier)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        visible.toggle()
      } label: {
        Label(visible ? "Hide" : "Show", systemImage: visible ? "eye.slash" : "eye")
          .labelStyle(.titleAndIcon)
          .hType(.buttonSmall)
          .foregroundStyle(HColor.textPrimary)
          .padding(.horizontal, 12)
          .frame(height: 36)
          .background(HColor.chipSurfaceOnCard, in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(visible ? "Hide password" : "Show password")
    }
  }
}

/// The new-password block: field, strength meter with the three checks, the repeat field
/// and the footer (Paper "Create a password"; spec 04 §6.1.2).
struct NewPasswordBlock: View {
  @Binding var password: String
  @Binding var confirm: String
  var assessment: PasswordAssessment
  var matches: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Your password signs you in. It can't unlock your data: on a new iPhone you'll also need your recovery phrase or a passkey.")
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      LabeledField(label: "Password") {
        PasswordInput(placeholder: "12 characters or more", text: $password, isNew: true, identifier: "password.new")
      }
      if !password.isEmpty { meter }
      LabeledField(label: "Type it again",
                   error: !confirm.isEmpty && !matches && confirm.count >= password.count ? "Passwords don't match." : nil) {
        PasswordInput(placeholder: "Same password", text: $confirm, isNew: true, identifier: "password.confirm")
      }
      if matches {
        StatusLine(text: "Passwords match.", tone: .success)
      }
      LockNote(text: "Your password is scrambled on this iPhone before it's sent. Our server never sees your password, only the scrambled form, which is slow to guess from.")
    }
  }

  private var meter: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 4) {
        ForEach(1...4, id: \.self) { i in
          Capsule()
            .fill(i <= filled ? meterColor : HColor.appleFillsSecondary)
            .frame(height: 4)
        }
      }
      .accessibilityHidden(true)
      if let message = assessment.message {
        StatusLine(text: message, tone: assessment.acceptable ? .success : .error)
      }
      Divider()
      check("12 or more characters", assessment.longEnough)
      check("Not your name or email", assessment.notPersonal)
      check("Not a common or leaked password", assessment.notCommon)
    }
    .padding(16)
    .listCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("password.meter")
  }

  private var filled: Int {
    switch assessment.strength {
    case .empty: 0
    case .tooShort: 1
    case .weak: 1
    case .fair: 3
    case .strong: 4
    }
  }

  private var meterColor: Color {
    assessment.acceptable ? HColor.statusSuccessForeground : HColor.statusErrorForeground
  }

  private func check(_ text: String, _ ok: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: ok ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(ok ? HColor.statusSuccessForeground : HColor.iconTertiary)
        .accessibilityHidden(true)
      Text(text).hType(.subheadline).foregroundStyle(HColor.textPrimary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(ok ? "done" : "not yet")
  }
}

/// An email field paired with AutoFill (`.username`), lower-case, no autocorrect.
struct EmailInput: View {
  var placeholder = "you@example.com"
  @Binding var text: String
  var identifier: String

  var body: some View {
    TextField(placeholder, text: $text)
      .textContentType(.username)
      .keyboardType(.emailAddress)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .accessibilityIdentifier(identifier)
  }
}

/// Twelve numbered words in two columns, LTR forced (spec 04 §6.7).
struct PhraseGrid: View {
  var words: [String]
  var hidden: Bool

  var body: some View {
    let half = (words.count + 1) / 2
    HStack(alignment: .top, spacing: 8) {
      column(Array(words.prefix(half)), start: 1)
      column(Array(words.dropFirst(half)), start: half + 1)
    }
    .padding(16)
    .listCard()
    .blur(radius: hidden ? 9 : 0)
    .environment(\.layoutDirection, .leftToRight)
    .privacySensitive()
    .accessibilityElement(children: hidden ? .ignore : .contain)
    .accessibilityLabel(hidden ? "Your words are hidden" : "")
    .accessibilityIdentifier("phrase.grid")
  }

  private func column(_ ws: [String], start: Int) -> some View {
    VStack(spacing: 8) {
      ForEach(Array(ws.enumerated()), id: \.offset) { i, w in
        HStack(spacing: 10) {
          Text("\(start + i)")
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .frame(minWidth: 18, alignment: .trailing)
          Text(w)
            .hType(.headline)
            .foregroundStyle(HColor.textPrimary)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: HRadius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Word \(start + i), \(w)")
      }
    }
    .frame(maxWidth: .infinity)
  }
}
