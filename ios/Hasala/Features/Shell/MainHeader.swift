import HasalaDesign
import HasalaModels
import SwiftUI

/// The main-screen header (Paper "kit Screen chrome", spec 04 §13.1): leading glass eye (Hide
/// amounts), the Hasala mark centred, and on the trailing side the bell with its
/// unread badge (Home only), "+" (Activity only) and the avatar. iOS 26 toolbar
/// items get the system Liquid Glass; nothing custom is drawn for them.
struct MainHeader: ToolbarContent {
  /// Header icons are ink, not the accent (Paper `--color-apple-labels-vibrant-primary`).
  static let iconColor = HColor.appleLabelsVibrantPrimary

  enum Extra { case bell(unread: Int), add, none }

  let amountsHidden: Bool
  let extra: Extra
  let avatarInitial: String
  let onToggleAmounts: () -> Void
  let onExtra: () -> Void
  let onProfile: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(action: onToggleAmounts) {
        Image(systemName: amountsHidden ? "eye.slash" : "eye")
          .foregroundStyle(Self.iconColor)
      }
      .accessibilityLabel(amountsHidden ? "Show amounts" : "Hide amounts")
      .accessibilityIdentifier("header.hideAmounts")
    }
    ToolbarItem(placement: .principal) {
      Image("HasalaMark")
        .resizable()
        .scaledToFit()
        .frame(width: 54, height: 32)
        .accessibilityLabel("Hasala")
    }
    switch extra {
    case .bell(let unread):
      ToolbarItem(placement: .topBarTrailing) {
        Button(action: onExtra) {
          Image(systemName: "bell")
            .foregroundStyle(Self.iconColor)
            .overlay(alignment: .topTrailing) {
              if unread > 0 {
                // Drawn here rather than with .badge(): the bar's own badge grows with
                // Dynamic Type until it covers the bell, and is the system red. Paper
                // ("Home · Default"): 20 pt, action-destructive, a 2 pt white ring, its
                // centre 15 pt right of and 17 pt above the button's. The button's label
                // carries the count for VoiceOver.
                CountBadge(unread, tone: .alert)
                  .background(Capsule().fill(HColor.white).padding(-2))
                  .dynamicTypeSize(...DynamicTypeSize.large)
                  .offset(x: 15, y: -16)
                  .accessibilityHidden(true)
              }
            }
        }
        .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
        .accessibilityIdentifier("header.notifications")
      }
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
    case .add:
      ToolbarItem(placement: .topBarTrailing) {
        Button(action: onExtra) {
          Image(systemName: "plus")
            .foregroundStyle(Self.iconColor)
        }
        .accessibilityLabel("Add a transaction")
        .accessibilityIdentifier("header.add")
      }
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
    case .none:
      ToolbarItem(placement: .topBarTrailing) { EmptyView() }
    }
    // The avatar is its own round button: without the bar's shared glass, which wraps
    // the 36 pt disc in a capsule wider than it is tall. The tap target stays 44 pt.
    ToolbarItem(placement: .topBarTrailing) {
      Button(action: onProfile) {
        AvatarDisc(initial: avatarInitial)
          .frame(width: 44, height: 44)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Your profile")
      .accessibilityIdentifier("header.profile")
    }
    .sharedBackgroundVisibility(.hidden)
  }
}
