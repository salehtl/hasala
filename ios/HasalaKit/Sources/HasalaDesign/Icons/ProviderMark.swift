import HasalaModels
import SwiftUI

/// A mail provider's mark in its own colours (page 15 · Mailboxes, page 05): the Google "G" and
/// the Microsoft four squares, never recoloured, outlined or tinted, and never a generic mail
/// icon. Microsoft covers Outlook.com, Hotmail, Live and Microsoft 365, so there is no separate
/// Outlook mark.
public struct ProviderMark: View {
  public enum Size: Sendable, Hashable {
    /// The 40 pt white tile, radius 12, with a 1 pt `borderSubtle` outline (mailbox rows,
    /// Choose your email).
    case tile40
    /// The 26 pt white disc inside a provider button.
    case disc26
    /// The 64 pt tile, radius 18, at the top of a mailbox detail.
    case large64

    var side: CGFloat {
      switch self {
      case .tile40: 40
      case .disc26: 26
      case .large64: 64
      }
    }

    func mark(_ provider: MailProviderKind) -> CGFloat {
      switch (self, provider) {
      case (.tile40, .gmail): 20
      case (.tile40, .outlook): 18
      case (.disc26, .gmail): 15
      case (.disc26, .outlook): 13
      case (.large64, _): 28
      }
    }
  }

  let provider: MailProviderKind
  let size: Size
  let faded: Bool

  /// `faded` draws a disconnected mailbox's plate at half opacity.
  public init(_ provider: MailProviderKind, size: Size = .tile40, faded: Bool = false) {
    self.provider = provider
    self.size = size
    self.faded = faded
  }

  public var body: some View {
    let icon: HIcon = provider == .gmail ? .google : .microsoft
    let mark = HIconView(icon, size: size.mark(provider))
    Group {
      switch size {
      case .disc26:
        mark.frame(width: size.side, height: size.side).background(HColor.white, in: Circle())
      case .tile40, .large64:
        let shape = RoundedRectangle(cornerRadius: size == .tile40 ? 12 : 18, style: .continuous)
        mark.frame(width: size.side, height: size.side)
          .background(HColor.white, in: shape)
          .overlay { shape.strokeBorder(HColor.borderSubtle, lineWidth: 1) }
      }
    }
    .opacity(faded ? 0.5 : 1)
    .accessibilityHidden(true)
  }
}

/// The Hasala mark: a dirham going into the slot (page B1). Drawn from the brand artwork's own
/// geometry (`HasalaMark.svg`, viewBox 616 × 368), never rebuilt from icon parts. Used where the
/// design shows the coin-on-tray: "You're set", the recap source row.
public struct HasalaMark: View {
  public init() {}

  public var body: some View {
    Canvas { context, size in
      // The artwork's own units; one scale keeps its 616 × 368 shape inside the frame.
      let s = min(size.width / 616, size.height / 368)
      let ox = (size.width - 616 * s) / 2, oy = (size.height - 368 * s) / 2
      func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: ox + (x - 204) * s, y: oy + (y - 328) * s, width: w * s, height: h * s)
      }
      func capsule(_ rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: rect.height / 2) }
      let navy = Color(HPalette.blue950)
      // The plate around the slot, then the slot and its lit lower lip.
      context.fill(capsule(r(212, 576, 600, 112)), with: .color(navy.opacity(0.12)))
      context.fill(capsule(r(244, 600, 536, 64)), with: .color(navy))
      context.fill(capsule(r(268, 648, 488, 10)), with: .color(.white.opacity(0.22)))
      // The coin, halfway in: everything below the slot's centre line is cut away.
      var coin = context
      coin.clip(to: Path(r(0, 0, 1024, 632)))
      let rim = Color(HRGBA(0xC9, 0x8A, 0x1E, 1))
      coin.fill(Path(ellipseIn: r(512 - 184, 538.2 - 184, 368, 368)), with: .color(rim))
      let face = Path(ellipseIn: r(512 - 184, 519.8 - 184, 368, 368))
      let faceRect = r(512 - 184, 519.8 - 184, 368, 368)
      coin.fill(face, with: .linearGradient(
        Gradient(colors: [Color(HRGBA(0xF9, 0xDC, 0x94, 1)), Color(HRGBA(0xEB, 0xB0, 0x4A, 1))]),
        startPoint: CGPoint(x: faceRect.midX, y: faceRect.minY), endPoint: CGPoint(x: faceRect.midX, y: faceRect.maxY)))
      coin.stroke(Path(ellipseIn: r(512 - 139.8, 519.8 - 139.8, 279.6, 279.6)),
                  with: .color(rim.opacity(0.5)), lineWidth: 10.1 * s)
      // The double rule: the dirham sign's two strokes.
      let ink = Color(HRGBA(0x8A, 0x5A, 0x05, 1))
      for y in [486.7, 552.9] as [CGFloat] {
        var bar = Path()
        bar.move(to: CGPoint(x: ox + (442.1 - 204) * s, y: oy + (y - 328) * s))
        bar.addLine(to: CGPoint(x: ox + (581.9 - 204) * s, y: oy + (y - 328) * s))
        coin.stroke(bar, with: .color(ink), style: StrokeStyle(lineWidth: 25.8 * s, lineCap: .round))
      }
    }
    .aspectRatio(616 / 368, contentMode: .fit)
    .accessibilityHidden(true)
  }
}
