import HasalaDesign
import HasalaModels
import SwiftUI

// Parts the setup steps share (Paper row 10 and P2.9): a scaffold for the two steps that
// `AccountScreen`'s scrolling column doesn't fit (the docked keypad, a screen with no
// header), the step rows of the scan and done cards, the app icon tile, and the dock's
// lock note.

/// A setup step on Paper's frame when `AccountScreen` can't draw it: the wash, the system
/// bar as the account header (back, step indicator, Skip), the question block, then the
/// content and a dock pinned to the bottom.
///
/// `.fill` gives the content all the height between the question and the dock (the income
/// step centres its figure there, Paper 56S); it scrolls only when the text is too large to
/// fit. It is one scroll view either way (no second layout swapped in at a larger text
/// size), so the text on it keeps its identity as it grows. `.scroll` is a plain scrolling
/// column, with the question `top` under a hidden bar (the notifications step, 28 under the
/// status bar, Paper GMV).
struct SetupScreen<Content: View, Dock: View>: View {
  enum Layout { case fill, scroll }

  var title: String
  var subtitle: String?
  var steps: (current: Int, of: Int)?
  var back: AccountBack = .none
  var trailing: (title: String, action: () -> Void)?
  var wash: HWash = .setup
  var layout: Layout = .scroll
  /// The question under the header (16), or under the status bar when there is none.
  var top: CGFloat = 16
  @ViewBuilder var content: () -> Content
  @ViewBuilder var dock: () -> Dock

  var body: some View {
    // The reader sees the room between the header and the dock (the safe area); the
    // scroll view inside still runs under both.
    GeometryReader { viewport in
      ScrollView {
        switch layout {
        case .fill:
          FillOrGrow(minHeight: viewport.size.height) { column(filling: true) }
        case .scroll:
          column(filling: false).padding(.bottom, 16)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
    .safeAreaBar(edge: .bottom) { dock() }
    .background(alignment: .top) {
      AmbientWash(wash).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .accountHeader(steps: steps, back: back, trailing: trailing)
  }

  private func column(filling: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      SetupQuestion(title: title, subtitle: subtitle)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, top)
      content()
        .frame(maxWidth: .infinity, maxHeight: filling ? .infinity : nil)
    }
  }
}

/// A column that is at least `minHeight` tall: given exactly that when its content fits
/// (so a `maxHeight: .infinity` part takes the room left), and its own height when it
/// doesn't (the scroll view around it then scrolls).
private struct FillOrGrow: Layout {
  var minHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(width: proposal.width ?? natural.width, height: max(minHeight, natural.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }
}

/// The question block (Paper "Question"): Title 1 and a body line on the wash, 8 apart.
struct SetupQuestion: View {
  let title: String
  let subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .hType(.title1)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      if let subtitle {
        Text(subtitle)
          .hType(.body)
          .foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The note above a step's button (Paper "Note row"): a 16 lock in a 20 lane and 15/20
/// secondary text, 8 in from the dock's edges.
struct DockNote: View {
  var icon: HIcon = .lock
  var text: String

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      HIconView(icon, size: 16, color: HColor.textSecondary, strokeWidth: 2).frame(height: lane)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 8)
    .accessibilityElement(children: .combine)
  }
}

/// A setup failure as the steps show it: the account banner (one line of copy).
struct SetupFailureBanner: View {
  var failure: SetupFailure?

  var body: some View {
    if let message = failure?.message, !message.isEmpty {
      FailureBanner(failure: .badPhrase(message))
    }
  }
}
