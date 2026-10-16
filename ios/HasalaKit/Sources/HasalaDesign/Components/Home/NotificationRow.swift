import HasalaModels
import SwiftUI

/// A row of the Notifications sheet (Paper "Home · Notifications" 11Y9-0, page 15 §15.2): "A
/// list row with a when-label." A 40 disc in the item's hue (or the neutral grey plate), the
/// title 16/22 600, one supporting line 13/18 secondary (after a 7 status dot when it has one),
/// and the when-label 13/18 with a 16 chevron, top-aligned. At least 64 tall, padding 12/16,
/// gap 12; the divider between rows is inset 68.
///
/// One VoiceOver stop: title, line, then when, in words ("AXA Insurance may be late, Usually
/// on the 7th, no email yet, Thursday", page 15 §15.2). At the accessibility sizes the disc
/// sits above the words and the when-label under them.
public struct NotificationRow: View {
  let item: NotificationItem
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ item: NotificationItem, hidden: Bool) {
    self.item = item
    self.hidden = hidden
  }

  public var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          disc
          words
          trailing
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        // The disc is centred on the row; the when-label sits on the title's baseline, at the
        // top however far the line wraps (Paper: trailing `align-self: start`, 2 down).
        HStack(alignment: .center, spacing: HSpacing.listRowGap) {
          disc
          HStack(alignment: .firstTextBaseline, spacing: HSpacing.listRowGap) {
            words.frame(maxWidth: .infinity, alignment: .leading)
            trailing
          }
        }
        // 12 above and below (a list row's own is 10): Paper's notification rows breathe more.
        .padding(.vertical, 12)
        .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  @ViewBuilder private var disc: some View {
    switch item.disc {
    case .hue(let hue, let glyph):
      CategoryDisc(hue: hue, glyph: glyph)
    case .neutral(let glyph):
      Circle()
        .fill(HColor.surfaceSecondary)
        .overlay { Circle().strokeBorder(HColor.borderSubtle, lineWidth: 1) }
        .frame(width: HSpacing.listRowLeadingDisc, height: HSpacing.listRowLeadingDisc)
        .overlay { HIconView(glyph.icon, size: 20, color: HColor.iconPrimary) }
        .accessibilityHidden(true)
    }
  }

  private var words: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(item.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        .fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 6) {
        if let status = item.status {
          Circle().fill(status.foreground).frame(width: 7, height: 7).frame(height: dotLane)
        }
        Text(item.line.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var trailing: some View {
    HStack(spacing: 6) {
      if let when = item.when {
        Text(when).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
      }
      HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
    }
  }

  @ScaledMetric(relativeTo: .footnote) private var dotLane: CGFloat = 18

  private var spoken: String {
    [item.title, item.line.spoken(hidden: hidden).replacingOccurrences(of: " · ", with: ", "),
     item.when.map(Self.spokenWhen)].compactMap { $0 }.joined(separator: ", ")
  }

  /// "Thu" reads "Thursday" and "28 Sep" "28 September"; "Today" and "9:12" stay.
  nonisolated static func spokenWhen(_ when: String) -> String {
    let words = when.split(separator: " ").map { Self.fullNames[String($0)] ?? String($0) }
    return words.joined(separator: " ")
  }

  private nonisolated static let fullNames: [String: String] = [
    "Mon": "Monday", "Tue": "Tuesday", "Wed": "Wednesday", "Thu": "Thursday", "Fri": "Friday",
    "Sat": "Saturday", "Sun": "Sunday", "Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April",
    "Jun": "June", "Jul": "July", "Aug": "August", "Sep": "September", "Oct": "October", "Nov": "November",
    "Dec": "December",
  ]
}

/// The all-clear state of the sheet (Paper 12AC-0): a 56 success disc with a 26 check, "Nothing
/// needs you" 20/25 600, "We'll tell you when something does." 15/20 secondary, centred.
public struct NothingNeedsYou: View {
  public init() {}

  public var body: some View {
    VStack(spacing: 12) {
      Circle().fill(HColor.statusSuccessSurface).frame(width: 56, height: 56)
        .overlay { HIconView(.check, size: 26, color: HColor.statusSuccessForeground, strokeWidth: 2.2) }
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text("Nothing needs you").hType(.title3).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text("We'll tell you when something does.").hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
      .multilineTextAlignment(.center)
    }
    .padding(.top, 28)
    .padding(.horizontal, 24)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}
