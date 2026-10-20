import HasalaDesign
import HasalaModels
import SwiftUI

/// The main header on every tab root (Paper "Header · Main", page 13 "The same top on every
/// screen."): Hide amounts on the left (the eye, eye-off while hidden), the Hasala mark
/// centred and not a button, and on the right at most two 48 glass buttons, 10 apart, the
/// profile avatar last. The bell is on every tab, just before the avatar; a tab's own button
/// ("+" on Activity) comes before the bell.
///
/// The buttons are the design system's `GlassIconButton` and `GlassAvatarButton`: native
/// Liquid Glass at Paper's 48 (decision 2), so the bar's own shared glass is turned off for
/// each item. The bell's badge counts what needs a look and is in the button's label.
struct MainHeader: ToolbarContent {
  /// Glass glyphs are ink, not the accent (`--color-icon-glass`); for the bar items other
  /// screens draw themselves.
  static let iconColor = HColor.iconGlass

  enum Extra { case add, none }

  let amountsHidden: Bool
  let extra: Extra
  let unread: Int
  let avatarInitial: String
  let onToggleAmounts: () -> Void
  let onExtra: () -> Void
  let onNotifications: () -> Void
  let onProfile: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      GlassIconButton(amountsHidden ? .eyeSlash : .eye, label: amountsHidden ? "Show amounts" : "Hide amounts",
                      selected: amountsHidden, action: onToggleAmounts)
        .accessibilityIdentifier("header.hideAmounts")
    }
    .sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .principal) {
      Image("HasalaMark")
        .resizable()
        .scaledToFit()
        .frame(width: 54, height: 32)
        .accessibilityLabel("Hasala")
    }
    .sharedBackgroundVisibility(.hidden)
    switch extra {
    case .add:
      ToolbarItem(placement: .topBarTrailing) {
        GlassIconButton(.add, label: "Add a transaction", action: onExtra)
          .accessibilityIdentifier("header.add")
      }
      .sharedBackgroundVisibility(.hidden)
    case .none:
      ToolbarItem(placement: .topBarTrailing) { EmptyView() }
    }
    ToolbarItem(placement: .topBarTrailing) {
      GlassIconButton(.bell, label: Bell.label(unread),
                      badge: unread, action: onNotifications)
        .accessibilityIdentifier("header.notifications")
    }
    .sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .topBarTrailing) {
      GlassAvatarButton(initial: avatarInitial, label: "Your profile", action: onProfile)
        .accessibilityIdentifier("header.profile")
    }
    .sharedBackgroundVisibility(.hidden)
  }
}
