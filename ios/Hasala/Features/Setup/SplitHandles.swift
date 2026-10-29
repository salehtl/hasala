import HasalaDesign
import HasalaModels
import SwiftUI

/// The starting split as a bar with two handles (Paper "Split · 50 / 30 / 20", "Stacked bar
/// · draggable"; the owner's "Add handles so the user can drag the ratios"): needs, wants and
/// savings in their hues, a white knob between each pair, the percentages under their
/// segments.
///
/// A handle moves in 5% steps with a light tick per step; each bucket can reach 0% and the
/// three always make 100. The left handle trades needs for wants, the right one wants for
/// savings. A drag anywhere on the bar takes the nearer handle, so the 10 pt knobs never
/// need hitting. VoiceOver reads each handle as adjustable: "Needs, 50%", "Wants, 30%".
struct SplitHandles: View {
  @Binding var plan: StartingPlan

  /// The handle a drag moves (nil at rest).
  @State private var dragging: Int?

  /// A handle's slot is 20 wide (Paper), its touch area 44.
  private static let slot: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      GeometryReader { geo in
        let track = max(0, geo.size.width - 2 * Self.slot)
        ZStack(alignment: .leading) {
          HStack(spacing: 0) {
            segment(.needs, plan.needsPercent, track)
            Knob().frame(width: Self.slot)
            segment(.wants, plan.wantsPercent, track)
            Knob().frame(width: Self.slot)
            segment(.savings, plan.savingsPercent, track)
          }
          .frame(height: 32)
          handle(0, at: x(of: 0, track), track: track)
          handle(1, at: x(of: 1, track), track: track)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .gesture(drag(track: track))
      }
      .frame(height: 44)
      .padding(.vertical, -6)
      labels
    }
    // Each 5% step slides on the snappy spring (a jump with Reduce Motion), with a tick.
    .hAnimation(.thumbSlide, value: plan)
    .hHaptic(.keyTick, trigger: plan)
  }

  /// A bucket's segment: 16 tall, radius 8, the hue's end colour under a 10% → 16% ink
  /// wash. A bucket at 0% has no segment; its handles meet.
  private func segment(_ bucket: Bucket, _ percent: Int, _ track: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(bucket.hue.end)
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(LinearGradient(colors: [bucket.hue.ink.opacity(0.10), bucket.hue.ink.opacity(0.16)],
                               startPoint: .top, endPoint: .bottom))
      }
      .frame(width: track * CGFloat(percent) / 100, height: 16)
      .accessibilityHidden(true)
  }

  /// Where handle `i`'s slot centre sits.
  private func x(of handle: Int, _ track: CGFloat) -> CGFloat {
    track * CGFloat(boundary(handle)) / 100 + Self.slot * (CGFloat(handle) + 0.5)
  }

  private func boundary(_ handle: Int) -> Int {
    handle == 0 ? plan.needsPercent : plan.needsPercent + plan.wantsPercent
  }

  /// The handle as VoiceOver and the tests reach it: a 44 box over the knob, adjustable.
  private func handle(_ i: Int, at x: CGFloat, track: CGFloat) -> some View {
    let bucket = i == 0 ? "Needs" : "Wants"
    let percent = i == 0 ? plan.needsPercent : plan.wantsPercent
    return Color.clear
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .offset(x: x - 22)
      .accessibilityElement()
      .accessibilityLabel(bucket)
      .accessibilityValue("\(percent)%")
      .accessibilityHint("Swipe up or down to move 5%.")
      .accessibilityAdjustableAction { direction in
        move(i, to: boundary(i) + (direction == .increment ? 5 : -5))
      }
      .accessibilityIdentifier("plan.split.handle.\(i)")
  }

  private func drag(track: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard track > 0 else { return }
        let handle = dragging ?? nearest(to: value.startLocation.x, track)
        dragging = handle
        let percent = (value.location.x - Self.slot * (CGFloat(handle) + 0.5)) / track * 100
        move(handle, to: Int((percent / 5).rounded()) * 5)
      }
      .onEnded { _ in dragging = nil }
  }

  private func nearest(to x: CGFloat, _ track: CGFloat) -> Int {
    abs(x - self.x(of: 0, track)) <= abs(x - self.x(of: 1, track)) ? 0 : 1
  }

  /// Moves handle `i` to `boundary` percent (from the left), keeping each bucket at 0% or
  /// more and the three at 100.
  private func move(_ i: Int, to boundary: Int) {
    let next = plan.moving(handle: i, to: boundary)
    if next != plan { plan = next }
  }

  /// "50%" under its segment, in its ink (Paper "Labels": the same growth as the
  /// segments, 20 apart).
  private var labels: some View {
    SplitLabelLayout(slot: Self.slot) {
      if plan.needsPercent > 0 {
        label(.needs, plan.needsPercent).layoutValue(key: SplitLabelStart.self, value: .init(percent: 0, knobs: 0))
      }
      if plan.wantsPercent > 0 {
        label(.wants, plan.wantsPercent)
          .layoutValue(key: SplitLabelStart.self, value: .init(percent: plan.needsPercent, knobs: 1))
      }
      if plan.savingsPercent > 0 {
        label(.savings, plan.savingsPercent)
          .layoutValue(key: SplitLabelStart.self,
                       value: .init(percent: plan.needsPercent + plan.wantsPercent, knobs: 2))
      }
    }
    .frame(minHeight: 20)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityLabel(
      "Needs \(plan.needsPercent)%, wants \(plan.wantsPercent)%, savings \(plan.savingsPercent)%")
  }

  private func label(_ bucket: Bucket, _ percent: Int) -> some View {
    Text(verbatim: "\(percent)%")
      .hFigure(HFigure(size: 15, leading: 20, weight: .semibold, textStyle: .subheadline,
                       maxDynamicTypeSize: .accessibility1))
      .foregroundStyle(bucket.hue.ink)
      .fixedSize()
  }
}

nonisolated struct SplitLabelStart: LayoutValueKey {
  static let defaultValue = SplitLabelStart.Value(percent: 0, knobs: 0)

  struct Value: Equatable {
    var percent: Int
    var knobs: Int
  }
}

struct SplitLabelLayout: Layout {
  var slot: CGFloat
  var gap: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    return CGSize(width: proposal.width ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
    let track = max(0, bounds.width - 2 * slot)
    let ideal = subviews.map { view -> CGFloat in
      let start = view[SplitLabelStart.self]
      return track * CGFloat(start.percent) / 100 + slot * CGFloat(start.knobs)
    }
    let xs = Self.positions(ideal: ideal, widths: widths, width: bounds.width, gap: gap)
    for (i, view) in subviews.enumerated() {
      view.place(at: CGPoint(x: bounds.minX + xs[i], y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
    }
  }

  static func positions(ideal: [CGFloat], widths: [CGFloat], width: CGFloat, gap: CGFloat) -> [CGFloat] {
    var xs = ideal
    for i in xs.indices {
      let lower = i == 0 ? 0 : xs[i - 1] + widths[i - 1] + gap
      xs[i] = max(xs[i], lower)
    }
    for i in xs.indices.reversed() {
      let upper = i == xs.count - 1 ? width - widths[i] : xs[i + 1] - gap - widths[i]
      xs[i] = min(xs[i], upper)
    }
    if let first = xs.first, first < 0 { xs[0] = 0 }
    return xs
  }
}

/// The white knob between two segments: 10 × 32, radius 5, with three grip lines.
private struct Knob: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .fill(HColor.white)
      .frame(width: 10, height: 32)
      .shadow(color: HColor.textPrimary.opacity(0.22), radius: 2, x: 0, y: 1)
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(HColor.textPrimary.opacity(0.12), lineWidth: 0.5)
      }
      .overlay {
        VStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 1).fill(HColor.neutral400).frame(width: 4, height: 1.5)
          }
        }
      }
      .accessibilityHidden(true)
  }
}

extension StartingPlan {
  /// The split with handle `i` at `boundary` percent from the left, in 5% steps: the left
  /// handle trades needs for wants, the right one wants for savings. No bucket goes under
  /// 0%, and the three stay at 100.
  func moving(handle i: Int, to boundary: Int) -> StartingPlan {
    let step = Int((Double(boundary) / 5).rounded()) * 5
    var next = self
    if i == 0 {
      let b = min(max(step, 0), needsPercent + wantsPercent)
      next.wantsPercent = needsPercent + wantsPercent - b
      next.needsPercent = b
    } else {
      let b = min(max(step, needsPercent), 100)
      next.wantsPercent = b - needsPercent
      next.savingsPercent = 100 - b
    }
    return next
  }
}
