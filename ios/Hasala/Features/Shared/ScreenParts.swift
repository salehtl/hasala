import HasalaDesign
import HasalaModels
import SwiftUI

// Parts the core screens share (Paper "kit Lists and cards", "Template · Sheet (large)";
// the tab screen template is `TabScreen`). They read amounts only through MoneyText and
// MoneyPhrase, so Hide amounts reaches every figure (spec 04 §12).

/// A line of copy that may carry amounts; hidden figures become bullets and read
/// "Amount hidden".
struct PhraseText: View {
  let phrase: MoneyPhrase
  let hidden: Bool

  init(_ phrase: MoneyPhrase, hidden: Bool) {
    self.phrase = phrase
    self.hidden = hidden
  }

  var body: some View {
    Text(phrase.rendered(hidden: hidden))
      .accessibilityLabel(phrase.spoken(hidden: hidden))
  }
}

/// A row's second line built from parts joined with " · "; a status part draws a
/// coloured dot and its words in the tone ("● Over pace").
struct DetailLine: View {
  let parts: [PlanDetailPart]
  let hidden: Bool

  var body: some View {
    text
      .hType(.footnote)
      .accessibilityLabel(spoken)
  }

  private var text: Text {
    var out = Text(verbatim: "")
    for (i, part) in parts.enumerated() {
      if i > 0 { out = Text("\(out)\(Text(verbatim: " · ").foregroundStyle(HColor.listRowSupporting))") }
      switch part {
      case .text(let p):
        out = Text("\(out)\(Text(verbatim: p.rendered(hidden: hidden)).foregroundStyle(HColor.listRowSupporting))")
      case .status(let words, let tone):
        let status = Text(verbatim: "● \(words)").foregroundStyle(tone.foreground)
        out = Text("\(out)\(status)")
      }
    }
    return out
  }

  private var spoken: String {
    parts.map { part in
      switch part {
      case .text(let p): p.spoken(hidden: hidden)
      case .status(let words, _): words
      }
    }.joined(separator: ", ")
  }
}

/// A white list card (r24) whose rows are separated by hairlines inset 68 pt.
struct ListCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
          if i > 0 {
            Rectangle().fill(HColor.listRowSeparator).frame(height: 0.5)
              .padding(.leading, HSpacing.listRowInsetInline + HSpacing.listRowLeadingDisc + HSpacing.listRowGap)
          }
          row
        }
      }
    }
    .listCard()
  }
}

/// "Coming up ……… next 7 days": a section title with a quiet trailing note or a link.
struct SectionTitle: View {
  let title: String
  var note: String?
  var count: Int?
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      HStack(spacing: 8) {
        Text(title).hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
        if let count { CountBadge(count).accessibilityLabel("\(count) items") }
      }
      Spacer(minLength: 8)
      if let actionTitle {
        Button(actionTitle) { action?() }
          .buttonStyle(.plain)
          .hType(.body.weight(.medium))
          .foregroundStyle(HColor.textLink)
      } else if let note {
        Text(note).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
    }
  }
}

/// "TODAY ……… 91.50": a day's overline with its total. At the accessibility sizes the total
/// goes under the day, so the day never has to squeeze beside it (spec 04 §17).
struct DayOverline: View {
  let title: String
  let total: Money
  let hidden: Bool

  var body: some View {
    ReflowingRow {
      Text(title).hType(.overline).foregroundStyle(HColor.textSecondary).accessibilityAddTraits(.isHeader)
        .fixedSize(horizontal: false, vertical: true)
    } trailing: {
      MoneyText(total, figure: .badge, hidden: hidden, hiddenGlyphs: 3, color: HColor.textSecondary,
                sign: total.isNegative ? .income : .none)
    }
    .padding(.horizontal, 4)
    // One heading per day, not a small static figure on its own.
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// A two-line navigation row: disc, title over detail, trailing value and chevron. A row
/// that opens nothing (yet) leaves the chevron out, so it doesn't look tappable.
struct NavRow<Leading: View, Trailing: View>: View {
  let title: String
  var detail: String?
  var chevron = true
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: HSpacing.listRowGap) {
      leading
      VStack(alignment: .leading, spacing: 0) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        if let detail { Text(detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting) }
      }
      Spacer(minLength: 8)
      trailing
      if chevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(HColor.listRowChevron)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .frame(minHeight: detail == nil ? HSpacing.listRowMinHeight : HSpacing.listRowMinHeightTwoLine)
    .contentShape(Rectangle())
  }
}

extension NavRow where Trailing == EmptyView {
  init(title: String, detail: String? = nil, chevron: Bool = true, @ViewBuilder leading: () -> Leading) {
    self.title = title
    self.detail = detail
    self.chevron = chevron
    self.leading = leading()
    self.trailing = EmptyView()
  }
}

/// A settings row icon: a line glyph in a fixed 24 pt lane.
struct RowIcon: View {
  let systemName: String
  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 17, weight: .regular))
      .foregroundStyle(HColor.listRowIcon)
      .frame(width: HSpacing.listRowLeadingIcon)
      .accessibilityHidden(true)
  }
}

/// The close button of a large sheet (Paper "Template · Sheet (large)": × top left).
struct SheetCloseButton: ToolbarContent {
  let identifier: String
  let action: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(role: .close, action: action)
        .accessibilityIdentifier(identifier)
    }
  }
}

/// The month pill under a large title ("October 2026 ⌄").
// TODO(spec 04 §16.2 P1): it opens the month picker; one month is shown for now, so a
// Release build drops the "⌄" that would promise a picker.
struct MonthPill: View {
  let month: YearMonth

  var body: some View {
    HStack(spacing: 4) {
      Text(month.title).hType(.subheadline.weight(.semibold))
      if BuildSurface.showsUnfinished {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).accessibilityHidden(true)
      }
    }
    .foregroundStyle(HColor.textPrimary)
    .padding(.horizontal, 14)
    .frame(minHeight: 36)
    .background(HColor.surfacePrimary, in: Capsule())
    .shadow(color: HColor.elevationNear, radius: 1, x: 0, y: 1)
    .accessibilityElement(children: .combine)
  }
}

/// A content-free empty state: one sentence and, optionally, one action (spec 04 §16.3).
struct EmptyNote: View {
  let systemImage: String
  let message: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage).foregroundStyle(HColor.iconSecondary).accessibilityHidden(true)
      Text(message).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      Spacer(minLength: 0)
    }
    .padding(HSpacing.md)
    .listCard()
  }
}

extension Bucket {
  /// "Needs", "Wants", "Savings".
  var label: String {
    switch self {
    case .needs: "Needs"
    case .wants: "Wants"
    case .savings: "Savings"
    case .income: "Income"
    case .project: "Projects"
    case .other: "Not spending"
    }
  }
}

extension View {
  /// Keeps `pulled` at how far a pull has dragged a scroll view's content below its top
  /// (0 when it isn't overscrolled). A screen's wash is offset by it, so pulling down,
  /// to refresh or not, moves the content and leaves the wash where it is.
  func trackingOverscroll(_ pulled: Binding<CGFloat>) -> some View {
    onScrollGeometryChange(for: CGFloat.self) { geo in
      max(0, -(geo.contentOffset.y + geo.contentInsets.top))
    } action: { _, value in
      pulled.wrappedValue = value
    }
  }
}
