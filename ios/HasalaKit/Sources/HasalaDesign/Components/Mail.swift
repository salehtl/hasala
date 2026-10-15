import HasalaModels
import SwiftUI

// Mailboxes (Paper page 15 §15.3 "Gmail or Outlook."): the mailbox row with its four states and
// the provider rows of "Choose your email". In lists and settings the thing you connect is a
// "mailbox"; in steps and buttons it is "your email" (page 07).

/// A mailbox's status chip: 24 tall, 13/16 600. Connected is green, Syncing blue with a
/// spinner, Sign in again amber, Disconnected grey. The word always says it.
public struct MailboxStatusChip: View {
  let state: MailboxState

  public init(_ state: MailboxState) {
    self.state = state
  }

  public var body: some View {
    HStack(spacing: state == .syncing ? 5 : 4) {
      if state == .syncing {
        Spinner(size: 12, tint: HColor.statusInfoForeground, track: HColor.actionAccentSubtlePressed)
      }
      Text(Self.word(state))
        .hType(HType(size: 13, leading: 16, weight: .semibold, textStyle: .footnote))
        .foregroundStyle(foreground)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.leading, state == .syncing ? 8 : 10)
    .padding(.trailing, 10)
    .frame(minHeight: 24)
    .background(surface, in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.word(state))
  }

  /// "Connected", "Syncing", "Sign in again", "Disconnected".
  public static func word(_ state: MailboxState) -> String {
    switch state {
    case .connected: "Connected"
    case .syncing: "Syncing"
    case .needsSignIn: "Sign in again"
    case .disconnected: "Disconnected"
    }
  }

  private var foreground: Color {
    switch state {
    case .connected: HColor.statusSuccessForeground
    case .syncing: HColor.statusInfoForeground
    case .needsSignIn: HColor.statusWarningForeground
    case .disconnected: HColor.textSecondary
    }
  }

  private var surface: Color {
    switch state {
    case .connected: HColor.statusSuccessSurface
    case .syncing: HColor.statusInfoSurface
    case .needsSignIn: HColor.statusWarningSurface
    case .disconnected: HColor.surfaceGrouped
    }
  }
}

/// One mailbox in Profile › Bank alerts (page 15 §15.3): the provider tile, the address on one
/// line, the provider and when it was last checked, then the status chip. A disconnected
/// mailbox fades its tile and greys its address. The address is the mailbox's, never the
/// Hasala account email. Tap opens the mailbox.
public struct MailboxRow: View {
  let mailbox: MailboxSnapshot
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ mailbox: MailboxSnapshot) {
    self.mailbox = mailbox
  }

  private var off: Bool { mailbox.state == .disconnected }

  public var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
    layout {
      ProviderMark(mailbox.provider, size: .tile40, faded: off)
      VStack(alignment: .leading, spacing: 2) {
        // One line at the default size (Paper clamps it); above it the address wraps.
        Text(mailbox.address)
          .hType(.rowTitle)
          .foregroundStyle(off ? HColor.textSecondary : HColor.textPrimary)
          .singleLineAtDefaultTextSize()
        Text(meta).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
          .fixedSize(horizontal: false, vertical: true)
        if let note = mailbox.note {
          Text(note).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      MailboxStatusChip(mailbox.state)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([mailbox.address, meta, mailbox.note].compactMap { $0 }.joined(separator: ", "))
    .accessibilityValue(MailboxStatusChip.word(mailbox.state))
  }

  /// "Gmail · Checked 4 min ago".
  private var meta: String { "\(mailbox.provider.appName) · \(mailbox.meta)" }
}

/// A provider row in "Choose your email" (page 15 §15.3): the provider tile, the mail app's
/// name ("Gmail", "Outlook"), a line of the account kinds it covers (or the connected address),
/// and a chevron. Picking it moves to the provider's read-only screen.
public struct ProviderRow: View {
  let provider: MailProviderKind
  let subtitle: String
  let action: () -> Void

  /// `subtitle` defaults to the provider's chooser line ("Any Google account").
  public init(provider: MailProviderKind, subtitle: String? = nil, action: @escaping () -> Void) {
    self.provider = provider
    self.subtitle = subtitle ?? provider.chooserSubtitle
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HListRow(leading: .provider(provider), title: provider.appName, supporting: .wrapping(subtitle),
               trailing: .chevron)
    }
    .buttonStyle(HRowPressStyle())
  }
}
