import HasalaDesign
import HasalaModels
import SwiftUI

/// What a "Confirm it's you" sheet asks for (Paper P2.6): the change it names, how the
/// person confirms, and what will happen.
struct ConfirmRequest: Equatable {
  /// How this account proves it's the holder (spec 09 P2.6).
  enum Factor: Equatable {
    /// A passkey account: Face ID, through the system's passkey sheet.
    case faceID
    /// A password-only account: the password, and this iPhone's own key signs too.
    case password
    /// A password-only account on an iPhone whose data is still sealed: it has no key yet,
    /// so it can't sign (Paper IYT "This iPhone can't confirm yet").
    case noKey
  }

  /// The change, as an imperative ("Remove the Work iPad passkey", "Show your 12 words").
  var title: String
  var factor: Factor
  /// What will happen, one line each (the passkey board's bullet card).
  var bullets: [String] = []
}

/// "Confirm it's you" (Paper P2.6 IHY, INK, IT2, IYT): the one confirmation every sensitive
/// change goes through. A floating medium sheet (8 from the edges, radius 40, the grey sheet
/// surface, height fitted to its content, one detent), with Close, the 64 hero disc, the
/// change named, then Face ID's bullet card or the password with this iPhone's key.
///
/// It may sit over Sign-in & security's large sheet: the one stack the design allows. The
/// system Face ID HUD and passkey sheet are iOS's; this sheet only says what is about to
/// happen. A wrong password keeps the sheet up with the field ringed; a cancelled Face ID
/// keeps it up quietly; a missing device key turns it into the "can't confirm yet" variant.
struct ConfirmItsYouSheet: View {
  var request: ConfirmRequest
  @Binding var password: String
  var busy: Bool
  var failure: AuthFailure?
  var onConfirm: () -> Void
  /// "Enter my 12 words" on the no-key variant, where the host can open the words.
  var onEnterWords: (() -> Void)?
  var onClose: () -> Void

  @State private var height: CGFloat = 520
  @State private var visible = false
  @FocusState private var passwordFocused: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    ScrollView {
      content
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0.rounded(.up) }
    }
    .scrollBounceBehavior(.basedOnSize)
    // One detent that fits the content; at the accessibility sizes it grows to large and
    // scrolls (page 14 §10: "medium sheets grow to large, then scroll").
    .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(height)])
    .presentationCornerRadius(HRadius.sheet)
    .presentationBackground(HColor.surfaceSecondary)
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(busy)
    .onAppear { if request.factor == .password { passwordFocused = true } }
  }

  private var content: some View {
    VStack(spacing: 0) {
      header
      VStack(spacing: 16) {
        HeroDisc(icon: hero.icon, hue: hero.hue, shadow: request.factor == .noKey)
          .padding(.bottom, request.factor == .noKey ? 8 : 0)
        VStack(spacing: 6) {
          Text(title)
            .hType(.section)
            .foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          Text(subtitle)
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        switch request.factor {
        case .faceID:
          if !request.bullets.isEmpty { BulletCard(lines: request.bullets) }
        case .password:
          passwordField
          DeviceKeyRow()
        case .noKey:
          BulletCard(lines: onEnterWords == nil
            ? ["Make the change on your other iPhone, where your data is open"]
            : ["Enter your 12 words to open it here", "Or make the change on your other iPhone"])
        }
        if let message = otherFailure?.message {
          FieldErrorLine(text: message)
            .accessibilityIdentifier("confirm.failure")
        }
        primary
      }
      .padding(.top, 12)
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.bottom, 30)
  }

  /// Paper's sheet header (48): Close glass, the title centred, an empty 48 slot. The
  /// system grabber sits above it.
  private var header: some View {
    HStack {
      GlassIconButton(.close, label: "Close", action: onClose)
        .accessibilityIdentifier("confirm.cancel")
        .disabled(busy)
      Spacer(minLength: 8)
      Text("Confirm it's you")
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
        .foregroundStyle(HColor.textPrimary)
        .lineLimit(1)
      Spacer(minLength: 8)
      Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
    }
    .padding(.top, 21)
  }

  private var hero: (icon: HIcon, hue: Hue) {
    switch request.factor {
    case .faceID: (.faceID, .sky)
    case .password: (.password, .other)
    case .noKey: (.lock, .sand)
    }
  }

  private var title: String { request.factor == .noKey ? "This iPhone can't confirm yet" : request.title }

  private var subtitle: String {
    switch request.factor {
    case .faceID: "Face ID confirms it's really you, using your passkey."
    case .password: "Your current password, plus this iPhone's own key. Neither one can do it alone."
    case .noKey:
      "Changes need your password plus the key of an iPhone where your data is open. Here it's still sealed."
    }
  }

  /// A wrong password rings the field; anything else is said above the button.
  private var otherFailure: AuthFailure? {
    guard let failure, !(request.factor == .password && failure == .stepUpFailed) else { return nil }
    return failure
  }

  private var passwordField: some View {
    FieldFrame(
      label: "Current password",
      error: request.factor == .password && failure == .stepUpFailed ? failure?.message : nil,
      focused: passwordFocused, trailingPill: true, labelsField: true, onTap: { passwordFocused = true }
    ) {
      Group {
        if visible {
          TextField("Your password", text: $password)
        } else {
          SecureField("Your password", text: $password)
        }
      }
      .textContentType(.password)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .submitLabel(.done)
      .onSubmit { if !password.isEmpty, !busy { onConfirm() } }
      .focused($passwordFocused)
      .accessibilityIdentifier("confirm.password")
      .accessibilityLabel("Current password")
    } trailing: {
      ShowHidePill(visible: $visible)
    }
  }

  @ViewBuilder private var primary: some View {
    switch request.factor {
    case .faceID:
      Button("Confirm with Face ID", action: onConfirm)
        .buttonStyle(.pill(.primary, fill: true, loading: busy, leadingIcon: .faceID))
        .accessibilityIdentifier("confirm.submit")
    case .password:
      Button("Confirm", action: onConfirm)
        .buttonStyle(.pill(.primary, fill: true, loading: busy))
        .disabled(password.isEmpty)
        .accessibilityIdentifier("confirm.submit")
    case .noKey:
      if let onEnterWords {
        Button("Enter my 12 words", action: onEnterWords)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("confirm.enterWords")
      } else {
        Button("Close", action: onClose)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("confirm.close")
      }
    }
  }
}

/// "This iPhone signs it too" (Paper IT2 "DeviceKeyRow"): the password's partner, shown so
/// the person knows the password alone can't make the change.
private struct DeviceKeyRow: View {
  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(Hue.mint.perceptualGradient)
        .frame(width: 32, height: 32)
        .overlay { HIconView(.phone, size: 18, color: Hue.mint.ink) }
      VStack(alignment: .leading, spacing: 1) {
        Text("This iPhone signs it too")
          .hType(.subheadline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
        Text("Its own key, never sent")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      HIconView(.check, size: 20, color: HColor.statusSuccessForeground, strokeWidth: 2)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
