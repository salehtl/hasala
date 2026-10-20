import HasalaModels
import SwiftUI

/// A 48 pt glass circle in screen chrome (page 10 "Glass for chrome, system for the OS.";
/// page 13 headers, page 14 sheet headers): Hide amounts, Notifications, Back, Close, Add,
/// More, Share, Filter, and the accent Done. Icon only: the label is for VoiceOver ("Back",
/// "Notifications, 4 new", "Hide amounts"); the circle never holds text.
///
/// Native Liquid Glass (the system brightens it on press, so there is no custom pressed fill);
/// solid with a hairline under Reduce Transparency. Dynamic Type does not grow the circle.
public struct GlassIconButton: View {
  let icon: HIcon
  let label: String
  let badge: Int?
  let prominent: Bool
  let selected: Bool?
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.hGlassPaired) private var paired

  /// `badge` draws the count top right (hidden at 0, "99+" past 99); put the count in `label`
  /// too, since the badge is hidden from VoiceOver. `prominent` is the accent Done (one per
  /// screen). `selected` marks a toggle such as Hide amounts.
  public init(_ icon: HIcon, label: String, badge: Int? = nil, prominent: Bool = false, selected: Bool? = nil,
              action: @escaping () -> Void)
  {
    self.icon = icon
    self.label = label
    self.badge = badge
    self.prominent = prominent
    self.selected = selected
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      ZStack {
        // A toggle's glyph swap (the eye of Hide amounts) cross-fades, 150 ms at most.
        HIconView(icon, size: iconSize, color: iconColor)
          .id(icon)
          .transition(.opacity)
      }
      .frame(width: paired ? HSpacing.targetMinimum : HSpacing.glassButton, height: HSpacing.glassButton)
      .hAnimation(.hideAmounts, value: icon)
      .hGlass(in: Circle(), prominent: prominent)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .topLeading) {
      if let badge {
        CountBadge(badge, style: .glass20)
          // Paper: left 29, top −3 on the 48 circle.
          .offset(x: 29, y: -3)
          .allowsHitTesting(false)
      }
    }
    .accessibilityLabel(label)
    .accessibilityAddTraits(selected == true ? .isSelected : [])
    // Dynamic Type does not grow the circle; a long press shows the icon and its name large.
    .accessibilityShowsLargeContentViewer {
      HIconView(icon, size: 28, color: HColor.iconPrimary)
      Text(label)
    }
  }

  /// 22 for every glass glyph (`--spacing-icon-glass`), 24 for the two eye glyphs.
  private var iconSize: CGFloat {
    icon == .eye || icon == .eyeSlash ? HSpacing.iconLarge : HSpacing.iconGlass
  }

  private var iconColor: Color {
    if !isEnabled { return HColor.controlNavigationDisabledForeground }
    return prominent ? HColor.iconOnAccent : HColor.iconGlass
  }
}

public struct GlassButtonPair<Content: View>: View {
  let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    HStack(spacing: 0) { content }
      .environment(\.hGlassPaired, true)
      .hGlass(in: Capsule())
      .accessibilityElement(children: .contain)
  }
}

/// The Profile glass button: a 36 initial disc inside the glass, 6 in (page 10, Avatar). It
/// opens Your profile from the Home header.
public struct GlassAvatarButton: View {
  let initial: String
  let label: String
  let action: () -> Void

  public init(initial: String, label: String = "Profile", action: @escaping () -> Void) {
    self.initial = initial
    self.label = label
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      AvatarDisc(initial: initial, size: 36)
        .frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
        .hGlass(in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityShowsLargeContentViewer {
      Text(label)
    }
  }
}
