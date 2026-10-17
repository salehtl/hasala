import HasalaModels
import SwiftUI

// Content cards (Paper page 15 §02): solid white, radius 24, on the grey canvas. Only cards that
// ask you to act get a shadow; glass is never used for content.

public extension View {
  /// The two-layer card shadow Paper uses on cards that stand alone (`--color-elevation-*`).
  func elevation() -> some View {
    hElevation(.nearFar)
  }

  /// A white list card, r24 (Paper "kit Lists and cards").
  func listCard() -> some View {
    background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}

/// A card that asks for a decision (page 15 · Brief card, page 16 §12): a hue poster with a
/// glyph plate, a label, a status pill and the figure, over a white body with a primary and a
/// secondary button, 44 tall. Bills stacks them full width (poster 104); the Core kit's 272 card
/// with a 120 poster is the first rail's, kept for its one remaining caller. At the
/// accessibility sizes the buttons stack, primary on top.
public struct BriefCard: View {
  public enum Poster: Sendable {
    /// 104 tall, padding 13/16, body 15/20 primary (Bills).
    case short104
    /// 120 tall, padding 14/16, a title 17/24 over a 15/20 secondary line.
    case tall120
  }

  let id: String?
  let hue: Hue
  let icon: HIcon
  let label: String
  let status: StatusPill
  let figure: PosterFigure
  let figureCaption: String?
  let title: String?
  let message: MoneyPhrase
  let primaryTitle: String
  let secondaryTitle: String
  let secondaryWidth: CGFloat
  let poster: Poster
  let width: CGFloat?
  let hidden: Bool
  let onPrimary: () -> Void
  let onSecondary: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize
  private var accessibilityLayout: Bool { typeSize.isAccessibilitySize }

  /// A decision card. `figureCaption` follows the figure in on-hue secondary ("every month");
  /// `title` is the tall poster's headline. Rose is for a bill that may be late only, sand for a
  /// price change, sky for a new bill.
  public init(
    hue: Hue, icon: HIcon, label: String, status: StatusPill, figure: PosterFigure, figureCaption: String? = nil,
    title: String? = nil, body: MoneyPhrase, primaryTitle: String, secondaryTitle: String,
    secondaryWidth: CGFloat = 128, poster: Poster = .short104, width: CGFloat? = nil, hidden: Bool,
    onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void
  ) {
    self.id = nil
    self.hue = hue
    self.icon = icon
    self.label = label
    self.status = status
    self.figure = figure
    self.figureCaption = figureCaption
    self.title = title
    self.message = body
    self.primaryTitle = primaryTitle
    self.secondaryTitle = secondaryTitle
    self.secondaryWidth = secondaryWidth
    self.poster = poster
    self.width = width
    self.hidden = hidden
    self.onPrimary = onPrimary
    self.onSecondary = onSecondary
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      posterView
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          if let title {
            Text(title).hType(.headline).foregroundStyle(HColor.textPrimary).singleLineAtDefaultTextSize()
          }
          Text(message.rendered(hidden: hidden))
            .hType(.subheadline)
            .foregroundStyle(title == nil ? HColor.textPrimary : HColor.textSecondary)
            // A title's line is one line at the default size; a body alone may take three.
            .lineLimitAtDefaultTextSize(title == nil ? 3 : 1)
            .accessibilityLabel(message.spoken(hidden: hidden))
        }
        buttons
      }
      .padding(EdgeInsets(top: poster == .tall120 ? 14 : 12, leading: 16, bottom: poster == .tall120 ? 16 : 14,
                          trailing: 16))
    }
    .frame(width: accessibilityLayout ? nil : width)
    .frame(maxWidth: accessibilityLayout || width == nil ? .infinity : nil)
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .hElevation(.nearFar)
    .accessibilityElement(children: .contain)
    .modifier(OptionalIdentifier(id: id))
  }

  @ViewBuilder private var buttons: some View {
    if accessibilityLayout {
      VStack(spacing: 8) {
        Button(primaryTitle, action: onPrimary).buttonStyle(.pill(.primary, size: .medium, fill: true))
        Button(secondaryTitle, action: onSecondary).buttonStyle(.pill(.secondary, size: .medium, fill: true))
      }
    } else {
      HStack(spacing: 8) {
        Button(primaryTitle, action: onPrimary)
          .buttonStyle(.pill(.primary, size: .medium, fill: true))
          .layoutPriority(1)
        Button(secondaryTitle, action: onSecondary)
          .buttonStyle(.pill(.secondary, size: .medium, fill: true))
          .frame(width: secondaryWidth)
      }
    }
  }

  private var posterView: some View {
    VStack(alignment: .leading) {
      ReflowingRow(spacing: 6) {
        HStack(spacing: 8) {
          GlyphPlate(icon: icon, hue: hue, size: 32)
          Text(label).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
            .singleLineAtDefaultTextSize()
        }
      } trailing: {
        StatusPillView(status)
      }
      Spacer(minLength: 8)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        figureView
        if let figureCaption {
          Text(figureCaption).hType(.body).foregroundStyle(HColor.textOnHueSecondary)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, poster == .tall120 ? 14 : 13)
    // At least the poster height; taller when the text needs it. fixedSize settles the height
    // first, so the spacer still pushes the figure to the bottom.
    .frame(maxWidth: .infinity, minHeight: poster == .tall120 ? 120 : 104, maxHeight: .infinity, alignment: .topLeading)
    .fixedSize(horizontal: false, vertical: true)
    .background(hue.perceptualGradient)
  }

  @ViewBuilder private var figureView: some View {
    switch figure {
    case .count(let n, let unit):
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\(n)").hFigure(.large).foregroundStyle(HColor.textPrimary)
        Text(unit).hFigure(.unit).foregroundStyle(HColor.textPrimary)
      }
      .accessibilityElement(children: .combine)
    case .money(let m):
      MoneyText(m, figure: .large, unit: .unit, hidden: hidden, hiddenGlyphs: 3, color: HColor.textPrimary,
                unitGap: 5)
    case .word(let w):
      Text(w).hFigure(.large).foregroundStyle(HColor.textPrimary)
    }
  }
}

struct OptionalIdentifier: ViewModifier {
  let id: String?

  func body(content: Content) -> some View {
    if let id { content.accessibilityIdentifier(id) } else { content }
  }
}

/// A screen-level placeholder for areas that are not built yet (Debug only).
public struct PlaceholderCard: View {
  let systemImage: String
  let title: String
  let message: String

  public init(systemImage: String, title: String, message: String) {
    self.systemImage = systemImage
    self.title = title
    self.message = message
  }

  public var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(HColor.iconAccent)
        .frame(width: 56, height: 56)
        .background(HColor.actionAccentSubtle, in: Circle())
      Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
      Text(message).hType(.subheadline).foregroundStyle(HColor.textSecondary).multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity)
    .listCard()
    .accessibilityElement(children: .combine)
  }
}
