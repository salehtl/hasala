import HasalaModels
import SwiftUI

/// Pill buttons (Paper "kit Controls"): pills only; Large 54, Medium 44, Small 36.
public struct PillButtonStyle: ButtonStyle {
  public enum Kind: Sendable { case primary, secondary, tertiary, destructive, destructiveText }
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

  /// `fill` stretches the pill to the width it is offered (brief-card buttons, sheet CTAs).
  public init(_ kind: Kind = .primary, size: Size = .large, fill: Bool = false) {
    self.kind = kind
    self.size = size
    self.fill = fill
  }

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .hType(size == .small ? .buttonSmall : .button)
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, kind == .destructiveText ? 8 : size.inset)
      .frame(maxWidth: fill ? .infinity : nil, minHeight: size.height)
      .background(background(pressed: configuration.isPressed), in: Capsule())
      .contentShape(Capsule())
  }

  private var foreground: Color {
    switch kind {
    case .primary, .destructive: HColor.textOnAccent
    case .secondary, .tertiary: HColor.textLink
    case .destructiveText: HColor.actionDestructive
    }
  }

  private func background(pressed: Bool) -> Color {
    switch kind {
    case .primary: pressed ? HColor.actionAccentPressed : HColor.actionAccent
    case .secondary: pressed ? HColor.actionAccentSubtlePressed : HColor.actionAccentSubtle
    case .tertiary: pressed ? HColor.listRowSurfacePressed : HColor.surfacePrimary
    case .destructive: pressed ? HColor.actionDestructivePressed : HColor.actionDestructive
    case .destructiveText: pressed ? HColor.stateLayerPressed : .clear
    }
  }
}

public extension ButtonStyle where Self == PillButtonStyle {
  static func pill(
    _ kind: PillButtonStyle.Kind = .primary, size: PillButtonStyle.Size = .large, fill: Bool = false
  ) -> PillButtonStyle {
    PillButtonStyle(kind, size: size, fill: fill)
  }
}

/// Filter chip (Paper "kit Controls"): 40 tall; ink when selected, white otherwise.
public struct FilterChip: View {
  let title: String
  let count: Int?
  let selected: Bool
  let action: () -> Void

  public init(_ title: String, count: Int? = nil, selected: Bool, action: @escaping () -> Void) {
    self.title = title
    self.count = count
    self.selected = selected
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title).hType(.buttonSmall)
        if let count { CountBadge(count, tone: .accent) }
      }
      .foregroundStyle(selected ? HColor.chipTextSelected : HColor.chipText)
      .padding(.horizontal, count == nil ? HSpacing.chipInset : 14)
      .frame(height: HSpacing.chipHeight)
      .background(selected ? HColor.chipSurfaceSelected : HColor.chipSurface, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The glass toast (Paper "kit Controls"): 56 tall, r28, over content near the tab bar.
/// Glass is for navigation-level chrome only; the toast floats over content, so it is glass.
public struct GlassToast: View {
  let systemImage: String
  let title: String
  let subtitle: String?
  let actionTitle: String?
  let action: (() -> Void)?

  public init(
    systemImage: String, title: String, subtitle: String? = nil, actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.systemImage = systemImage
    self.title = title
    self.subtitle = subtitle
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(HColor.surfaceInverse)
        .frame(width: 36, height: 36)
        .overlay {
          Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)).foregroundStyle(HColor.white)
        }
      VStack(alignment: .leading, spacing: 0) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        if let subtitle { Text(subtitle).hType(.footnote).foregroundStyle(HColor.textSecondary) }
      }
      Spacer(minLength: 8)
      if let actionTitle {
        Button(actionTitle) { action?() }
          .buttonStyle(.plain)
          .hType(.rowTitle)
          .foregroundStyle(HColor.textLink)
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 18)
    .frame(minHeight: HSpacing.toastHeight)
    .glassEffect(.regular, in: .capsule)
    .accessibilityElement(children: .combine)
  }
}
