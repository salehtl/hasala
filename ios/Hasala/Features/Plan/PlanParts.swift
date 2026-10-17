import HasalaDesign
import HasalaModels
import SwiftUI

// Parts the Plan screens share: the pushed screen around Plan · Dining and Plan · Japan
// trip, a budget row's line of facts, the overline, the bucket dot and the two glyphs Plan
// draws that the kit has no icon for. Figures go through MoneyText and MoneyPhrase, so Hide
// amounts reaches every one (spec 04 §12).

/// One item of a pushed screen's More menu (page 14 §04: a native menu, verb first).
struct PlanMenuItem: Identifiable {
  let title: String
  let action: () -> Void
  var id: String { title }
}

/// A pushed Plan screen (Paper "Plan · Dining", "Plan · Japan trip"): the system bar with
/// its back button, the title and, when there is something to do, More; the hue's wash
/// scrolling away with the content; sections 32 apart from 20 under the bar, 160 at the
/// bottom so the last card clears the tab bar, and the soft edge over the tab bar.
struct PlanDetailScreen<Content: View>: View {
  let app: AppModel
  let title: String
  let wash: HWash
  /// The More menu; none when empty (a menu with nothing in it would promise an action).
  var more: [PlanMenuItem] = []
  /// Hosts the toast where nothing above does (the Plan tab's root hosts its own, but a pushed
  /// screen covers it; the profile sheet hosts one over all its pages).
  var hostsToast = true
  @ViewBuilder let content: () -> Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
        content()
      }
      .padding(.top, 20)
      .padding(.bottom, HSpacing.scrollContentBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // The wash starts at the top of the screen, behind the bar, and scrolls away with the
    // content (Paper: absolute, 420 tall); a pull or a refresh doesn't carry it down.
    .washBehind(wash)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.surfaceSecondary)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .modifier(MoreMenu(items: more))
    .overlay(alignment: .bottom) {
      if hostsToast { ToastHost(app: app) }
    }
  }
}

/// The More glass button and its native menu, on the trailing side of a pushed screen's bar.
/// With nothing to offer there is no toolbar at all: an empty one still leaves the bar a
/// zero-sized item, which the accessibility audit reads as a control too small to tap.
private struct MoreMenu: ViewModifier {
  let items: [PlanMenuItem]

  func body(content: Content) -> some View {
    if items.isEmpty {
      content
    } else {
      content.toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            ForEach(items) { item in Button(item.title, action: item.action) }
          } label: {
            HIconView(.more, size: HSpacing.iconGlass, color: HColor.iconGlass)
          }
          .accessibilityLabel("More")
          .accessibilityIdentifier("plan.more")
        }
      }
    }
  }
}

/// Two parts side by side on one baseline while they fit, else one above the other (Paper
/// draws them side by side; at larger text sizes they stack). The same views either way, so
/// their identity holds while the text size changes (a `ViewThatFits` swaps in a second copy,
/// which VoiceOver and the accessibility audit see as new text that never grew).
struct SideBySideOrStacked: Layout {
  /// Side by side: the least room between the parts.
  var spacing: CGFloat = 6
  /// Stacked: the room between the lines.
  var lineSpacing: CGFloat = 2
  /// Side by side: the first part at the leading edge and the last at the trailing edge
  /// (a field's label and value); otherwise the parts sit together, centred.
  var spreads = true
  /// Stacked: how the lines line up.
  var stackedAlignment: HorizontalAlignment = .leading

  private func sideBySide(_ subviews: Subviews, width: CGFloat?) -> Bool {
    let natural = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
      + spacing * CGFloat(max(0, subviews.count - 1))
    return natural <= (width ?? .infinity)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    if sideBySide(subviews, width: proposal.width) {
      let dims = subviews.map { $0.dimensions(in: .unspecified) }
      let ascent = dims.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
      let descent = dims.map { $0.height - $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
      let natural = dims.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, dims.count - 1))
      return CGSize(width: spreads ? (proposal.width ?? natural) : natural, height: ascent + descent)
    }
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
    let height = sizes.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, sizes.count - 1))
    return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    if sideBySide(subviews, width: bounds.width) {
      let dims = subviews.map { $0.dimensions(in: .unspecified) }
      let ascent = dims.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
      let natural = dims.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, dims.count - 1))
      let gap = spreads && dims.count > 1
        ? spacing + max(0, bounds.width - natural) / CGFloat(dims.count - 1) : spacing
      var x = spreads ? bounds.minX : bounds.minX + max(0, bounds.width - natural) / 2
      for (i, d) in dims.enumerated() {
        let y = bounds.minY + ascent - d[VerticalAlignment.firstTextBaseline]
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
        x += d.width + gap
      }
      return
    }
    var y = bounds.minY
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      let x: CGFloat = switch stackedAlignment {
      case .center: bounds.minX + (bounds.width - size.width) / 2
      case .trailing: bounds.maxX - size.width
      default: bounds.minX
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: bounds.width, height: nil))
      y += size.height + lineSpacing
    }
  }
}

/// "NEW BUDGET", "TO", "TAKE FROM": the 13/16 overline just inside a block's edge.
struct PlanOverline: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title).hType(.overline).foregroundStyle(HColor.textSecondary)
      .padding(.leading, 4)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A bucket's dot, beside its name and on the split: the hue's deeper step (Paper draws raw
/// #E9B877, #BBA6E6 and #93D3B5; they are `Hue.dotDeep`).
extension Bucket {
  var splitColor: Color { Color(hue.dotDeep) }
}

/// The glyphs Plan draws that the kit has no icon for, from the Paper boards' paths: the
/// wallet of Ready to assign (Plan · October, Move money) and the before → after arrow (Move
/// money). Line drawings on the 24 grid with round caps and joins, like `HIconView`.
struct PlanGlyph: View {
  enum Kind {
    /// Plan · October "Ready to assign": a wallet with its flap and clasp.
    case wallet
    /// Move money "Before and after": an arrow to the right.
    case arrowRight
  }

  let kind: Kind
  let size: CGFloat
  let color: Color
  /// The main stroke in grid units (the wallet's clasp is drawn a little heavier).
  var stroke: CGFloat = 1.9

  private var lines: [(d: String, width: CGFloat)] {
    switch kind {
    case .wallet:
      [("M4 8V7a2.5 2.5 0 0 1 2.5-2.5H16", stroke),
       ("M6 7.5H18A2.5 2.5 0 0 1 20.5 10V17A2.5 2.5 0 0 1 18 19.5H6A2.5 2.5 0 0 1 3.5 17V10A2.5 2.5 0 0 1 6 7.5Z",
        stroke),
       ("M15.5 13.5h1.5", stroke + 0.4)]
    case .arrowRight:
      [("M4.5 12h14M13 6.5l5.5 5.5-5.5 5.5", stroke)]
    }
  }

  var body: some View {
    Canvas { context, canvas in
      let box = CGRect(origin: .zero, size: canvas)
      let unit = min(canvas.width, canvas.height) / 24
      for line in lines {
        guard let svg = try? SVGPath(parsing: line.d) else { continue }
        context.stroke(svg.path(in: box), with: .color(color),
                       style: StrokeStyle(lineWidth: line.width * unit, lineCap: .round, lineJoin: .round))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// A budget row's second line (page 16 §05): "spent of plan", then one short fact. Words run
/// together with " · "; a status leads with a 7 dot and is set 600 in its colour: green for a
/// paid bill, amber words with the brighter amber dot for "Over pace", red for a late bill.
/// One line at the default size; at the accessibility sizes it wraps, the dot riding in the
/// text. VoiceOver reads the words, with "Amount hidden" for each hidden figure.
struct PlanFactsLine: View {
  let parts: [PlanDetailPart]
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  /// Adjacent words are one run; a status stands alone.
  private enum Run {
    case words(String)
    case status(String, StatusTone)
  }

  private var runs: [Run] {
    var out: [Run] = []
    for part in parts {
      switch part {
      case .text(let p):
        let s = p.rendered(hidden: hidden)
        if case .words(let previous)? = out.last {
          out[out.count - 1] = .words(previous + " · " + s)
        } else {
          out.append(.words(s))
        }
      case .status(let words, let tone):
        out.append(.status(words, tone))
      }
    }
    return out
  }

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        wrapped.fixedSize(horizontal: false, vertical: true)
      } else {
        line
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  /// Paper's drawing: runs 6 apart, " ·" closing the words before a status and "· " opening
  /// the words after one.
  private var line: some View {
    let runs = self.runs
    return HStack(spacing: 6) {
      ForEach(Array(runs.enumerated()), id: \.offset) { i, run in
        switch run {
        case .words(let s):
          let lead = i > 0 ? "· " : ""
          let tail = i + 1 < runs.count ? " ·" : ""
          Text(verbatim: lead + s + tail).hType(.footnote).foregroundStyle(HColor.textSecondary)
        case .status(let words, let tone):
          HStack(spacing: 6) {
            Circle().fill(Self.dot(tone)).frame(width: 7, height: 7)
            Text(words).hType(.footnote.weight(.semibold)).foregroundStyle(Self.words(tone))
          }
        }
      }
    }
    .lineLimit(1)
  }

  /// The same line as one wrapping text, the dot a character in it.
  private var wrapped: Text {
    var out = Text(verbatim: "")
    for (i, run) in runs.enumerated() {
      if i > 0 { out = Text("\(out)\(Text(verbatim: " · ").foregroundStyle(HColor.textSecondary))") }
      switch run {
      case .words(let s):
        out = Text("\(out)\(Text(verbatim: s).foregroundStyle(HColor.textSecondary))")
      case .status(let words, let tone):
        let dot = Text(verbatim: "● ").foregroundStyle(Self.dot(tone))
        let w = Text(verbatim: words).font(HType.footnote.weight(.semibold).font).foregroundStyle(Self.words(tone))
        out = Text("\(out)\(dot)\(w)")
      }
    }
    return out.font(HType.footnote.font)
  }

  private var spoken: String {
    parts.map { part in
      switch part {
      case .text(let p): p.spoken(hidden: hidden)
      case .status(let words, _): words
      }
    }.joined(separator: ", ")
  }

  static func dot(_ tone: StatusTone) -> Color {
    switch tone {
    case .warning: HColor.paceFillOverPace
    case .error: HColor.paceOverBudget
    case .success: HColor.paceOnTrack
    case .accent: HColor.actionAccent
    }
  }

  static func words(_ tone: StatusTone) -> Color {
    switch tone {
    case .warning: HColor.paceOverPace
    case .error: HColor.paceOverBudget
    case .success: HColor.paceOnTrack
    case .accent: HColor.actionAccent
    }
  }
}

/// "✓ Done", "✓ Done for October": the 14 check (stroke 3) and the words, 600 green.
struct DoneMark: View {
  let words: String

  init(_ words: String) { self.words = words }

  var body: some View {
    HStack(spacing: 4) {
      HIconView(.check, size: 14, color: HColor.statusSuccessForeground, strokeWidth: 3)
      Text(words).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.statusSuccessForeground)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isStaticText)
  }
}

/// A white list card's rows with Paper's dividers between them (1 pt `--color-border-subtle`,
/// inset to where the text starts; 16 at the accessibility sizes, where rows stack).
struct PlanListCard<Content: View>: View {
  var inset: HDivider.Inset = .disc68
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
