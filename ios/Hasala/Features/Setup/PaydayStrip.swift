import HasalaDesign
import HasalaModels
import SwiftUI

/// "Payday" and when the next one is, over the day strip (Paper "Payday picker · day strip
/// (snaps, haptic tick per day)", the answer to the owner's "a better selection UX" comment).
struct PaydayPicker: View {
  @Binding var choice: PaydayChoice
  /// The next payday for the choice, from the ledger's clock.
  let next: LocalDate

  var body: some View {
    VStack(spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline) { label; Spacer(minLength: 8); nextLine }
        VStack(alignment: .leading, spacing: 2) { label; nextLine }.frame(maxWidth: .infinity, alignment: .leading)
      }
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
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The tiles grow with the text in them; at the default size they are Paper's.
  @ScaledMetric(relativeTo: .title3) private var scale: CGFloat = 1

  /// The tile pitch (48 and the 8 gap), and how much the chosen one grows.
  private var pitch: CGFloat { 56 * scale }
  private var grow: CGFloat { 8 * scale }

  private var motion: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
  }

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
    .hHaptic(.keyTick, trigger: choice)
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

  @ViewBuilder private var label: some View {
    switch day {
    case .day(let d):
      if selected {
        VStack(spacing: 0) {
          Text(verbatim: "\(d)")
            .font(.system(size: 24 * scale, weight: .bold, design: .rounded))
            .foregroundStyle(HColor.white)
          Text(verbatim: PaydayChoice.suffix(d))
            .font(.custom(HWeight.semibold.interFace, fixedSize: 11 * scale))
            .foregroundStyle(HColor.white.opacity(0.8))
        }
      } else {
        Text(verbatim: "\(d)")
          .font(.system(size: 20 * scale, weight: .semibold, design: .rounded))
          .foregroundStyle(distance < 1.5 ? HColor.textPrimary : HColor.textSecondary)
      }
    case .lastWorkingDay:
      VStack(spacing: 0) {
        Text("Last").font(.custom(HWeight.semibold.interFace, fixedSize: 13 * scale))
        Text("work day").font(.custom(HWeight.medium.interFace, fixedSize: 11 * scale))
      }
      .foregroundStyle(selected ? HColor.white : HColor.textSecondary)
    }
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
