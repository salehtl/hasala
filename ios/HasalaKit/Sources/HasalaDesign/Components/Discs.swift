import HasalaModels
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

// Discs and plates (page 16 §03, page 15 §01): a round hue disc with a line icon names a
// category; a grey monogram stands in for a merchant with no category yet; a rounded-square
// plate is a bank, so a bank never reads as a category. All decorative: the row names them.

/// A category disc: the bucket's 160° gradient with its ink icon at half the disc. Three sizes:
/// 32 (the review suggestion strip, 16 pt icon at 2.0), 40 (rows, 20 at 1.9), 56 (detail heroes
/// and the review card, 28 at 1.7). `ring` adds the 3 pt white ring a hero disc wears.
public struct CategoryDisc: View {
  public enum Size: Sendable {
    case s32, s40, s56

    public var side: CGFloat {
      switch self {
      case .s32: 32
      case .s40: HSpacing.listRowLeadingDisc
      case .s56: 56
      }
    }
  }

  let hue: Hue
  let icon: HIcon
  let size: Size
  let ring: Bool

  public init(hue: Hue, icon: HIcon, size: Size = .s40, ring: Bool = false) {
    self.hue = hue
    self.icon = icon
    self.size = size
    self.ring = ring
  }

  public init(hue: Hue, glyph: Glyph, size: Size = .s40, ring: Bool = false) {
    self.init(hue: hue, icon: glyph.icon, size: size, ring: ring)
  }

  public var body: some View {
    Circle()
      .fill(hue.perceptualGradient)
      .frame(width: size.side, height: size.side)
      .overlay { HIconView(icon, size: size.side / 2, color: hue.ink) }
      .background { if ring { Circle().fill(HColor.white).padding(-3) } }
      .accessibilityHidden(true)
  }
}

/// A gradient disc with a glyph in the hue's ink, at any size (the original API; it now draws
/// the custom icons of page 05).
public struct HueDisc: View {
  let hue: Hue
  let glyph: Glyph
  let size: CGFloat
  let iconSize: CGFloat

  public init(hue: Hue, glyph: Glyph, size: CGFloat = HSpacing.listRowLeadingDisc, iconSize: CGFloat? = nil) {
    self.hue = hue
    self.glyph = glyph
    self.size = size
    self.iconSize = iconSize ?? (size / 2).rounded()
  }

  public var body: some View {
    Circle()
      .fill(hue.perceptualGradient)
      .frame(width: size, height: size)
      .overlay { HIconView(glyph.icon, size: iconSize, color: hue.ink) }
      .accessibilityHidden(true)
  }
}

/// A grey disc with a merchant's first letter, for a merchant not sorted yet (Paper "L" for
/// Lulu): `--color-list-row-monogram` with a 1 pt inset `--color-border-subtle` ring, the letter
/// 17/22 600 at 40 and 24/28 at 56. No hue: there is no bucket yet.
public struct MonogramDisc: View {
  let letter: String
  let size: CGFloat

  public init(_ letter: String, size: CGFloat = HSpacing.listRowLeadingDisc) {
    self.letter = letter
    self.size = size
  }

  public var body: some View {
    Circle()
      .fill(HColor.listRowMonogram)
      .overlay { Circle().strokeBorder(HColor.borderSubtle, lineWidth: 1) }
      .frame(width: size, height: size)
      .overlay {
        Text(letter)
          .font(.custom(HWeight.semibold.interFace, size: size >= 56 ? 24 : size * 17 / 40))
          .foregroundStyle(HColor.textPrimary)
      }
      .accessibilityHidden(true)
  }
}

/// A bank's plate: a 40 pt rounded square (radius 12) in a hue, with its initials in the hue's
/// ink ("ENBD", "DIB"). One line always: a four-letter code too wide for the plate is drawn a
/// little smaller rather than wrapped (Paper's own drift note on "ENBD").
///
/// The initials are a picture of the bank's mark, drawn in a canvas, not set as text: the
/// plate keeps its size at every text size, as the glyph plates do, and a shrunk text node
/// inside it read as "Dynamic Type partially unsupported" to the accessibility audit even in a
/// row that hides it (requests/p8.md 1). The row beside it names the bank in text that grows.
public struct BankPlate: View {
  let initials: String
  let hue: Hue

  public init(initials: String, hue: Hue) {
    self.initials = initials
    self.hue = hue
  }

  public var body: some View {
    let long = initials.count > 3
    let mark = Text(verbatim: initials)
      .font(.custom(HWeight.bold.interFace, fixedSize: long ? 11 : 12))
      .tracking(long ? -0.2 : 0.2)
      .foregroundStyle(hue.ink)
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(hue.perceptualGradient)
      .frame(width: 40, height: 40)
      .overlay {
        Canvas { context, size in
          let text = context.resolve(mark)
          // 3 pt clear on each side, as the text had.
          let room = size.width - 6
          let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: size.height))
          let scale = measured.width > room ? room / measured.width : 1
          context.translateBy(x: size.width / 2, y: size.height / 2)
          context.scaleBy(x: scale, y: scale)
          context.draw(text, at: .zero, anchor: .center)
        }
      }
      .accessibilityHidden(true)
  }
}

/// A glyph on a translucent white plate, on a hue poster or card (brief card 32 with an 18 icon,
/// project card 40 with a 20 icon, recap tiles 28). The plate is `--color-poster-glyph`.
public struct GlyphPlate: View {
  let icon: HIcon
  let hue: Hue
  let size: CGFloat

  public init(icon: HIcon, hue: Hue, size: CGFloat = 32) {
    self.icon = icon
    self.hue = hue
    self.size = size
  }

  public var body: some View {
    Circle()
      .fill(HColor.posterGlyph)
      .frame(width: size, height: size)
      .overlay {
        HIconView(icon, size: size <= 32 ? (size * 18 / 32).rounded() : size / 2, color: hue.ink,
                  strokeWidth: size <= 32 ? 2 : nil)
      }
      .accessibilityHidden(true)
  }
}

/// The gradient avatar with the person's initial: 36 in the header glass, 96 on Your profile
/// (with a 4 pt white ring and the far shadow).
public struct AvatarDisc: View {
  let initial: String
  let size: CGFloat
  let ring: Bool
  let email: String?

  @Environment(\.avatarPictures) private var pictures
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var picture: AvatarPicture?

  public init(initial: String, size: CGFloat = 36, ring: Bool = false, email: String? = nil) {
    self.initial = initial
    self.size = size
    self.ring = ring
    self.email = email
  }

  private var pixels: Int { max(1, Int((size * displayScale).rounded(.up))) }

  public var body: some View {
    Circle()
      .fill(
        // Paper: linear-gradient(in oklab 145deg, oklab(82.1% .042 .111) 0%, oklab(75.6% .086 .050) 55%,
        // oklab(59.2% .064 −.100) 100%); converted, as no token holds an avatar gradient.
        LinearGradient(
          gradient: Gradient(stops: [
            .init(color: Color(HRGBA(246, 182, 107, 1)), location: 0),
            .init(color: Color(HRGBA(232, 152, 138, 1)), location: 0.55),
            .init(color: Color(HRGBA(140, 107, 184, 1)), location: 1),
          ]),
          startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)
        )
      )
      .frame(width: size, height: size)
      .overlay {
        Text(initial)
          .font(.custom(HWeight.bold.interFace, fixedSize: size <= 48 ? size * 16 / 36 : size * 40 / 96))
          .foregroundStyle(Color(HRGBA(42, 31, 61, 1)))
      }
      .overlay {
        if let picture {
          picture.image
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .transition(.opacity)
        }
      }
      .task(id: AvatarKey(email: email, pixels: pixels, enabled: pictures != nil)) {
        guard let pictures, let email, !email.isEmpty else {
          picture = nil
          return
        }
        let data = await pictures.load(email, pixels)
        guard !Task.isCancelled else { return }
        let loaded = data.flatMap(AvatarPicture.init(data:))
        if reduceMotion {
          picture = loaded
        } else {
          withAnimation(.easeOut(duration: 0.2)) { picture = loaded }
        }
      }
      .background { if ring { Circle().fill(HColor.white).padding(-4) } }
      .shadow(color: ring ? HColor.elevationFar : .clear, radius: 12, x: 0, y: 8)
      .accessibilityHidden(true)
  }
}

private struct AvatarKey: Hashable {
  let email: String?
  let pixels: Int
  let enabled: Bool
}

struct AvatarPicture {
  let image: Image

  init?(data: Data) {
    #if canImport(UIKit)
      guard let ui = UIImage(data: data) else { return nil }
      image = Image(uiImage: ui)
    #else
      return nil
    #endif
  }
}

public struct AvatarPictureProvider: Sendable {
  public var load: @Sendable (_ email: String, _ pixels: Int) async -> Data?

  public init(load: @escaping @Sendable (_ email: String, _ pixels: Int) async -> Data?) {
    self.load = load
  }
}

public extension EnvironmentValues {
  @Entry var avatarPictures: AvatarPictureProvider? = nil
}
