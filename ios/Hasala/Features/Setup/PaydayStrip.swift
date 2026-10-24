import HasalaDesign
import HasalaModels
import SwiftUI

/// "Payday" and when the next one is, over the day strip (Paper "Payday picker · day strip
/// (snaps, haptic tick per day)", the answer to the owner's "a better selection UX" comment).
struct PaydayPicker: View {
  @Binding var choice: PaydayChoice
  /// The next payday for the choice, from the ledger's clock.
  let next: LocalDate
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(spacing: 10) {
      // One row as Paper draws it; at the accessibility sizes the next payday goes under
      // "Payday" (the same two texts, so they keep growing where they are).
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
      layout {
        label
        if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        nextLine
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HSpacing.insetPage)
      PaydayStrip(choice: $choice)
    }
  }

  private var label: some View {
    Text("Payday").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
  }

  /// "Next one Wed, 28 Oct".
  private var nextLine: some View {
    Text("Next one \(next.weekdayShort), \(next.dayMonth)")
      .hType(.footnote.weight(.medium))
      .foregroundStyle(HColor.textSecondary)
  }
}

/// The day strip: the 1st to the 31st and "Last work day" in a row that runs past the
/// screen's edges, the chosen day lifted into an accent tile in the middle. Drag it, flick
/// it, or tap a day: it snaps to a day, with a light tick for each day it passes. Days fade
/// with their distance from the chosen one.
///
/// It doesn't scroll: one position, `centre`, places every tile, so a drag moves the strip
/// under the finger and the chosen tile grows as it reaches the middle. VoiceOver reads
/// the chosen tile, "Payday, 28th", and swipes up or down to change it; the days either
/// side are buttons too.
struct PaydayStrip: View {
  @Binding var choice: PaydayChoice

  /// Where the strip is while a finger moves it, in tiles from the 1st (nil at rest).
  @State private var dragCentre: Double?
  /// The tiles moved since the drag began, for the tick per day passed.
  @State private var dragStart: Double = 0
  @StageMotion private var motion: MotionPolicy
  /// The tiles grow with the text in them; at the default size they are Paper's.
  @ScaledMetric(relativeTo: .title3) private var scale: CGFloat = 1

  /// The tile pitch (48 and the 8 gap), and how much the chosen one grows.
  private var pitch: CGFloat { 56 * scale }
  private var grow: CGFloat { 8 * scale }

  private var centre: Double { dragCentre ?? Double(choice.index) }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        ForEach(PaydayChoice.all, id: \.self) { day in
          tile(day, width: geo.size.width)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
      .contentShape(Rectangle())
      .gesture(drag)
    }
    .frame(height: 64 * scale)
    // A picker step: the selection tick (motion policy, Haptics), not the keypad's tap.
    .hHaptic(.selection, trigger: choice)
  }

  /// One day: its place from the centre, its size (the chosen one 56 × 64, the rest
  /// 48 × 56), and its fade by distance (Paper ±1 full, ±2 secondary, ±3 0.75, ±4 0.5).
  @ViewBuilder private func tile(_ day: PaydayChoice, width: CGFloat) -> some View {
    let offset = Double(day.index) - centre
    let distance = abs(offset)
    let lift = CGFloat(max(0, 1 - distance))
    let side: CGFloat = offset < 0 ? -1 : 1
    // The chosen tile pushes its neighbours out by half its growth; the wider "Last work
    // day" tile sits 4 further out.
    let push = CGFloat(min(1, distance)) * (grow / 2 + (day == .lastWorkingDay ? 4 * scale : 0)) * side
    let x = CGFloat(offset) * pitch + push
    if abs(x) < width / 2 + pitch {
      PaydayTile(day: day, selected: day == choice, lift: lift, distance: distance, scale: scale)
        .offset(x: x)
        .opacity(distance >= 4 ? 0.5 : distance >= 3 ? 0.75 : 1)
        .onTapGesture { settle(on: day.index) }
        .accessibilityHidden(distance > 3.5)
        .modifier(PaydayAccessibility(day: day, chosen: day == choice, pick: { settle(on: day.index) }) { step($0) })
    }
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in
        if dragCentre == nil { dragStart = Double(choice.index) }
        let moved = dragStart - Double(value.translation.width / pitch)
        let clamped = min(Double(PaydayChoice.all.count - 1), max(0, moved))
        dragCentre = clamped
        // A tick for each day passed: the choice follows the day in the middle.
        let nearest = PaydayChoice.all[Int(clamped.rounded())]
        if nearest != choice { choice = nearest }
      }
      .onEnded { value in
        // A flick carries on to where it would coast, then snaps to a day.
        let projected = dragStart - Double(value.predictedEndTranslation.width / pitch)
        settle(on: Int(min(Double(PaydayChoice.all.count - 1), max(0, projected)).rounded()))
      }
  }

  private func settle(on index: Int) {
    withHMotion(.thumbSlide, motion) {
      choice = PaydayChoice.all[index]
      dragCentre = nil
    }
  }

  /// VoiceOver's swipe up or down on the chosen day.
  private func step(_ by: Int) {
    let index = min(PaydayChoice.all.count - 1, max(0, choice.index + by))
    settle(on: index)
  }
}

/// A day tile (Paper "Day", "Day · Selected", "Day · Last working day").
private struct PaydayTile: View {
  let day: PaydayChoice
  let selected: Bool
  /// 0…1: how far into the middle it is (1 is the chosen size).
  let lift: CGFloat
  let distance: Double
  let scale: CGFloat

  var body: some View {
    let width = ((day == .lastWorkingDay ? 56 : 48) + (day == .lastWorkingDay ? 0 : 8 * lift)) * scale
    let height = (56 + 8 * lift) * scale
    RoundedRectangle(cornerRadius: (16 + 2 * lift) * scale, style: .continuous)
      .fill(selected ? HColor.actionAccent : HColor.surfacePrimary)
      .shadow(color: selected ? HColor.actionAccent.opacity(0.35) : .clear, radius: 8, x: 0, y: 6)
      .frame(width: width, height: height)
      .overlay { label }
  }

  // Paper: the day 20/24 semibold, the chosen day 24/28 bold over its "th" (Inter 11/14
  // 600); "Last" 13/16 600 over "work day" 11/14 500. Each grows on its own text style's
  // curve; the small words grow faster than the tile, so they shrink to fit it if they must.
  private static let numeral = HFigure(size: 20, leading: 24, weight: .semibold, textStyle: .title3)
  private static let chosenNumeral = HFigure(size: 24, leading: 28, weight: .bold, textStyle: .title3)
  private static let suffix = HType(size: 11, leading: 14, weight: .semibold, textStyle: .caption2)
  private static let last = HType(size: 13, leading: 16, weight: .semibold, textStyle: .footnote)
  private static let workDay = HType(size: 11, leading: 14, weight: .medium, textStyle: .caption2)

  @ViewBuilder private var label: some View {
    switch day {
    case .day(let d):
      if selected {
        VStack(spacing: 0) {
          Text(verbatim: "\(d)").hFigure(Self.chosenNumeral).foregroundStyle(HColor.white)
          OrdinalMark(text: PaydayChoice.suffix(d), type: Self.suffix)
        }
      } else {
        Text(verbatim: "\(d)")
          .hFigure(Self.numeral)
          .foregroundStyle(distance < 1.5 ? HColor.textPrimary : HColor.textSecondary)
      }
    case .lastWorkingDay:
      VStack(spacing: 0) {
        Text("Last").hType(Self.last)
        Text("work day").hType(Self.workDay)
      }
      .lineLimit(1)
      .minimumScaleFactor(0.5)
      .padding(.horizontal, 2)
      .foregroundStyle(selected ? HColor.white : HColor.textSecondary)
    }
  }
}

/// The chosen day's ordinal ending under its numeral ("th", white at 80%): part of the
/// figure, so it is drawn with it rather than read on its own (the tile reads "Payday,
/// 28th"). It grows with the text size on its style's curve.
private struct OrdinalMark: View {
  let text: String
  let type: HType
  @ScaledMetric private var line: CGFloat

  init(text: String, type: HType) {
    self.text = text
    self.type = type
    _line = ScaledMetric(wrappedValue: type.leading, relativeTo: type.textStyle)
  }

  var body: some View {
    let mark = Text(verbatim: text).font(type.font).foregroundStyle(HColor.white.opacity(0.8))
    Canvas { context, size in
      context.draw(context.resolve(mark), at: CGPoint(x: size.width / 2, y: size.height / 2))
    }
    .frame(height: line)
    .accessibilityHidden(true)
  }
}

/// Each tile is a button ("25th"); the chosen one is also adjustable: "Payday, 28th".
private struct PaydayAccessibility: ViewModifier {
  let day: PaydayChoice
  let chosen: Bool
  var pick: () -> Void
  var step: (Int) -> Void

  func body(content: Content) -> some View {
    content
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(chosen ? "Payday, \(day.spoken)" : day.spoken)
      .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction(.default, pick)
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: step(1)
        case .decrement: step(-1)
        @unknown default: break
        }
      }
      .accessibilityIdentifier(day.identifier)
  }
}
