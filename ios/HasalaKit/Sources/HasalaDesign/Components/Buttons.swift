import HasalaModels
import SwiftUI

/// Pill buttons (Paper page 10, "A pill for every action."): pills only, in three heights,
/// Large 54, Medium 44, Small 36. Type says how important the action is; size says where it
/// lives. One primary per decision.
///
/// Pressed darkens the fill and scales to 0.97 at once, then eases back (decision 1, `.press`);
/// with Reduce Motion only the colour changes. Disabled greys out but stays readable. Loading
/// shows a spinner before the label (pass the verb, "Saving"), keeps the button's size and
/// colour, and blocks a second tap; the spinner waits about 300 ms so fast actions don't flash.
public struct PillButtonStyle: ButtonStyle {
  public enum Kind: Sendable {
    /// The one main action: accent fill, white label.
    case primary
    /// The other choice: accent-subtle fill, link label.
    case secondary
    /// A quiet action on the grey canvas: white fill, link label.
    case onGrouped
    /// Text only, no fill (Cancel under a Large).
    case tertiary
    /// The last step of a loss: destructive fill, white label.
    case destructive
    /// A red label that opens a confirm ("Sign out"): white fill on the grey canvas.
    case destructiveQuiet
    /// A red label with no fill and an 8 inset ("Archive"). The old name for the quiet kind
    /// without a fill; kept.
    case destructiveText
  }

  public enum Size: Sendable {
    case large, medium, small

    var height: CGFloat {
      switch self {
      case .large: HSpacing.buttonHeightLarge
      case .medium: HSpacing.buttonHeightMedium
      case .small: HSpacing.buttonHeightSmall
      }
    }

    var inset: CGFloat {
      switch self {
      case .large: HSpacing.buttonInsetLarge
      case .medium: HSpacing.buttonInsetMedium
      case .small: HSpacing.buttonInsetSmall
      }
    }
  }

  let kind: Kind
  let size: Size
  let fill: Bool
  let loading: Bool
  let leadingIcon: HIcon?

  /// `fill` stretches the pill to the width it is offered (sheet CTAs, a pair in a card).
  /// `leadingIcon` is for a known system act only (Face ID, export, add): 18 with an 8 gap,
  /// Face ID 22 with a 10 gap, in the label's colour.
  public init(_ kind: Kind = .primary, size: Size = .large, fill: Bool = false, loading: Bool = false,
              leadingIcon: HIcon? = nil)
  {
    self.kind = kind
    self.size = size
    self.fill = fill
    self.loading = loading
    self.leadingIcon = leadingIcon
  }

  public func makeBody(configuration: Configuration) -> some View {
    PillButtonBody(configuration: configuration, kind: kind, size: size, fill: fill, loading: loading,
                   leadingIcon: leadingIcon)
  }
}

public extension ButtonStyle where Self == PillButtonStyle {
  static func pill(
    _ kind: PillButtonStyle.Kind = .primary, size: PillButtonStyle.Size = .large, fill: Bool = false,
    loading: Bool = false, leadingIcon: HIcon? = nil
  ) -> PillButtonStyle {
    PillButtonStyle(kind, size: size, fill: fill, loading: loading, leadingIcon: leadingIcon)
  }
}

struct PillButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: PillButtonStyle.Kind
  let size: PillButtonStyle.Size
  let fill: Bool
  let loading: Bool
  let leadingIcon: HIcon?
  @Environment(\.isEnabled) private var isEnabled
  @ResolvedMotion private var motion: MotionPolicy
  /// The spinner shows only once loading has lasted about 300 ms (page 17 · ButtonLoading).
  @State private var showsSpinner = false

  var body: some View {
    let pressed = configuration.isPressed && !loading
    HStack(spacing: leadingIcon == .faceID ? 10 : 8) {
      if loading && showsSpinner {
        Spinner(size: size == .small ? 16 : 20, tint: foreground, track: spinnerTrack)
      } else if let leadingIcon, !loading {
        HIconView(leadingIcon, size: leadingIcon == .faceID ? 22 : HSpacing.iconInline, color: foreground)
      }
      configuration.label
        .multilineTextAlignment(.center)
        // One line at the default size; above it the label wraps and the pill grows.
        .lineLimitAtDefaultTextSize(1)
    }
    .hType(size == .small ? .smallButton : .button)
    .foregroundStyle(foreground)
    .padding(.horizontal, kind == .destructiveText ? 8 : size.inset)
    .padding(.vertical, 4)
    .frame(maxWidth: fill ? .infinity : nil, minHeight: size.height)
    .background(background(pressed: pressed), in: Capsule())
    .contentShape(Capsule())
    .scaleEffect(pressed && !motion.isStill ? HMotion.pressScale : 1)
    // Down at once, back over 120 ms.
    .animation(pressed ? nil : motion.animation(.press), value: pressed)
    .allowsHitTesting(!loading)
    .accessibilityValue(loading ? Text("In progress") : Text(""))
    .task(id: loading) {
      guard loading else {
        showsSpinner = false
        return
      }
      try? await Task.sleep(for: .milliseconds(300))
      if !Task.isCancelled { showsSpinner = true }
    }
  }

  private var foreground: Color {
    if !isEnabled { return HColor.textDisabled }
    switch kind {
    case .primary, .destructive: return HColor.textOnAccent
    case .secondary, .onGrouped, .tertiary: return HColor.textLink
    case .destructiveQuiet, .destructiveText: return HColor.actionDestructive
    }
  }

  private var spinnerTrack: Color {
    switch kind {
    case .primary, .destructive: HColor.white.opacity(0.35)
    default: HColor.actionAccentSubtlePressed
    }
  }

  private func background(pressed: Bool) -> Color {
    if !isEnabled {
      switch kind {
      // On grouped keeps its white fill: the disabled grey matches the canvas.
      case .onGrouped, .destructiveQuiet: return HColor.surfacePrimary
      case .tertiary, .destructiveText: return .clear
      default: return HColor.actionDisabled
      }
    }
    switch kind {
    case .primary: return pressed ? HColor.actionAccentPressed : HColor.actionAccent
    case .secondary: return pressed ? HColor.actionAccentSubtlePressed : HColor.actionAccentSubtle
    case .onGrouped, .destructiveQuiet: return pressed ? HColor.listRowSurfacePressed : HColor.surfacePrimary
    case .tertiary: return pressed ? HColor.stateLayerPressed : .clear
    case .destructive: return pressed ? HColor.actionDestructivePressed : HColor.actionDestructive
    case .destructiveText: return pressed ? HColor.stateLayerPressed : .clear
    }
  }
}

/// The press for a custom button (a card that opens one thing, a tile): scale 0.97 and the
/// pressed state layer at once, 120 ms back (`.press`). With Reduce Motion, the layer only.
/// Rows and list groups never scale: use `HRowPressStyle`.
public struct HPressStyle: ButtonStyle {
  let shape: AnyShape
  let scales: Bool

  /// A pill or a circle (the default shape is a capsule).
  public init(scales: Bool = true) {
    self.init(in: Capsule(), scales: scales)
  }

  /// A card or tile: pass its shape, so the pressed layer follows the corners.
  public init<S: Shape>(in shape: S, scales: Bool = true) {
    self.shape = AnyShape(shape)
    self.scales = scales
  }

  public func makeBody(configuration: Configuration) -> some View {
    PressBody(configuration: configuration, shape: shape, scales: scales)
  }

  struct PressBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: AnyShape
    let scales: Bool
    @ResolvedMotion private var motion: MotionPolicy

    var body: some View {
      let pressed = configuration.isPressed
      configuration.label
        .overlay { if pressed { shape.fill(HColor.stateLayerPressed) } }
        .contentShape(shape)
        .scaleEffect(pressed && scales && !motion.isStill ? HMotion.pressScale : 1)
        .animation(pressed ? nil : motion.animation(.press), value: pressed)
    }
  }
}

/// A row in a list card: the whole row takes the pressed fill for the touch (100 ms), card
/// corners only on end rows (the card clips). Rows never scale (page 15 §03).
public struct HRowPressStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .background(configuration.isPressed ? HColor.listRowSurfacePressed : .clear)
      .animation(.easeOut(duration: HMotion.highlight), value: configuration.isPressed)
  }
}

/// "Continue with Google" / "Continue with Microsoft" (page 15 · Mailboxes): the Primary Large
/// pill, full width, with the provider's mark in a 26 white disc. One per screen, after the
/// person has picked a provider. The label names the company, not the app.
public struct ProviderButton: View {
  let provider: MailProviderKind
  let loading: Bool
  let action: () -> Void

  public init(provider: MailProviderKind, loading: Bool = false, action: @escaping () -> Void) {
    self.provider = provider
    self.loading = loading
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if !loading { ProviderMark(provider, size: .disc26) }
        Text(provider.continueTitle)
      }
    }
    .buttonStyle(.pill(.primary, size: .large, fill: true, loading: loading))
  }
}
