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

/// The close button of a large sheet (Paper "Template · Sheet (large)": × top left).
struct SheetCloseButton: ToolbarContent {
  let identifier: String
  let action: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(role: .close, action: action)
        // Paper draws a sheet's close × in the glass ink (`--color-icon-glass`); the system
        // button would take the app's accent (requests p5 3, p6 3, p8 3).
        .tint(HColor.iconGlass)
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

/// Where a screen's wash sits while its scroll view moves (Paper: the wash is absolute at the
/// top of the screen, 420 tall, and scrolls away with the content). Scrolling up carries it
/// away; a pull past the top, and the spinner's hold while a refresh runs, leave it put.
nonisolated enum WashPin {
  /// The wash's offset from the top of the screen: up by as far as the content has scrolled
  /// up past its top, 0 while it is at rest, pulled down, or held down by the refresh spinner
  /// (which grows `insetTop` by its own height and holds `contentOffset` at minus that).
  static func offset(contentOffset: CGFloat, insetTop: CGFloat) -> CGFloat {
    -max(0, contentOffset + insetTop)
  }
}

extension View {
  /// Draws `wash` behind a scroll view, from the top of the screen (`WashPin`). It sits
  /// outside the scrolled content, so a pull, the refresh spinner's hold and the bounce back
  /// don't carry it down (drawn in the content, it went down with them wherever the offset
  /// that undid the pull lagged: the spinner's hold, the animated settle): it moves only by
  /// its offset, and only up.
  func washBehind(_ wash: HWash) -> some View {
    modifier(WashBehind(wash: wash))
  }
}

private struct WashBehind: ViewModifier {
  let wash: HWash
  @State private var offset: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: CGFloat.self) { geo in
        WashPin.offset(contentOffset: geo.contentOffset.y, insetTop: geo.contentInsets.top)
      } action: { _, value in
        offset = value
      }
      .background(alignment: .top) {
        AmbientWash(wash).offset(y: offset).ignoresSafeArea(edges: .top)
      }
  }
}
