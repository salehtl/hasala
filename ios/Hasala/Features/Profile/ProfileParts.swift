import HasalaDesign
import HasalaModels
import SwiftUI

// The parts of Your profile (Paper "Profile · Your profile (sheet)" 5DE-0 and its page-14
// variant HI3-0): the identity block, the bank alerts status card, the two-line "Your money"
// rows and the one-line settings rows, in white list cards with their dividers.

extension EnvironmentValues {
  /// The view is inside the profile sheet's stack: it pushes onto `router.profile` and leaves
  /// the toast to the sheet's own host. Off in a tab's stack.
  @Entry var inProfileSheet = false
}

/// The 96 avatar with its white ring, the name, and the email chip (Paper "Identity").
struct ProfileIdentity: View {
  let name: String
  let initial: String
  var email: String?
  /// "maya@example.com · Verified".
  let emailLine: String

  var body: some View {
    VStack(spacing: 10) {
      AvatarDisc(initial: initial, size: 96, ring: true, email: email)
        // The monogram is the name's first letter: drawn, not read (the name follows).
        .accessibilityHidden(true)
      VStack(spacing: 8) {
        Text(name)
          .hType(.section)
          .foregroundStyle(HColor.textPrimary)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("profile.name")
        HStack(spacing: 6) {
          Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7)
          Text(emailLine)
            .hType(.footnote.weight(.semibold))
            .foregroundStyle(HColor.statusSuccessForeground)
            .multilineTextAlignment(.center)
            .singleLineAtDefaultTextSize()
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 28)
        .background(HColor.statusSuccessSurface, in: Capsule())
        .accessibilityElement(children: .combine)
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 4)
  }
}

/// "Bank alerts are working ›": the status card (radius 20, Paper's one exception to 24) in
/// the summary's hue, a 40 glyph disc, the title in the hue's ink over the facts, and the
/// chevron. The whole card opens Profile › Bank alerts.
struct BankAlertsCard: View {
  let summary: MailboxesSummary
  let action: () -> Void

  private var lines: [String] { summary.detail.split(separator: "\n").map(String.init) }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous)
    Button(action: action) {
      HStack(spacing: 12) {
        Circle()
          .fill(HColor.posterGlyph)
          .frame(width: 40, height: 40)
          .overlay {
            if summary.needsYou {
              HIconView(.envelope, size: 20, color: summary.hue.ink)
            } else {
              HIconView(.check, size: 20, color: summary.hue.ink, strokeWidth: 2.4)
            }
          }
        VStack(alignment: .leading, spacing: 2) {
          Text(summary.title).hType(.rowTitle).foregroundStyle(summary.hue.ink)
          // One Text per line ("Last email 4 min ago", "Emirates NBD and DIB"), so each wraps
          // on its own at the accessibility sizes.
          ForEach(lines, id: \.self) { line in
            Text(line).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: summary.hue.ink)
      }
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
      .background(summary.hue.perceptualGradient, in: shape)
    }
    .buttonStyle(HPressStyle(in: shape))
    // One stop: "Bank alerts are working. Last email 4 min ago. Emirates NBD and DIB."
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(([summary.title] + lines).joined(separator: ". "))
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("profile.bankAlerts")
  }
}

/// A white list card (r24) with a divider between its rows, inset to where the text starts:
/// 68 after a 40 plate (Your money, rules), 52 after a 22 icon (Settings).
struct ProfileListCard<Content: View>: View {
  let inset: HDivider.Inset
  @ViewBuilder let content: Content

  var body: some View {
    HListCard {
      Group(subviews: content) { rows in
        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
          if i > 0 { HDivider(inset: inset) }
          row
        }
      }
    }
  }
}

/// A 40 hue plate: round for a category (a disc), rounded square (radius 12) for a bank.
struct HuePlate: View {
  let hue: Hue
  let icon: HIcon
  var square = false

  var body: some View {
    RoundedRectangle(cornerRadius: square ? 12 : 20, style: .continuous)
      .fill(hue.perceptualGradient)
      .frame(width: 40, height: 40)
      .overlay { HIconView(icon, size: 20, color: hue.ink) }
      .accessibilityHidden(true)
  }
}

/// A "Your money" row (page 15 · two-line row): the plate, the title over its facts, a red
/// count badge when something waits, and the chevron. Min 64, padding 10/16. At the
/// accessibility sizes the plate goes above the words.
struct MoneyThingRow: View {
  let plate: HuePlate
  let title: String
  let detail: MoneyPhrase
  let hidden: Bool
  var badge = 0
  /// What the badge says to VoiceOver ("1 item needs a look").
  var badgeSpoken: String?
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            plate
            words
            if badge > 0 { CountBadge(badge, style: .row22) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          chevron
        }
        .padding(.vertical, 14)
      } else {
        HStack(spacing: HSpacing.listRowGap) {
          plate
          words.frame(maxWidth: .infinity, alignment: .leading)
          if badge > 0 { CountBadge(badge, style: .row22) }
          chevron
        }
        .padding(.vertical, HSpacing.listRowInsetBlock)
        .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(detail.spoken(hidden: hidden))")
    .accessibilityValue(badge > 0 ? (badgeSpoken ?? "\(badge)") : "")
  }

  private var words: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle).singleLineAtDefaultTextSize()
      Text(detail.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        .singleLineAtDefaultTextSize()
    }
  }

  private var chevron: some View {
    HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
  }
}

/// A settings row (page 15 · one-line row): a 22 line icon at 1.8, the title, then a value
/// in words ("AED", "Important only"), a status with its dot ("● Protected") or nothing, and
/// a chevron when a tap goes somewhere. Min 52, 14 from icon to text. The title is the row's
/// name, so it is never cut: when it and a longer value can't share the line ("Sign-in &
/// security" beside "● Password only"), the value goes under the title (the two-line row,
/// min 64), as it does at the accessibility sizes.
struct SettingRow: View {
  enum Trailing {
    case none
    /// A value in words; `spoken` when the drawn words aren't speech ("← Want · Need →").
    case value(String, spoken: String? = nil)
    /// A dot in the tone, then the words in secondary ("● Protected").
    case status(String, StatusTone)
  }

  let icon: HIcon
  let title: String
  var trailing: Trailing = .none
  var chevron = true
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
              iconView
              Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            }
            trailingView
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if chevron { chevronView }
        }
        .padding(.vertical, 14)
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 14) {
            iconView
            Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
              .singleLineAtDefaultTextSize()
              .frame(maxWidth: .infinity, alignment: .leading)
            trailingView
            if chevron { chevronView }
          }
          .frame(minHeight: HSpacing.listRowMinHeight)
          HStack(spacing: 14) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
              Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
                .fixedSize(horizontal: false, vertical: true)
              trailingView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron { chevronView }
          }
          .padding(.vertical, 10)
          .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
        }
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(spokenValue)
  }

  private var iconView: some View {
    HIconView(icon, size: HSpacing.iconGlass, color: HColor.listRowIcon, strokeWidth: 1.8)
  }

  @ViewBuilder private var trailingView: some View {
    switch trailing {
    case .none:
      EmptyView()
    case .value(let words, _):
      Text(words).hType(.subheadline).foregroundStyle(HColor.listRowSupporting).fixedSize()
    case .status(let words, let tone):
      HStack(spacing: 6) {
        Circle().fill(tone.foreground).frame(width: 7, height: 7)
        Text(words).hType(.subheadline).foregroundStyle(HColor.listRowSupporting)
      }
      .fixedSize()
    }
  }

  private var chevronView: some View {
    HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
  }

  private var spokenValue: String {
    switch trailing {
    case .none: ""
    case .value(let words, let spoken): spoken ?? words
    case .status(let words, _): words
    }
  }
}

/// A settings row with a switch where the chevron would be (page 15: "A row has a switch or
/// a chevron, never both"). The whole row is one stop that flips it; the title labels it.
struct SettingSwitchRow: View {
  let icon: HIcon
  let title: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) {
      HStack(spacing: 14) {
        HIconView(icon, size: HSpacing.iconGlass, color: HColor.listRowIcon, strokeWidth: 1.8)
        Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
      }
    }
    .tint(HColor.controlSwitchTrackOn)
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .frame(minHeight: HSpacing.listRowMinHeight)
  }
}
