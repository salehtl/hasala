import HasalaModels
import SwiftUI

// Lists and section headings (Paper page 15 "One row, many lists."): one row inside a white
// list card on the grey canvas. Fixed leading and trailing slots keep every row in a list on
// the same lanes. Rows never scale on press; the fill changes instead. At the accessibility
// sizes a row stacks: the leading item above, the trailing value under the supporting line.

/// A white list card, radius 24, no shadow, no padding of its own: rows fill it edge to edge
/// and its corners clip the first and last row.
public struct HListCard<Content: View>: View {
  let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    VStack(spacing: 0) { content }
      .frame(maxWidth: .infinity)
      .background(HColor.listRowSurface)
      .clipShape(RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}

/// The 1 pt divider between rows, inset to where the text starts. None above the first row
/// or after the last.
public struct HDivider: View {
  public enum Inset: Sendable {
    /// After a 40 pt disc: 16 + 40 + 12.
    case disc68
    /// After a 22 pt icon: 16 + 22 + 14.
    case icon52
    /// Text-only rows, and every row at the accessibility sizes.
    case text16
    /// A step list's dot lane: 16 + 7 + 12.
    case lane35
    /// Key–value rows inside a padded details card: spans the card's inner width.
    case none

    var value: CGFloat {
      switch self {
      case .disc68: 68
      case .icon52: 52
      case .text16: 16
      case .lane35: 35
      case .none: 0
      }
    }
  }

  let inset: Inset
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(inset: Inset = .disc68) {
    self.inset = inset
  }

  public var body: some View {
    HColor.listRowSeparator
      .frame(height: 1)
      .padding(.leading, typeSize.isAccessibilitySize && inset != .none ? 16 : inset.value)
      .accessibilityHidden(true)
  }
}

/// One list row: a leading slot, the title over an optional supporting line, a trailing slot
/// (page 15 §01). Title 16/22 600, supporting 13/18 secondary; two-line rows are at least 64
/// tall with a 40 disc, one-line rows 52. VoiceOver reads the row as one sentence: title,
/// supporting facts, then the trailing value (an amount as money).
public struct HListRow: View {
  public enum Leading {
    /// A 40 category disc.
    case disc(Hue, HIcon)
    /// A 40 grey monogram for a merchant with no category.
    case monogram(String)
    /// A 40 bank plate.
    case plate(initials: String, hue: Hue)
    /// A 40 provider tile (mailboxes, Choose your email).
    case provider(MailProviderKind)
    /// A 22 line icon (settings and actions); the gap to the text is 14.
    case icon22(HIcon, color: Color = HColor.listRowIcon)
    case none
  }

  /// The second line: facts joined by " · ", or a status in its tone.
  public enum Supporting: ExpressibleByStringLiteral {
    /// One line at the default size; above it, it wraps.
    case text(String)
    /// A longer line that wraps at every size (a status
    /// sentence, a provider's account kinds).
    case wrapping(String)
    /// A figure-bearing line that Hide amounts reaches ("Japan trip · 7,140.00 left").
    case phrase(MoneyPhrase)
    /// A 7 dot and words in the tone ("To review · 18:42", "Expected the 7th").
    case status(String, StatusTone)

    public init(stringLiteral value: String) { self = .text(value) }
  }

  public enum Trailing {
    /// An amount: 16/22 bold, tabular, no currency; money in gets "+" and green.
    case amount(Money, in: Bool = false)
    /// A value in 15/20 secondary ("AED", "Important only").
    case value(String)
    /// A chevron: a tap goes somewhere.
    case chevron
    /// A value then a chevron.
    case valueChevron(String)
    /// The iOS switch, tinted accent; the whole row flips it.
    case `switch`(Binding<Bool>)
    /// A tick in a fixed 24 slot (pick one); empty when not selected.
    case check(Bool)
    /// A count in the 22 row badge, then a chevron.
    case badge(Int)
    /// A status pill (a mailbox state, "Price change").
    case status(StatusPill)
    case none
  }

  let leading: Leading
  let title: String
  let titleColor: Color
  let supporting: Supporting?
  let trailing: Trailing
  let hidden: Bool
  let project: String?
  @Environment(\.dynamicTypeSize) private var typeSize

  /// `titleColor` is `listRowAction` for an action row ("Add a rule") and `listRowDestructive`
  /// for a destructive one ("Archive", in its own card, last).
  public init(leading: Leading = .none, title: String, supporting: Supporting? = nil, trailing: Trailing = .none,
              titleColor: Color = HColor.listRowTitle, hidden: Bool = false, project: String? = nil)
  {
    self.project = project
    self.leading = leading
    self.title = title
    self.supporting = supporting
    self.trailing = trailing
    self.titleColor = titleColor
    self.hidden = hidden
  }

  private var isIconRow: Bool {
    if case .icon22 = leading { return true }
    return false
  }

  private var hasLeading: Bool {
    if case .none = leading { return false }
    return true
  }

  public var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          if hasLeading { leadingView }
          text
          trailingView
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: isIconRow ? 14 : HSpacing.listRowGap) {
          if hasLeading { leadingView }
          text.frame(maxWidth: .infinity, alignment: .leading)
          trailingView
        }
        .padding(.vertical, isIconRow ? 0 : HSpacing.listRowInsetBlock)
        .frame(minHeight: supporting == nil ? HSpacing.listRowMinHeight : HSpacing.listRowMinHeightTwoLine)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .contentShape(Rectangle())
    .modifier(RowAccessibility(isSwitch: isSwitch, label: spokenLabel, value: spokenValue))
  }

  private var isSwitch: Bool {
    if case .switch = trailing { return true }
    return false
  }

  @ViewBuilder private var leadingView: some View {
    switch leading {
    case .disc(let hue, let icon): CategoryDisc(hue: hue, icon: icon)
    case .monogram(let letter): MonogramDisc(letter)
    case .plate(let initials, let hue): BankPlate(initials: initials, hue: hue)
    case .provider(let p): ProviderMark(p)
    case .icon22(let icon, let color): HIconView(icon, size: HSpacing.iconGlass, color: color, strokeWidth: 1.8)
    case .none: EmptyView()
    }
  }

  private var text: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).hType(.rowTitle).foregroundStyle(titleColor).singleLineAtDefaultTextSize()
      if let supporting {
        if let project {
          ProjectChipFlow(project) { SupportingLine(supporting, hidden: hidden) }
        } else {
          SupportingLine(supporting, hidden: hidden)
        }
      } else if let project {
        ProjectChip(project)
      }
    }
  }

  @ViewBuilder private var trailingView: some View {
    switch trailing {
    case .amount(let money, let isIn):
      MoneyText(money, figure: .row, hidden: hidden, hiddenGlyphs: 3, color: isIn ? HColor.moneyIn : HColor.moneyOut,
                sign: isIn ? .income : .none)
        .fixedSize()
    case .value(let v):
      Text(v).hType(.subheadline).foregroundStyle(HColor.listRowSupporting)
    case .chevron:
      HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
    case .valueChevron(let v):
      HStack(spacing: 8) {
        Text(v).hType(.subheadline).foregroundStyle(HColor.listRowSupporting)
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    case .switch(let isOn):
      Toggle("", isOn: isOn).labelsHidden().tint(HColor.controlSwitchTrackOn)
    case .check(let on):
      ZStack { if on { HIconView(.check, size: 22, color: HColor.listRowCheck) } }.frame(width: 24, height: 24)
    case .badge(let n):
      HStack(spacing: 12) {
        CountBadge(n, style: .row22)
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    case .status(let pill):
      StatusPillView(pill, size: .s22, surface: .tinted)
    case .none:
      EmptyView()
    }
  }

  private var spokenLabel: String {
    var parts = [title]
    if let supporting { parts.append(supporting.spoken(hidden: hidden)) }
    if let project { parts.append(ProjectChip.spoken(project)) }
    return parts.joined(separator: ", ")
  }

  private var spokenValue: String {
    switch trailing {
    case .amount(let m, let isIn):
      hidden ? "Amount hidden" : (isIn ? "plus " : "") + "\(m.currency) \(MoneyFormat.string(m.minor))"
    case .value(let v), .valueChevron(let v): v
    case .badge(let n): n > 0 ? "\(n) new" : ""
    case .status(let pill): pill.text
    case .check(let on): on ? "Selected" : ""
    case .switch, .chevron, .none: ""
    }
  }
}

/// One VoiceOver stop per row; a switch row keeps the switch as the element, so the row title
/// labels it and a double-tap flips it.
struct RowAccessibility: ViewModifier {
  let isSwitch: Bool
  let label: String
  let value: String

  func body(content: Content) -> some View {
    if isSwitch {
      content.accessibilityElement(children: .combine).accessibilityLabel(label)
    } else {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
  }
}

/// A row's second line (page 15): facts in 13/18 secondary, or a status: a 7 dot and words
/// 13/18 600 in the tone.
struct SupportingLine: View {
  let line: HListRow.Supporting
  let hidden: Bool

  init(_ line: HListRow.Supporting, hidden: Bool) {
    self.line = line
    self.hidden = hidden
  }

  var body: some View {
    switch line {
    case .text(let s):
      Text(s).hType(.footnote).foregroundStyle(HColor.listRowSupporting).singleLineAtDefaultTextSize()
    case .wrapping(let s):
      Text(s).hType(.footnote).foregroundStyle(HColor.listRowSupporting).fixedSize(horizontal: false, vertical: true)
    case .phrase(let p):
      Text(p.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        .singleLineAtDefaultTextSize()
    case .status(let s, let tone):
      HStack(spacing: 6) {
        Circle().fill(tone.foreground).frame(width: 7, height: 7)
        Text(s).hType(.footnote.weight(.semibold)).foregroundStyle(tone.foreground).singleLineAtDefaultTextSize()
      }
    }
  }
}

extension HListRow.Supporting {
  func spoken(hidden: Bool) -> String {
    switch self {
    case .text(let s), .wrapping(let s), .status(let s, _): s
    case .phrase(let p): p.spoken(hidden: hidden)
    }
  }
}

/// A key–value detail row (page 15 · details card, page 11 · value rows): the key in 15/20
/// secondary on the left, the value 15/20 600 on the right, at least 48 tall. A chevron means it
/// opens a picker or editor; a bucket dot may lead the value ("● Groceries").
public struct KeyValueRow: View {
  let key: String
  let value: String
  let dot: Hue?
  let chevron: Bool
  let placeholder: Bool

  /// `placeholder` draws the value in secondary ("Add a note").
  public init(_ key: String, value: String, dot: Hue? = nil, chevron: Bool = false, placeholder: Bool = false) {
    self.key = key
    self.value = value
    self.dot = dot
    self.chevron = chevron
    self.placeholder = placeholder
  }

  public var body: some View {
    ReflowingRow(spacing: 12) {
      Text(key).hType(.subheadline).foregroundStyle(HColor.listRowSupporting)
    } trailing: {
      HStack(spacing: 8) {
        if let dot { Circle().fill(dot.dotGradient).frame(width: 8, height: 8) }
        Text(value)
          .hType(placeholder ? .subheadline : .subheadline.weight(.semibold))
          .foregroundStyle(placeholder ? HColor.listRowSupporting : HColor.listRowTitle)
        if chevron {
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
        } else {
          // The chevron's lane stays, so values line up down the card.
          Color.clear.frame(width: HSpacing.iconSmall, height: HSpacing.iconSmall)
        }
      }
    }
    .frame(minHeight: HSpacing.listRowMinHeightKeyValue)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(key)
    .accessibilityValue(value)
  }
}

/// A settings row (page 15 · one-line rows, page 12 · switch): a 22 icon at 1.8, the title,
/// then a value and chevron, a chevron alone, or a switch. Min 52, 14 from icon to text.
public struct SettingsRow: View {
  public enum Accessory {
    case chevron
    case value(String)
    case `switch`(Binding<Bool>)
    case none
  }

  public enum Role: Sendable {
    case standard
    /// An accent row ("Add a rule"): icon and title in `listRowAction`, no chevron.
    case action
    /// A destructive row ("Archive"): icon and title in `listRowDestructive`.
    case destructive
  }

  let icon: HIcon?
  let title: String
  let accessory: Accessory
  let role: Role

  public init(icon: HIcon?, title: String, accessory: Accessory = .chevron, role: Role = .standard) {
    self.icon = icon
    self.title = title
    self.accessory = accessory
    self.role = role
  }

  public var body: some View {
    HListRow(leading: icon.map { .icon22($0, color: tint) } ?? .none, title: title, trailing: trailing,
             titleColor: role == .standard ? HColor.listRowTitle : tint)
  }

  private var tint: Color {
    switch role {
    case .standard: HColor.listRowIcon
    case .action: HColor.listRowAction
    case .destructive: HColor.listRowDestructive
    }
  }

  private var trailing: HListRow.Trailing {
    switch accessory {
    case .chevron: .chevron
    case .value(let v): .valueChevron(v)
    case .switch(let b): .switch(b)
    case .none: .none
    }
  }
}

/// A screen's section heading (page 15 §02): 22/28 bold, −0.35, 12 above its card. A trailing
/// link ("See all", "Edit") in 15/20 medium blue on the same baseline, or a quiet fact ("next
/// 7 days"), or an ink count badge. An optional line under the title says what waits.
public struct HSectionHeader: View {
  public enum Trailing {
    case link(String, action: () -> Void)
    case fact(String)
    case count(Int)
    case none
  }

  let title: String
  let subtitle: String?
  let trailing: Trailing

  public init(_ title: String, subtitle: String? = nil, trailing: Trailing = .none) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
  }

  public var body: some View {
    ReflowingRow(alignment: subtitle == nil ? .firstTextBaseline : .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(title).hType(.section).foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          if case .count(let n) = trailing {
            CountBadge(n, style: .title24)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(countLabel)
        if let subtitle {
          Text(subtitle).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
      }
    } trailing: {
      switch trailing {
      case .link(let label, let action):
        Button(label, action: action)
          .buttonStyle(.plain)
          .hType(.subheadline.weight(.medium))
          .foregroundStyle(HColor.textLink)
          .frame(minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
      case .fact(let fact):
        Text(fact).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      case .count, .none:
        EmptyView()
      }
    }
  }

  private var countLabel: String {
    if case .count(let n) = trailing, n > 0 { return "\(title), \(n)" }
    return title
  }
}

/// A day or group overline just inside a card's edge (page 15 §02): 13/16 600, 0.06 em,
/// uppercase in styling, `--color-text-grouped-header`, inset 4. Day groups add the day's total
/// on the right.
public struct OverlineHeader<Trailing: View>: View {
  let title: String
  let trailing: Trailing

  public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.trailing = trailing()
  }

  public var body: some View {
    ReflowingRow(alignment: .firstTextBaseline) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader).accessibilityAddTraits(.isHeader)
    } trailing: {
      trailing
    }
    .padding(.leading, 4)
    .padding(.trailing, 4)
    .padding(.top, 2)
  }
}

public extension OverlineHeader where Trailing == EmptyView {
  init(_ title: String) {
    self.init(title) { EmptyView() }
  }
}

/// A transaction row (page 15 §02, Activity · Overview): a 40 category disc, or a grey monogram
/// for a merchant not sorted yet; the merchant 16/22 600 over "Dining · 13:20"; the amount in
/// the trailing slot, 16/22 bold tabular. A row to review leads its line with an accent dot and
/// the words in accent. At the accessibility sizes the amount moves under the line. Min 64.
public struct TransactionRow: View {
  let row: MiniTxnRow
  let hidden: Bool

  static func tone(_ reason: TxnReviewReason?) -> StatusTone {
    switch reason {
    case .senderUnverified: .warning
    case .probableCopy, .samePurchase: .accent
    case nil: .accent
    }
  }

  public init(_ row: MiniTxnRow, hidden: Bool) {
    self.row = row
    self.hidden = hidden
  }

  public var body: some View {
    HListRow(
      leading: row.monogram.map { .monogram($0) } ?? .disc(row.hue, row.glyph.icon),
      title: row.merchant,
      supporting: row.toReview ? .status(row.detail, Self.tone(row.reviewReason)) : .text(row.detail),
      trailing: .amount(row.amount, in: row.isIncome),
      hidden: hidden,
      project: row.project?.name)
  }
}

public struct ProjectChip: View {
  let name: String
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 20

  public init(_ name: String) {
    self.name = name
  }

  public static func spoken(_ name: String) -> String { "\(name) project" }

  public var body: some View {
    let large = typeSize.isAccessibilitySize
    HStack(spacing: large ? 8 : 4) {
      HIconView(.project, size: large ? 26 : 12, color: HColor.huePeachInk, strokeWidth: large ? 2 : 2.4)
      Text(name).hType(.caption1).foregroundStyle(HColor.huePeachInk)
        .lineLimit(large ? nil : 1).truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: large)
    }
    .padding(.leading, large ? 10 : 5)
    .padding(.trailing, large ? 16 : 8)
    .padding(.vertical, large ? 4 : 0)
    .frame(minHeight: large ? nil : height)
    .background(HColor.bucketProjectStart, in: Capsule())
    .frame(maxWidth: large ? nil : 140, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.spoken(name))
  }
}

public struct ProjectChipFlow<Detail: View>: View {
  let project: String
  let detail: Detail
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ project: String, @ViewBuilder detail: () -> Detail) {
    self.project = project
    self.detail = detail()
  }

  public var body: some View {
    if typeSize.isAccessibilitySize {
      stacked(spacing: 8)
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 6) {
          detail
          ProjectChip(project)
        }
        stacked(spacing: 4)
      }
    }
  }

  private func stacked(spacing: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: spacing) {
      detail
      ProjectChip(project)
    }
  }
}

/// A bill or income line (Activity · Coming up, Bills · Upcoming and Recently paid; page 16
/// §12): disc, name, the due line, then the amount, with "~" for an expected amount and "+"
/// in green for income. A late bill's line is a red dot and words ("Expected the 7th").
public struct BillRowView: View {
  let row: BillRowModel
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ row: BillRowModel, hidden: Bool) {
    self.row = row
    self.hidden = hidden
  }

  public var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
    layout {
      CategoryDisc(hue: row.hue, glyph: row.glyph)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle).singleLineAtDefaultTextSize()
        DetailParts(parts: row.detail, hidden: hidden)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
        HStack(spacing: 0) {
          if row.approximate && !hidden {
            Text(verbatim: "~").hFigure(.row).foregroundStyle(HColor.moneyOut)
          }
          MoneyText(row.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                    color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
        }
        if let note = row.trailingNote { DetailParts(parts: [note], hidden: hidden) }
      }
      .fixedSize()
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var spoken: String {
    let amount = hidden
      ? "Amount hidden"
      : (row.approximate ? "about " : "") + (row.isIncome ? "plus " : "")
        + "\(row.amount.currency) \(MoneyFormat.string(row.amount.minor))"
    return ([row.name, DetailParts.spoken(row.detail, hidden: hidden), amount]
      + (row.trailingNote.map { [DetailParts.spoken([$0], hidden: hidden)] } ?? []))
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }
}

/// A line of `PlanDetailPart`s joined with " · ": figures through `MoneyPhrase`, so Hide
/// amounts reaches them; a status part draws a 7 dot and words 600 in its tone.
struct DetailParts: View {
  let parts: [PlanDetailPart]
  let hidden: Bool

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
        if index > 0 {
          Text(verbatim: " · ").hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        }
        switch part {
        case .text(let p):
          Text(p.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        case .status(let words, let tone):
          HStack(spacing: 6) {
            Circle().fill(tone.foreground).frame(width: 7, height: 7)
            Text(words).hType(.footnote.weight(.semibold)).foregroundStyle(tone.foreground)
          }
        }
      }
    }
    .lineLimitAtDefaultTextSize(1)
  }

  static func spoken(_ parts: [PlanDetailPart], hidden: Bool) -> String {
    parts.map { part in
      switch part {
      case .text(let p): p.spoken(hidden: hidden)
      case .status(let words, _): words
      }
    }.joined(separator: ", ")
  }
}

/// A row with a leading and a trailing part. It stays one line while both fit at their
/// natural width; otherwise, and always at the accessibility text sizes, the trailing
/// part moves under the leading one instead of either truncating (spec 04 §17).
public struct ReflowingRow<Leading: View, Trailing: View>: View {
  let spacing: CGFloat
  let alignment: VerticalAlignment
  let leading: Leading
  let trailing: Trailing
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(
    spacing: CGFloat = 8, alignment: VerticalAlignment = .center, @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.spacing = spacing
    self.alignment = alignment
    self.leading = leading()
    self.trailing = trailing()
  }

  public var body: some View {
    if typeSize.isAccessibilitySize {
      stacked
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: alignment, spacing: 0) {
          leading
          Spacer(minLength: spacing)
          trailing
        }
        stacked
      }
    }
  }

  private var stacked: some View {
    VStack(alignment: .leading, spacing: 4) {
      leading
      trailing
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

