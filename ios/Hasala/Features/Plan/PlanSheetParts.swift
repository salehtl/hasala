import HasalaDesign
import HasalaModels
import SwiftUI

// The parts of Plan's two sheets (Paper page 14 "Sheets & overlays"): the medium sheet's
// fitted white container and the large sheet's grey one, the sheet header, the money figure
// that is the field, the radio mark, a disc for "Ready to assign" and the pages pushed inside
// a sheet to pick a source or a category.

extension View {
  /// A medium sheet (page 14 §02 "Medium · Dining budget"): white, floating 8 from three
  /// edges, radius 40, one detent the height of its content (it never drags up to large). At
  /// the accessibility sizes the content grows past the screen and the sheet stops at large
  /// and scrolls. `height` is the content's measured height.
  func planMediumSheet(height: CGFloat) -> some View {
    presentationDetents([height > 0 ? .height(height) : .medium])
      .presentationCornerRadius(HRadius.sheet)
      .presentationBackground(HColor.sheetSurface)
      .presentationDragIndicator(.visible)
      // The shell presents this sheet with `.presentationDetents([.large])` (MainView, frozen),
      // and the outer modifier wins over this one; until Stage I drops it (requests/p7.md),
      // the sheet's own controller is fitted to the content directly.
      .background { FittedSheetDetent(height: height).frame(width: 0, height: 0) }
  }

  /// A large sheet (page 14 §02 "Large · Template"): full height, grey, top corners 34, the
  /// screen behind pushed back. Its rows sit in white cards.
  func planLargeSheet() -> some View {
    presentationDetents([.large])
      .presentationCornerRadius(HRadius.sheetLarge)
      .presentationBackground(HColor.sheetSurfaceLarge)
      .presentationDragIndicator(.visible)
  }
}

/// Fits the presenting sheet to `height` through its `UISheetPresentationController`: one
/// custom detent, never more than the screen allows (at the accessibility sizes the content
/// is taller, so the sheet stops at the top and scrolls). It is applied when the sheet appears
/// and whenever the height changes.
struct FittedSheetDetent: UIViewControllerRepresentable {
  let height: CGFloat

  func makeUIViewController(context: Context) -> Controller { Controller() }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.height = height
    controller.apply()
  }

  final class Controller: UIViewController {
    var height: CGFloat = 0
    private var applied: CGFloat = -1
    private static let fitted = UISheetPresentationController.Detent.Identifier("hasala.plan.fitted")

    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      applied = -1
      apply()
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      applied = -1
      apply()
    }

    func apply() {
      guard height > 0, height != applied, let sheet = presentingSheet else { return }
      applied = height
      // The detent is the height above the sheet's bottom safe area; the content runs into
      // that area itself (it ignores it), so the sheet ends 28 under the button, as drawn.
      let h = max(1, height - (sheet.presentedViewController.view.safeAreaInsets.bottom))
      let change = {
        sheet.detents = [.custom(identifier: Self.fitted) { context in min(h, context.maximumDetentValue) }]
        sheet.selectedDetentIdentifier = Self.fitted
      }
      if sheet.detents.contains(where: { $0.identifier == Self.fitted }) {
        sheet.animateChanges(change)
      } else {
        change()
      }
    }

    /// The sheet this view sits in: the nearest ancestor presented as a sheet.
    private var presentingSheet: UISheetPresentationController? {
      var vc: UIViewController? = self
      while let current = vc {
        if current.presentingViewController != nil, let sheet = current.sheetPresentationController {
          return sheet
        }
        vc = current.parent
      }
      return nil
    }
  }
}

/// A sheet's header (page 14 §03): 48 tall, the glass Close on the leading side, the title
/// centred in 17/22 semibold, an empty 48 slot on the trailing side so the title stays
/// centred. The action that finishes the task is the primary button at the bottom.
struct PlanSheetHeader: View {
  let title: String
  let closeID: String
  let close: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      GlassIconButton(.close, label: "Close", action: close)
        .accessibilityIdentifier(closeID)
      Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
      Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
        .accessibilityHidden(true)
    }
    .frame(minHeight: HSpacing.glassButton)
  }
}

/// The amount being set, as the field it is (Paper "AED 1,800", "AED 318.00"): "AED" 17/22
/// 600 and the figure 44/46 bold rounded, −0.8, on one baseline. The field keeps the typed
/// amount to the keypad rules (one point, two decimals, nine whole digits) and shows it with
/// thousands commas. Inputs show their real value with amounts hidden (spec 04 §12).
struct PlanAmountField: View {
  @Binding var text: String
  let identifier: String
  /// VoiceOver's name for the field ("New budget", "Amount").
  let label: String
  var focus: FocusState<Bool>.Binding

  @ScaledMetric(relativeTo: .largeTitle) private var figure: CGFloat = 44
  @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 17

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("AED")
        .font(.system(size: unit, weight: .semibold, design: .rounded))
        .foregroundStyle(HColor.textPrimary)
        .accessibilityHidden(true)
      TextField("0", text: $text)
        .font(.system(size: figure, weight: .bold, design: .rounded))
        .tracking(-0.8 * figure / 44)
        .foregroundStyle(HColor.textPrimary)
        .keyboardType(.decimalPad)
        .focused(focus)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .onChange(of: text) { _, new in
          let shown = Self.shown(new)
          if shown != new { text = shown }
        }
    }
    .contentShape(Rectangle())
    .onTapGesture { focus.wrappedValue = true }
  }

  /// What the field shows for what was typed: the keypad's rules, grouped ("1,800",
  /// "318.5"); empty stays empty so the placeholder shows.
  static func shown(_ typed: String) -> String {
    let entry = AmountEntry(typing: typed.filter { $0 != "," })
    return entry.isEmpty ? "" : entry.display
  }

  /// The field's text for an amount: "1,800" in the budget sheet (plan amounts are whole,
  /// page 06), "318.00" in Move money (`.exact`).
  static func text(for minor: Int64, style: MoneyStyle = .compact) -> String {
    shown(MoneyFormat.string(max(0, minor), style: style))
  }
}

/// The radio of a choice row (Move money "Take from"): 24, selected is the accent circle with
/// a white 14 check (stroke 3.2), unselected a 2 pt ring in gray 3. In a fixed 24 slot, so
/// rows line up.
struct RadioMark: View {
  let selected: Bool

  var body: some View {
    ZStack {
      if selected {
        Circle().fill(HColor.actionAccent)
        HIconView(.check, size: 14, color: HColor.white, strokeWidth: 3.2)
      } else {
        Circle().strokeBorder(HColor.appleGraysGray3, lineWidth: 2)
      }
    }
    .frame(width: 24, height: 24)
    .accessibilityHidden(true)
  }
}

/// A source's disc: the category's, or for Ready to assign the mint disc with the wallet.
struct SourceDisc: View {
  let source: MoveSource

  var body: some View {
    if source.id == nil {
      Circle().fill(Hue.mint.perceptualGradient).frame(width: 40, height: 40)
        .overlay { PlanGlyph(kind: .wallet, size: 20, color: Hue.mint.ink) }
        .accessibilityHidden(true)
    } else {
      CategoryDisc(hue: source.hue, glyph: source.glyph)
    }
  }
}

/// A source as a choice row: the disc, the name over what it has ("1,000.00 not in a budget
/// yet"), the radio. At least 60 tall; the whole row is the target and reads as one choice.
struct SourceRow: View {
  let source: MoveSource
  let selected: Bool
  let hidden: Bool

  var body: some View {
    HStack(spacing: HSpacing.listRowGap) {
      SourceDisc(source: source)
      VStack(alignment: .leading, spacing: 2) {
        Text(source.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        PhraseText(source.detail, hidden: hidden).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      RadioMark(selected: selected)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, 8)
    .frame(minHeight: 60)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(source.name), \(source.detail.spoken(hidden: hidden))")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// "Take it from" pushed inside the budget sheet (page 14: "Push a page inside the sheet to
/// go deeper"): every place the money can come from, in 03a §6.13's order. A tap picks it and
/// goes back.
struct SourcePickerPage: View {
  let title: String
  let sources: [MoveSource]
  let selected: CategoryID?
  let hidden: Bool
  /// Rows sit straight on a white medium sheet; on the grey large sheet they sit in a card.
  let onCard: Bool
  let pick: (CategoryID?) -> Void

  var body: some View {
    ScrollView {
      Group {
        if onCard {
          PlanListCard { rows }
        } else {
          VStack(spacing: 0) {
            Group(subviews: rows) { subviews in
              ForEach(Array(subviews.enumerated()), id: \.offset) { i, row in
                if i > 0 { HDivider(inset: .disc68) }
                row
              }
            }
          }
        }
      }
      .padding(.horizontal, onCard ? HSpacing.insetPage : 0)
      .padding(.vertical, 8)
    }
    .background(onCard ? HColor.sheetSurfaceLarge : HColor.sheetSurface)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private var rows: some View {
    ForEach(sources) { s in
      Button { pick(s.id) } label: { SourceRow(source: s, selected: s.id == selected, hidden: hidden) }
        .buttonStyle(HRowPressStyle())
        .accessibilityIdentifier("source.\(s.id ?? "rta")")
    }
  }
}

/// Assign's "To": every category a budget can go to, by bucket, pushed inside Move money.
struct DestinationPickerPage: View {
  let destinations: [CategoryOption]
  let selected: CategoryID?
  let pick: (CategoryID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ForEach([Bucket.needs, .wants, .savings], id: \.self) { bucket in
          let options = destinations.filter { $0.bucket == bucket }
          if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              PlanOverline(bucket.title)
              PlanListCard {
                ForEach(options) { o in
                  Button { pick(o.id) } label: {
                    HListRow(leading: .disc(o.hue, o.glyph.icon), title: o.name, trailing: .check(o.id == selected))
                  }
                  .buttonStyle(HRowPressStyle())
                  .accessibilityIdentifier("destination.\(o.id)")
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.vertical, 8)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("To")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Quick chips that share their line (Paper "Quick chips": each grows to fill its row; one
/// that doesn't fit takes the next line, full width). `spacing` apart side by side,
/// `lineSpacing` between lines (the chips carry 2 of their 44 pt target above and below the
/// drawn 40, so 4 here draws Paper's 8).
struct GrowingChipRows: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let lines = self.lines(subviews, width: width)
    let height = lines.reduce(CGFloat(0)) { sum, line in
      sum + placements(line, subviews, width: width).map(\.height).max()!
    } + lineSpacing * CGFloat(max(0, lines.count - 1))
    return CGSize(width: proposal.width ?? lines.map { lineWidth($0, subviews) }.max() ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for line in lines(subviews, width: bounds.width) {
      let sizes = placements(line, subviews, width: bounds.width)
      let height = sizes.map(\.height).max() ?? 0
      var x = bounds.minX
      for (k, i) in line.enumerated() {
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: sizes[k].width, height: height))
        x += sizes[k].width + spacing
      }
      y += height + lineSpacing
    }
  }

  /// Each chip of a line grown to share the line's room, never wider than the line (a chip
  /// alone on a line that its words overflow wraps them instead), and its height there.
  private func placements(_ line: [Int], _ subviews: Subviews, width: CGFloat) -> [CGSize] {
    let natural = line.map { subviews[$0].sizeThatFits(.unspecified).width }
    let room = width.isFinite ? width : natural.reduce(0, +) + spacing * CGFloat(line.count - 1)
    let extra = max(0, room - natural.reduce(0, +) - spacing * CGFloat(line.count - 1)) / CGFloat(line.count)
    return line.enumerated().map { k, i in
      let w = min(natural[k] + extra, room)
      return CGSize(width: w, height: subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
    }
  }

  private func lines(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
    var out: [[Int]] = []
    var current: [Int] = []
    var used: CGFloat = 0
    for i in subviews.indices {
      let w = subviews[i].sizeThatFits(.unspecified).width
      if !current.isEmpty, used + spacing + w > width {
        out.append(current)
        current = []
        used = 0
      }
      used += (current.isEmpty ? 0 : spacing) + w
      current.append(i)
    }
    if !current.isEmpty { out.append(current) }
    return out
  }

  private func lineWidth(_ line: [Int], _ subviews: Subviews) -> CGFloat {
    line.map { subviews[$0].sizeThatFits(.unspecified).width }.reduce(0, +) + spacing * CGFloat(max(0, line.count - 1))
  }
}

/// A quick chip on a sheet (Paper "+ 200", "Cover the pace 1,992"): 40 tall, 16 in, the
/// on-card chip fill; words 15/20 600, a figure in rounded compact. The button is 44 tall (2
/// above and below the drawn chip), so the target is its own frame; pressed, the drawn chip
/// darkens.
struct QuickChip: View {
  let title: String
  /// A figure after the words, rounded 600 in the count colour ("1,992"), or nil.
  var figure: MoneyPhrase?
  let hidden: Bool
  /// The words are a figure themselves ("+ 200"): rounded 700.
  var titleIsFigure = false
  let action: () -> Void

  /// How far the target reaches past the drawn chip, above and below.
  static let reach: CGFloat = (HSpacing.targetMinimum - HSpacing.chipHeight) / 2

  var body: some View {
    Button(action: action) {
      // The words and the figure on one line; at the larger sizes the figure goes under them.
      SideBySideOrStacked(spacing: 6, lineSpacing: 0, spreads: false, stackedAlignment: .center) {
        if titleIsFigure {
          Text(title).hFigure(.compact)
        } else {
          Text(title).hType(.smallButton).multilineTextAlignment(.center)
        }
        if let figure {
          Text(figure.rendered(hidden: hidden)).hFigure(HFigure.compact.weight(.semibold))
            .foregroundStyle(HColor.chipCount)
        }
      }
      .foregroundStyle(HColor.chipText)
      .padding(.horizontal, HSpacing.chipInset)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, minHeight: HSpacing.chipHeight)
      .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(ChipStyle())
    .accessibilityLabel(figure.map { "\(title), \($0.spoken(hidden: hidden))" } ?? title)
  }

  /// The chip's fill (and its pressed layer) on the drawn 40, inside a 44 target.
  private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .background(HColor.chipSurfaceOnCard, in: Capsule())
        .overlay { Capsule().fill(HColor.stateLayerPressed).opacity(configuration.isPressed ? 1 : 0) }
        .hAnimation(.highlight, value: configuration.isPressed)
        .padding(.vertical, QuickChip.reach)
        .contentShape(Rectangle())
    }
  }
}
