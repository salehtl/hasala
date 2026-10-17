import HasalaDesign
import SwiftUI
import UIKit

// The account fields (Paper page 11 "Type it once, see what's wrong." and "One box per
// character, one cell per word."; spec 02 §11, spec 07 §6): a filled box with its label
// above, a 2 pt ring outside the box only for focus or a failed check, and one line of help
// or error below. Codes and the recovery phrase are one field drawn as cells.

// MARK: - Field

/// Where a field sits: white on the grouped grey, grey on a white card or sheet.
enum FieldSurface {
  case onGrouped, onCard

  var fill: Color {
    switch self {
    case .onGrouped: HColor.fieldSurfaceOnGrouped
    case .onCard: HColor.fieldSurface
    }
  }
}

/// A labelled field (Paper "TextField"): the 13/18 label 6 above a 52 box (radius 14, 16 in,
/// 8 on the right when a pill sits inside), a value in 17/22, the blue ring while typing, the
/// red ring and a 15/20 line after a failed check, otherwise a 13/18 help line.
///
/// The whole box takes the tap and focuses the field. `focused` overrides what the field
/// reports (a UIKit field inside, or a screen that keeps its own focus state). `field` is the
/// bare control, which takes the label as its VoiceOver name and the help or error as its
/// hint; a Show / Hide pill or a clear button goes in `trailing`.
struct AccountField<Field: View, Trailing: View>: View {
  var label: String
  var help: String?
  var error: String?
  var surface: FieldSurface
  var focused: Bool?
  @ViewBuilder var field: () -> Field
  @ViewBuilder var trailing: () -> Trailing

  @FocusState private var hasFocus: Bool

  init(
    _ label: String, help: String? = nil, error: String? = nil, surface: FieldSurface = .onGrouped,
    focused: Bool? = nil, @ViewBuilder field: @escaping () -> Field, @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.label = label
    self.help = help
    self.error = error
    self.surface = surface
    self.focused = focused
    self.field = field
    self.trailing = trailing
  }

  var body: some View {
    FieldFrame(label: label, help: help, error: error, focused: focused ?? hasFocus, surface: surface,
               trailingPill: Trailing.self != EmptyView.self, labelsField: true, onTap: { hasFocus = true }) {
      field()
        .focused($hasFocus)
        // The label names the field for VoiceOver; help and errors are read after it.
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(error.map { "Error: \($0)" } ?? help ?? ""))
    } trailing: {
      trailing()
    }
  }
}

extension AccountField where Trailing == EmptyView {
  init(
    _ label: String, help: String? = nil, error: String? = nil, surface: FieldSurface = .onGrouped,
    focused: Bool? = nil, @ViewBuilder field: @escaping () -> Field
  ) {
    self.init(label, help: help, error: error, surface: surface, focused: focused, field: field,
              trailing: { EmptyView() })
  }
}

/// The drawing every field shares: label, box, ring, and the line below.
struct FieldFrame<Field: View, Trailing: View>: View {
  var label: String
  var help: String?
  var error: String?
  var focused: Bool
  var surface: FieldSurface = .onGrouped
  var trailingPill: Bool
  /// The control carries the label itself, so the drawn one is not read twice.
  var labelsField = false
  var onTap: (() -> Void)?
  @ViewBuilder var field: () -> Field
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.fieldLabelGap) {
      Text(label)
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.textSecondary)
        .accessibilityHidden(labelsField)
      HStack(spacing: 8) {
        field()
          .hType(Self.valueType)
          .foregroundStyle(HColor.fieldText)
          .tint(HColor.actionAccent)
          .frame(maxWidth: .infinity, alignment: .leading)
        trailing()
      }
      .padding(.leading, HSpacing.fieldInsetInline)
      .padding(.trailing, trailingPill ? 8 : HSpacing.fieldInsetInline)
      .frame(minHeight: HSpacing.fieldMinHeight)
      .background(surface.fill, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
      .overlay { FieldRing(color: ringColor) }
      .modifier(BoxTap(action: onTap))
      if let error {
        FieldErrorLine(text: error)
          .padding(.top, 2)
      } else if let help {
        Text(help)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .hAnimation(.fade, value: ringColor == .clear)
  }

  /// Field values: Inter 17/22 regular.
  static var valueType: HType { HType(size: 17, leading: 22, weight: .regular, textStyle: .body) }

  private var ringColor: Color {
    if error != nil { return HColor.fieldError }
    return focused ? HColor.fieldFocus : .clear
  }
}

/// A tap anywhere in a field's box focuses the field. Alongside the field's own tap, never
/// instead of it, so a tap on the text still places the caret (and UI tests can type).
private struct BoxTap: ViewModifier {
  let action: (() -> Void)?

  func body(content: Content) -> some View {
    if let action {
      content
        .contentShape(RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .simultaneousGesture(TapGesture().onEnded(action))
    } else {
      content
    }
  }
}

/// The 2 pt ring drawn outside a box's edge, no gap (box-shadow 0 0 0 2px).
struct FieldRing: View {
  var color: Color
  var radius: CGFloat = HRadius.field

  var body: some View {
    RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
      .strokeBorder(color, lineWidth: 2)
      .padding(-2)
      .allowsHitTesting(false)
  }
}

/// The line under a field or cells that failed a check: a 7 pt dot centred on the first
/// line, then 15/20 medium in the error (or warning) ink. Colour never works alone.
struct FieldErrorLine: View {
  var text: String
  var warning = false

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle().fill(ink).frame(width: 7, height: 7).frame(height: lane)
      Text(text)
        .hType(.subheadline.weight(.medium))
        .foregroundStyle(ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }

  private var ink: Color { warning ? HColor.statusWarningForeground : HColor.statusErrorForeground }
}

/// Show / Hide inside a password box (Paper "RevealPill"): 36 tall, the chip grey, an 18 eye
/// (slashed when shown) and 15/20 semibold; a 44 target. At the accessibility sizes it is
/// the eye alone.
struct ShowHidePill: View {
  @Binding var visible: Bool
  /// What it shows, for VoiceOver ("Show password").
  var subject = "password"

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Button {
      visible.toggle()
    } label: {
      HStack(spacing: 6) {
        HIconView(visible ? .eyeSlash : .eye, size: 18, color: HColor.iconPrimary)
        if !typeSize.isAccessibilitySize {
          Text(visible ? "Hide" : "Show")
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textPrimary)
        }
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 36)
      .background(HColor.chipSurfaceOnCard, in: Capsule())
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(HPressStyle(scales: false))
    .accessibilityLabel(visible ? "Hide \(subject)" : "Show \(subject)")
  }
}

/// A password field with Show / Hide (Paper "Sign in · Face ID first"). `isNew` picks
/// `.newPassword` (with Hasala's password rules for AutoFill) over `.password`.
struct PasswordInput: View {
  var placeholder: String
  @Binding var text: String
  var isNew: Bool
  var identifier: String
  @State private var visible = false

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if isNew {
          // SwiftUI's fields can't carry `passwordRules`; a UITextField can.
          RuledNewPasswordField(placeholder: placeholder, text: $text, secure: !visible, identifier: identifier)
        } else if visible {
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
      ShowHidePill(visible: $visible)
    }
  }
}

/// A new-password field that hands iOS Hasala's strong-password rules (spec 04 §6.1.2:
/// `minlength: 12; maxlength: 128;`), so AutoFill suggests a password the rules accept.
struct RuledNewPasswordField: UIViewRepresentable {
  static let rules = "minlength: 12; maxlength: 128;"

  var placeholder: String
  @Binding var text: String
  var secure: Bool
  var identifier: String

  func makeUIView(context: Context) -> UITextField {
    let f = UITextField()
    f.placeholder = placeholder
    f.textContentType = .newPassword
    f.passwordRules = UITextInputPasswordRules(descriptor: Self.rules)
    f.autocapitalizationType = .none
    f.autocorrectionType = .no
    f.spellCheckingType = .no
    f.font = .preferredFont(forTextStyle: .body)
    f.adjustsFontForContentSizeCategory = true
    f.textColor = UIColor(HColor.fieldText)
    f.tintColor = UIColor(HColor.actionAccent)
    f.accessibilityIdentifier = identifier
    f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    f.setContentHuggingPriority(.defaultHigh, for: .vertical)
    f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    f.delegate = context.coordinator
    return f
  }

  func updateUIView(_ f: UITextField, context: Context) {
    context.coordinator.text = $text
    if f.text != text { f.text = text }
    if f.isSecureTextEntry != secure { f.isSecureTextEntry = secure }
    f.placeholder = placeholder
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: uiView.intrinsicContentSize.height)
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }

    @objc func changed(_ f: UITextField) { text.wrappedValue = f.text ?? "" }

    func textFieldShouldReturn(_ f: UITextField) -> Bool {
      f.resignFirstResponder()
      return true
    }
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

// MARK: - Password strength

/// The strength card under a new password (Paper "PasswordStrengthCard", S10a/b): a four-part
/// meter, the one status line, a hairline, then the three rules that tick as they pass. Only
/// positive, live feedback while typing (page 11 §05).
struct PasswordStrengthCard: View {
  var assessment: PasswordAssessment

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 4) {
        ForEach(1...4, id: \.self) { i in
          RoundedRectangle(cornerRadius: 3)
            .fill(i <= filled ? meterColor : HColor.paceTrack)
            .frame(height: 6)
        }
      }
      .hAnimation(.fade, value: filled)
      .accessibilityHidden(true)
      if let message = assessment.message {
        StatusLine(text: message, tone: assessment.acceptable ? .success : .error, size: .regular)
      }
      Rectangle().fill(HColor.borderSubtle).frame(height: 1)
      VStack(alignment: .leading, spacing: 10) {
        rule("12 or more characters", assessment.longEnough)
        rule("Not your name or email", assessment.notPersonal)
        // TODO(WS-14, spec 04 §4.6): the bundled list is a short starter list; the full
        // one built by ios/tools/passwords from a public breach list replaces it, and the
        // copy can then say "leaked" again (Paper: "Not a common or leaked password").
        rule("Not on our list of common passwords", assessment.notCommon)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("password.meter")
  }

  private var filled: Int {
    switch assessment.strength {
    case .empty: 0
    case .tooShort, .weak: 1
    case .fair: 3
    case .strong: 4
    }
  }

  private var meterColor: Color {
    assessment.acceptable ? HColor.statusSuccessForeground : HColor.statusErrorForeground
  }

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  private func rule(_ text: String, _ met: Bool) -> some View {
    HStack(alignment: .top, spacing: 10) {
      ZStack {
        Circle().strokeBorder(HColor.neutral300, lineWidth: 1.5).opacity(met ? 0 : 1)
        Circle().fill(HColor.statusSuccessForeground).opacity(met ? 1 : 0)
        HIconView(.check, size: 11, color: HColor.white, strokeWidth: 3.4).opacity(met ? 1 : 0)
      }
      .frame(width: 18, height: 18)
      .frame(height: lane)
      .hAnimation(.fade, value: met)
      Text(text).hType(.subheadline).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(met ? "done" : "not yet")
  }
}

/// The new-password block: field, strength card, the repeat field and the notes (Paper
/// "Create a password"; spec 04 §6.1.2).
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
      // The password field and its pill come as one control, so the field frame draws them.
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
      NoteRow(icon: .lock, text: "Your password is scrambled on this iPhone before it's sent. Our server never sees your password, only the scrambled form, which is slow to guess from.")
    }
    .hAnimation(.rise, value: password.isEmpty)
  }
}

// MARK: - Code cells

/// A one-time code as six cells over one hidden `.oneTimeCode` field (Paper "CodeCells",
/// S7a–c): two groups of three 52 × 64 cells, digits in SF Pro Rounded 28/34 semibold. The
/// next empty cell takes the focus ring and the caret. A wrong code rings every cell (the
/// digits stay so people can compare); an expired one empties the cells onto the wash and
/// hides the keyboard. iOS may offer the code from Mail; paste fills every cell at once.
struct CodeCells: View {
  enum State: Equatable { case typing, wrong, expired }

  @Binding var code: String
  var state: State = .typing
  var length = 6
  var identifier = "code.field"
  /// What VoiceOver calls the group ("Email code, 3 of 6 digits").
  var label = "Email code"

  @FocusState private var focused: Bool

  var body: some View {
    ZStack {
      TextField("", text: Binding(get: { code }, set: { code = String($0.filter(\.isNumber).prefix(length)) }))
        .textContentType(.oneTimeCode)
        .keyboardType(.numberPad)
        .focused($focused)
        .disabled(state == .expired)
        .foregroundStyle(.clear)
        .tint(.clear)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilityValue("\(code.count) of \(length) digits")
      cells
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
    .onTapGesture { if state != .expired { focused = true } }
    .onAppear { focused = state != .expired }
    .onChange(of: state) { _, new in if new == .expired { focused = false } }
  }

  private var cells: some View {
    let half = length / 2
    return HStack(spacing: 0) {
      group(0..<half)
      Spacer(minLength: 18)
      group(half..<length)
    }
  }

  private func group(_ range: Range<Int>) -> some View {
    HStack(spacing: 8) {
      ForEach(range, id: \.self) { i in cell(i) }
    }
  }

  private func cell(_ i: Int) -> some View {
    let digit = state == .expired || i >= code.count ? "" : String(code[code.index(code.startIndex, offsetBy: i)])
    let isNext = focused && state == .typing && i == min(code.count, length - 1) && code.count < length
    return ZStack {
      Text(digit)
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .foregroundStyle(HColor.textPrimary)
      if isNext && digit.isEmpty {
        RoundedRectangle(cornerRadius: 1).fill(HColor.actionAccent).frame(width: 2, height: 30)
      }
    }
    .frame(width: HSpacing.codeCellWidth, height: HSpacing.codeCellHeight)
    .background(state == .expired ? HColor.surfaceOnWash : HColor.fieldSurfaceOnGrouped,
                in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
    .overlay { FieldRing(color: ring(isNext: isNext)) }
    // Digits stay one row; at the largest sizes the cells keep their box.
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
  }

  private func ring(isNext: Bool) -> Color {
    switch state {
    case .wrong: HColor.fieldError
    case .expired: .clear
    case .typing: isNext ? HColor.fieldFocus : .clear
    }
  }
}

/// The first code field's name, kept for the screens drawn with it: the cells above, with
/// `error` as the wrong state.
struct CodeBoxes: View {
  @Binding var code: String
  var error = false
  var identifier = "code.field"

  var body: some View {
    CodeCells(code: $code, state: error ? .wrong : .typing, identifier: identifier)
  }
}

// MARK: - Recovery phrase

/// The 12 words (Paper "RecoveryPhraseGrid", S12 F6Q/F9O): two columns of six numbered cells
/// in a white card, radius 24, forced left to right; one column at the accessibility sizes.
///
/// Hidden, the words are blurred under a white veil with an eye button, "Tap to show your
/// words": the whole card is one button ("Show your 12 words", `phrase.reveal`). Revealed, a
/// header with "Your recovery phrase" and a Hide pill (`phrase.hide`) sits above read-only
/// cells, each read as "Word 1, orbit". `.privacySensitive()` keeps the words out of
/// snapshots and redacted contexts; the screen hides them on leaving.
///
/// Masked (the screen is recorded or mirrored), every cell holds dots and the veil can't
/// be lifted: it says why instead, so a tap never counts as the words being shown.
struct PhraseGrid: View {
  var words: [String]
  @Binding var revealed: Bool
  var masked = false

  @Environment(\.dynamicTypeSize) private var typeSize

  private var shown: Bool { revealed && !masked }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if shown {
        header.hTransition(.fade)
      }
      ZStack {
        grid
          .blur(radius: shown ? 0 : 9)
          .opacity(shown ? 1 : 0.85)
          .accessibilityHidden(!shown)
        if !shown {
          veil.hTransition(.fade)
        }
      }
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    }
    .hAnimation(.stateSwap, value: shown)
    .environment(\.layoutDirection, .leftToRight)
    .privacySensitive()
  }

  private var header: some View {
    // At the accessibility sizes Hide goes under the heading, so the heading has the width
    // to wrap as words fit rather than one word a line beside it.
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: 8))
    return layout {
      Text("Your recovery phrase").hType(.overline).foregroundStyle(HColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
      Button {
        revealed = false
      } label: {
        HStack(spacing: 6) {
          HIconView(.eyeSlash, size: 16, color: HColor.textLink, strokeWidth: 2)
          Text("Hide").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textLink)
        }
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(HColor.surfacePrimary, in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(HPressStyle(scales: false))
      .accessibilityLabel("Hide your words")
      .accessibilityIdentifier("phrase.hide")
    }
    .padding(.leading, 4)
  }

  private var veil: some View {
    Button {
      if !masked { revealed = true }
    } label: {
      ZStack {
        HColor.white.opacity(0.35)
        VStack(spacing: 10) {
          Circle()
            .fill(HColor.surfacePrimary)
            .frame(width: 56, height: 56)
            .shadow(color: HColor.elevationFar, radius: 8, x: 0, y: 6)
            .overlay { Circle().stroke(HColor.materialGlassOutline, lineWidth: 0.5) }
            .overlay { HIconView(masked ? .eyeSlash : .eye, size: 26, color: HColor.iconAccent) }
          Text(masked ? "Your words stay hidden" : "Tap to show your words")
            .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .body))
            .foregroundStyle(HColor.textPrimary)
          Text(masked ? Self.maskedNote : "Only on this screen, only for you")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(16)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(masked)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(masked ? "Your words stay hidden. \(Self.maskedNote)" : "Show your 12 words")
    .accessibilityAddTraits(masked ? [] : .isButton)
    .accessibilityIdentifier("phrase.reveal")
  }

  static let maskedNote = "Stop recording or mirroring your screen to see them."

  private var grid: some View {
    // Masked, not even the blurred words are drawn.
    let drawn = masked ? Array(repeating: "•••••", count: words.count) : words
    let columns = typeSize.isAccessibilitySize ? 1 : 2
    let perColumn = (drawn.count + columns - 1) / columns
    return HStack(alignment: .top, spacing: 8) {
      ForEach(0..<columns, id: \.self) { c in
        let start = c * perColumn
        column(Array(drawn.dropFirst(start).prefix(perColumn)), start: start + 1)
      }
    }
    .padding(16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("phrase.grid")
  }

  private func column(_ ws: [String], start: Int) -> some View {
    VStack(spacing: 8) {
      ForEach(Array(ws.enumerated()), id: \.offset) { i, w in
        HStack(spacing: 8) {
          Text("\(start + i)")
            .hFigure(HFigure(size: 14, leading: 18, weight: .semibold, textStyle: .subheadline))
            .foregroundStyle(HColor.textSecondary)
            .frame(minWidth: 20, alignment: .trailing)
          Text(w)
            .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .body))
            .foregroundStyle(HColor.textPrimary)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Word \(start + i), \(w)")
      }
    }
    .frame(maxWidth: .infinity)
  }
}
