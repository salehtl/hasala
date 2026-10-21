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
      if let badge, !paired {
        GlassBadge(count: badge)
      }
    }
    .anchorPreference(key: GlassBadgeAnchors.self, value: .bounds) { bounds in
      guard paired, let badge, badge > 0 else { return [] }
      return [GlassBadgeAnchor(count: badge, bounds: bounds)]
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
  @Environment(\.layoutDirection) private var layoutDirection

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    HStack(spacing: 0) { content }
      .environment(\.hGlassPaired, true)
      .hGlass(in: Capsule())
      .overlayPreferenceValue(GlassBadgeAnchors.self) { anchors in
        GeometryReader { proxy in
          ForEach(anchors.indices, id: \.self) { index in
            let frame = proxy[anchors[index].bounds]
            Color.clear
              .frame(width: frame.width, height: frame.height)
              .overlay(alignment: .topLeading) { GlassBadge(count: anchors[index].count) }
              .environment(\.layoutDirection, layoutDirection)
              .position(x: frame.midX, y: frame.midY)
          }
        }
        .environment(\.layoutDirection, .leftToRight)
      }
      .accessibilityElement(children: .contain)
  }
}

struct GlassBadge: View {
  let count: Int

  var body: some View {
    CountBadge(count, style: .glass20)
      .padding(.leading, 29)
      .offset(y: -3)
      .allowsHitTesting(false)
  }
}

struct GlassBadgeAnchor {
  let count: Int
  let bounds: Anchor<CGRect>
}

struct GlassBadgeAnchors: PreferenceKey {
  static let defaultValue: [GlassBadgeAnchor] = []

  static func reduce(value: inout [GlassBadgeAnchor], nextValue: () -> [GlassBadgeAnchor]) {
    value.append(contentsOf: nextValue())
  }
}

/// The Profile glass button: a 36 initial disc inside the glass, 6 in (page 10, Avatar). It
/// opens Your profile from the Home header.
public struct GlassAvatarButton: View {
  let initial: String
  let email: String?
  let label: String
  let action: () -> Void

  public init(initial: String, email: String? = nil, label: String = "Profile", action: @escaping () -> Void) {
    self.initial = initial
    self.email = email
    self.label = label
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      AvatarDisc(initial: initial, size: 36, email: email)
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
