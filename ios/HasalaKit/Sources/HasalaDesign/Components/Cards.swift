import HasalaModels
import SwiftUI

// Content cards (white on the grouped canvas): brief cards, stat tiles, list cards.

public extension View {
  /// The two-layer card shadow Paper uses on brief cards (`--color-elevation-*`).
  func elevation() -> some View {
    shadow(color: HColor.elevationNear, radius: 1, x: 0, y: 1)
      .shadow(color: HColor.elevationFar, radius: 12, x: 0, y: 8)
  }

  /// A white list card, r24 (Paper "kit Lists and cards").
  func listCard() -> some View {
    background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}

/// A brief card on the Needs-you rail (Paper "kit Brief card"): a 120 pt hue poster over a
/// white body with a primary and a "Later"-style secondary button. 272 wide.
public struct BriefCard: View {
  let card: NeedsYouCard
  let hidden: Bool
  let onPrimary: () -> Void
  let onSecondary: () -> Void

  public init(
    _ card: NeedsYouCard, hidden: Bool, onPrimary: @escaping () -> Void = {}, onSecondary: @escaping () -> Void = {}
  ) {
    self.card = card
    self.hidden = hidden
    self.onPrimary = onPrimary
    self.onSecondary = onSecondary
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      poster
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(card.title).hType(.headline).foregroundStyle(HColor.textPrimary).lineLimit(1)
          Text(card.subtitle.rendered(hidden: hidden))
            .hType(.subheadline).foregroundStyle(HColor.textSecondary).lineLimit(1)
            .accessibilityLabel(card.subtitle.spoken(hidden: hidden))
        }
        HStack(spacing: 8) {
          Button(card.primaryAction, action: onPrimary)
            .buttonStyle(.pill(.primary, size: .medium, fill: true))
            .layoutPriority(1)
          Button(card.secondaryAction, action: onSecondary)
            .buttonStyle(.pill(.secondary, size: .medium, fill: true))
            .frame(width: 88)
        }
      }
      .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
    }
    .frame(width: HContainer.briefCard)
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .elevation()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("needsYou.\(card.id)")
  }

  private var poster: some View {
    VStack(alignment: .leading) {
      HStack {
        HStack(spacing: 8) {
          Circle().fill(HColor.posterGlyph).frame(width: 32, height: 32)
            .overlay {
              Image(systemName: card.glyph.symbolName)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(card.hue.ink)
            }
            .accessibilityHidden(true)
          Text(card.label).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary).lineLimit(1)
        }
        Spacer(minLength: 6)
        StatusPillView(card.status)
      }
      Spacer(minLength: 0)
      switch card.figure {
      case .count(let n, let unit):
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("\(n)").hFigure(.large).foregroundStyle(HColor.textPrimary)
          Text(unit).hFigure(.unit).foregroundStyle(HColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
      case .money(let m):
        MoneyText(m, figure: .large, unit: .unit, hidden: hidden, hiddenGlyphs: 3, color: HColor.textPrimary,
                  unitGap: 5)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(height: 120)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(card.hue.gradient)
  }
}

/// A translucent stat tile on the hero wash: label over a rounded figure.
public struct StatTile: View {
  let stat: HeroStat
  let hidden: Bool

  public init(_ stat: HeroStat, hidden: Bool) {
    self.stat = stat
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(stat.label).hType(.footnote).foregroundStyle(HColor.textOnWashSecondary).lineLimit(1)
      MoneyText(stat.value, figure: HFigure.unit.weight(.bold), hidden: hidden, color: HColor.textPrimary)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// A two-line transaction row (Paper "kit Lists and cards"): disc, title over detail, trailing amount.
public struct TxnRow: View {
  let row: MiniTxnRow
  let hidden: Bool
  let compact: Bool

  /// `compact` is the 48 pt widget row (32 pt disc, 15/20 type); otherwise the 64 pt list row.
  public init(_ row: MiniTxnRow, hidden: Bool, compact: Bool = false) {
    self.row = row
    self.hidden = hidden
    self.compact = compact
  }

  public var body: some View {
    HStack(spacing: HSpacing.listRowGap) {
      HueDisc(hue: row.hue, glyph: row.glyph, size: compact ? 32 : HSpacing.listRowLeadingDisc,
              iconSize: compact ? 16 : 20)
      VStack(alignment: .leading, spacing: 0) {
        Text(row.merchant).hType(compact ? .subheadline.weight(.semibold) : .rowTitle)
          .foregroundStyle(HColor.listRowTitle).lineLimit(1)
        Text(row.detail).font(.custom(HWeight.regular.interFace, size: 13, relativeTo: .footnote))
          .foregroundStyle(HColor.listRowSupporting).lineLimit(1)
      }
      Spacer(minLength: 8)
      MoneyText(row.amount, figure: compact ? .compact : .row, hidden: hidden, hiddenGlyphs: 3,
                color: row.isIncome ? HColor.moneyIn : HColor.moneyOut)
        .fixedSize()
    }
    .frame(minHeight: compact ? 48 : HSpacing.listRowMinHeightTwoLine)
    .accessibilityElement(children: .combine)
  }
}

/// A screen-level placeholder for areas that are not built yet.
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
