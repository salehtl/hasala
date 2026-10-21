import HasalaDesign
import HasalaModels
import SwiftUI

/// The main header on every tab root (Paper "Header · Main", page 13 "The same top on every
/// screen."): the profile avatar on the left, the Hasala mark centred and not a button, and
/// on the right Hide amounts (the eye, eye-off while hidden), Search and the bell joined in
/// one glass capsule. Adding a transaction is the round button beside the tab bar.
///
/// The buttons are the design system's `GlassIconButton`, `GlassButtonPair` and
/// `GlassAvatarButton`: native Liquid Glass at Paper's 48 (decision 2), so the bar's own
/// shared glass is turned off for each item. The bell's badge counts what needs a look and is
/// in the button's label.
struct MainHeader: ToolbarContent {
  /// Glass glyphs are ink, not the accent (`--color-icon-glass`); for the bar items other
  /// screens draw themselves.
  static let iconColor = HColor.iconGlass

  let amountsHidden: Bool
  let unread: Int
  let avatarInitial: String
  let avatarEmail: String?
  let onToggleAmounts: () -> Void
  let onSearch: () -> Void
  let onNotifications: () -> Void
  let onProfile: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      GlassAvatarButton(initial: avatarInitial, email: avatarEmail, label: "Your profile", action: onProfile)
        .accessibilityIdentifier("header.profile")
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
    ToolbarItem(placement: .topBarTrailing) {
      GlassButtonPair {
        GlassIconButton(amountsHidden ? .eyeSlash : .eye, label: amountsHidden ? "Show amounts" : "Hide amounts",
                        selected: amountsHidden, action: onToggleAmounts)
          .accessibilityIdentifier("header.hideAmounts")
        GlassIconButton(.magnifier, label: "Search", action: onSearch)
          .accessibilityIdentifier("header.search")
        GlassIconButton(.bell, label: Bell.label(unread),
                        badge: unread, action: onNotifications)
          .accessibilityIdentifier("header.notifications")
      }
    }
    .sharedBackgroundVisibility(.hidden)
  }
}
