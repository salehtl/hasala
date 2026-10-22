import HasalaDesign
import HasalaModels
import SwiftUI

// The drawings the welcome stories and the join screens share (spec 04 §2.1, §2.4, §2.5,
// §6.1; spec 07 S1, S3): the morning background, the orbit stage, the Hasala slot mark
// and the app icon tile. All decorative: hidden from VoiceOver, never scaled by Dynamic
// Type (the copy next to them carries the words).

// MARK: - Background

/// The stories' background (Paper "StoryBackground"): the sky start, under a 180° wash
/// from the morning blue through the sky start to blue 50, interpolated perceptually.
struct StoryBackground: View {
  var body: some View {
    Rectangle()
      .fill(.linearGradient(
        Gradient(stops: [
          .init(color: HColor.washMorning, location: 0),
          .init(color: HColor.hueSkyStart, location: 0.52),
          .init(color: HColor.blue50, location: 1),
        ]).colorSpace(.perceptual),
        startPoint: .top, endPoint: .bottom))
      .background(HColor.hueSkyStart)
    .accessibilityHidden(true)
  }
}

// MARK: - Orbit stage

/// The orbit behind every story (Paper "Orbits" and "Glow", 402 × 337 at (0, 16) in the
/// stage; the glow 320 at (41, 22)): an outer ring, a dotted inner ring, two white dots and
/// the sky-ink dot that travels the outer ring once per story. The rings turn 20° per page
/// as the pager moves (spec 04 §3.1); with Reduce Motion they hold still.
struct OrbitRings: View {
  /// The rings' turn, in degrees.
  var turn: Double
  /// The travelling dot's angle from the top, in degrees, clockwise.
  var dot: Double

  /// The orbit's centre in its own 402 × 337 box.
  static let centre = CGPoint(x: 201, y: 164)
  static let size = CGSize(width: 402, height: 337)

  var body: some View {
    Canvas { context, size in
      let s = size.width / Self.size.width
      let c = CGPoint(x: Self.centre.x * s, y: Self.centre.y * s)
      let ring = Color.white.opacity(0.9)
      context.stroke(Path(ellipseIn: CGRect(x: c.x - 156 * s, y: c.y - 156 * s, width: 312 * s, height: 312 * s)),
                     with: .color(ring), lineWidth: 1.5 * s)
      // The dotted ring turns with the pager (its dashes show the turn).
      var inner = context
      inner.translateBy(x: c.x, y: c.y)
      inner.rotate(by: .degrees(turn))
      inner.stroke(Path(ellipseIn: CGRect(x: -104 * s, y: -104 * s, width: 208 * s, height: 208 * s)),
                   with: .color(ring),
                   style: StrokeStyle(lineWidth: 1.5 * s, lineCap: .round, dash: [2 * s, 6 * s]))
      // The two white dots ride the rings: one on the inner (left), one on the outer (right).
      func spot(_ radius: CGFloat, _ angle: Double, _ r: CGFloat, _ color: Color) {
        let a = (angle - 90) * .pi / 180
        let p = CGPoint(x: c.x + radius * s * cos(a), y: c.y + radius * s * sin(a))
        context.fill(Path(ellipseIn: CGRect(x: p.x - r * s, y: p.y - r * s, width: 2 * r * s, height: 2 * r * s)),
                     with: .color(color))
      }
      spot(104, 270 + turn, 3.5, .white)
      spot(156, 90 + turn, 3, .white)
      spot(156, dot + turn, 3, HColor.hueSkyInk)
    }
    .frame(width: Self.size.width, height: Self.size.height)
  }
}

/// The soft white glow inside the rings (Paper "Glow": 320, radial white 85% to clear at 70%
/// of the farthest corner).
struct OrbitGlow: View {
  var body: some View {
    Circle()
      .fill(.radialGradient(
        Gradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0)]).colorSpace(.perceptual),
        center: .center, startRadius: 0, endRadius: 160 * 2.squareRoot() * 0.7))
      .frame(width: 320, height: 320)
  }
}

// MARK: - The Hasala slot mark

/// The Hasala mark drawn from its artwork (viewBox 204 328 616 368): the plate, the slot and
/// its lit lip, and the coin cut at the slot's centre line, so it reads as dropping in.
/// `drop` lifts the coin out of the slot, in the artwork's units (the story 3 coin falls in
/// from above); it animates. The drawing fits the frame's width and sits on its bottom
/// edge, so a taller frame leaves room above for the coin to fall from.
struct SlotMark: View, Animatable {
  enum Plate { case onTile, onWash }

  var plate: Plate = .onWash
  /// The thin inner ring and the slot's lit lip (Paper leaves both off the 56 app icon).
  var detailed = true
  /// The coin's drop shadow (story 3: dy 14, blur 18, blue 950 at 22%).
  var coinShadow = false
  var drop: CGFloat = 0
  var spin: CGFloat = 0
  var squash: CGFloat = 0

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
    get { AnimatablePair(AnimatablePair(drop, spin), squash) }
    set {
      drop = newValue.first.first
      spin = newValue.first.second
      squash = newValue.second
    }
  }

  static let aspect: CGFloat = 616 / 368

  static func scale(in size: CGSize) -> CGFloat { min(size.width / 616, size.height / 368) }

  static func slotCentre(in size: CGSize) -> CGPoint {
    let s = scale(in: size)
    let ox = (size.width - 616 * s) / 2, oy = size.height - 368 * s
    return CGPoint(x: ox + (512 - 204) * s, y: oy + (632 - 328) * s)
  }

  static let coinRim = Color(HRGBA(0xC9, 0x8A, 0x1E, 1))
  static let coinLight = Color(HRGBA(0xF9, 0xDC, 0x94, 1))
  static let coinDeep = Color(HRGBA(0xEB, 0xB0, 0x4A, 1))

  var body: some View {
    Canvas { context, size in
      let s = Self.scale(in: size)
      let slot = Self.slotCentre(in: size)
      let ox = (size.width - 616 * s) / 2, oy = size.height - 368 * s
      func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: ox + (x - 204) * s, y: oy + (y - 328) * s, width: w * s, height: h * s)
      }
      func capsule(_ rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: rect.height / 2) }
      let navy = HColor.blue950
      context.fill(capsule(r(212, 576, 600, 112)),
                   with: .color(plate == .onTile ? Color.white.opacity(0.14) : navy.opacity(0.12)))
      context.fill(capsule(r(244, 600, 536, 64)), with: .color(navy))
      if detailed {
        context.fill(capsule(r(268, 648, 488, 10)), with: .color(Color.white.opacity(0.22)))
      }
      // The coin, halfway in: everything below the slot's centre line is cut away.
      var coin = context
      coin.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: slot.y)))
      if coinShadow {
        coin.addFilter(.shadow(color: navy.opacity(0.22), radius: 18 * s, x: 0, y: 14 * s))
      }
      coin.translateBy(x: 0, y: -drop * s)
      if squash != 0 {
        coin.translateBy(x: slot.x, y: slot.y)
        coin.scaleBy(x: 1 + squash * 0.6, y: max(1 - squash, 0.2))
        coin.translateBy(x: -slot.x, y: -slot.y)
      }
      if spin != 0 {
        coin.translateBy(x: slot.x, y: 0)
        coin.scaleBy(x: max(abs(cos(spin * .pi * 2)), 0.04), y: 1)
        coin.translateBy(x: -slot.x, y: 0)
      }
      coin.drawLayer { layer in
        let rim = Self.coinRim
        layer.fill(Path(ellipseIn: r(512 - 184, 538.2 - 184, 368, 368)), with: .color(rim))
        let faceRect = r(512 - 184, 519.8 - 184, 368, 368)
        layer.fill(
          Path(ellipseIn: faceRect),
          with: .linearGradient(
            Gradient(colors: [Self.coinLight, Self.coinDeep]),
            startPoint: CGPoint(x: faceRect.midX, y: faceRect.minY),
            endPoint: CGPoint(x: faceRect.midX, y: faceRect.maxY)))
        if detailed {
          layer.stroke(Path(ellipseIn: r(512 - 139.8, 519.8 - 139.8, 279.6, 279.6)),
                       with: .color(rim.opacity(0.5)), lineWidth: 10.1 * s)
        }
        // The double rule: the dirham sign's two strokes.
        let ink = Color(HRGBA(0x8A, 0x5A, 0x05, 1))
        for y in [486.7, 552.9] as [CGFloat] {
          var bar = Path()
          bar.move(to: CGPoint(x: ox + (442.1 - 204) * s, y: oy + (y - 328) * s))
          bar.addLine(to: CGPoint(x: ox + (581.9 - 204) * s, y: oy + (y - 328) * s))
          layer.stroke(bar, with: .color(ink), style: StrokeStyle(lineWidth: 25.8 * s, lineCap: .round))
        }
      }
    }
    .accessibilityHidden(true)
  }
}

/// The Hasala app icon (Paper "Slot mark · tile"): the blue tile and the mark scaled 1.1
/// about the icon's centre. 24 on the "Read on this iPhone" chip, 32 in the story header,
/// 36 in "Who can see what", 56 on "Your invite is ready" (no ring, no lit lip).
struct AppIconTile: View {
  var size: CGFloat
  var radius: CGFloat
  var detailed = true

  var body: some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .fill(LinearGradient(
        colors: [Color(HRGBA(0x54, 0x79, 0xFF, 1)), Color(HRGBA(0x2B, 0x4A, 0xD2, 1))],
        startPoint: .topLeading, endPoint: UnitPoint(x: 0.4, y: 1)))
      .overlay(alignment: .topLeading) {
        // The 616 × 368 artwork at 1.1 inside the 1024 icon: x 16.9%…83.1%, y 30.2%…69.8%.
        SlotMark(plate: .onTile, detailed: detailed)
          .frame(width: size * 0.6617, height: size * 0.3953)
          .offset(x: size * 0.1691, y: size * 0.3023)
      }
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .accessibilityHidden(true)
  }
}

// MARK: - Small art parts

/// A hue disc in the art (Paper "HueDisc", "OrbitDisc"): the hue's 160° gradient and a line
/// icon in its ink, at the drawing's own size.
struct ArtDisc: View {
  var hue: Hue
  var icon: HIcon
  var size: CGFloat
  var iconSize: CGFloat

  var body: some View {
    Circle()
      .fill(hue.perceptualGradient)
      .overlay { HIconView(icon, size: iconSize, color: hue.ink, strokeWidth: 1.9) }
      .frame(width: size, height: size)
  }
}

/// The art's shadows (spec 04 §0), drawn behind a shape so they never stack on each other.
enum ArtShadow {
  /// `0 1 2 sky-ink 8%, 0 18 40 sky-ink 16%`: the hero cards.
  case hero
  /// `0 1 2 black 4%, 0 10 24 sky-ink 12%`: cards and discs that float.
  case float
  /// `0 1 2 black 4%, 0 6 16 sky-ink 8%`: chips.
  case chip
  /// `0 1 2 sky-ink 8%, 0 6 14 sky-ink 14%`: the "Read on this iPhone" chip.
  case chipLift

  var near: (color: Color, radius: CGFloat, y: CGFloat) {
    switch self {
    case .hero, .chipLift: (HColor.hueSkyInk.opacity(0.08), 1, 1)
    case .float, .chip: (Color.black.opacity(0.04), 1, 1)
    }
  }

  var far: (color: Color, radius: CGFloat, y: CGFloat) {
    switch self {
    case .hero: (HColor.hueSkyInk.opacity(0.16), 20, 18)
    case .float: (HColor.hueSkyInk.opacity(0.12), 12, 10)
    case .chip: (HColor.hueSkyInk.opacity(0.08), 8, 6)
    case .chipLift: (HColor.hueSkyInk.opacity(0.14), 7, 6)
    }
  }
}

extension View {
  /// A filled shape with one of the art's two-part shadows behind the content.
  func artCard<S: Shape>(_ shape: S, fill: Color = HColor.surfacePrimary, shadow: ArtShadow) -> some View {
    background {
      ZStack {
        shape.fill(fill).shadow(color: shadow.far.color, radius: shadow.far.radius, y: shadow.far.y)
        shape.fill(fill).shadow(color: shadow.near.color, radius: shadow.near.radius, y: shadow.near.y)
      }
    }
  }
}

extension Font {
  /// A face at a fixed size: the art is a drawing, not text that grows with Dynamic Type.
  static func artInter(_ size: CGFloat, _ weight: HWeight) -> Font {
    .custom(weight.interFace, fixedSize: size)
  }

  static func artRounded(_ size: CGFloat, _ weight: Font.Weight) -> Font {
    .system(size: size, weight: weight, design: .rounded)
  }
}
