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

/// A brief card on the Needs-you rail (Paper "kit Brief card"): a hue poster (at least 120 pt)
/// over a white body with a primary and a "Later"-style secondary button. 272 wide; full width,
/// with stacked buttons, at the accessibility text sizes (spec 04 §17).
public struct BriefCard: View {
  let card: NeedsYouCard
  let hidden: Bool
  let onPrimary: () -> Void
  let onSecondary: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize
  private var accessibilityLayout: Bool { typeSize.isAccessibilitySize }

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
          Text(card.title).hType(.headline).foregroundStyle(HColor.textPrimary).singleLineAtDefaultTextSize()
          Text(card.subtitle.rendered(hidden: hidden))
            .hType(.subheadline).foregroundStyle(HColor.textSecondary).singleLineAtDefaultTextSize()
            .accessibilityLabel(card.subtitle.spoken(hidden: hidden))
        }
        if accessibilityLayout {
          VStack(spacing: 8) {
            Button(card.primaryAction, action: onPrimary)
              .buttonStyle(.pill(.primary, size: .medium, fill: true))
            Button(card.secondaryAction, action: onSecondary)
              .buttonStyle(.pill(.secondary, size: .medium, fill: true))
          }
        } else {
          HStack(spacing: 8) {
            Button(card.primaryAction, action: onPrimary)
              .buttonStyle(.pill(.primary, size: .medium, fill: true))
              .layoutPriority(1)
            Button(card.secondaryAction, action: onSecondary)
              .buttonStyle(.pill(.secondary, size: .medium, fill: true))
              .frame(width: 88)
          }
        }
      }
      .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
    }
    .frame(width: accessibilityLayout ? nil : HContainer.briefCard)
    .frame(maxWidth: accessibilityLayout ? .infinity : nil)
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .elevation()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("needsYou.\(card.id)")
  }

  private var poster: some View {
    VStack(alignment: .leading) {
      ReflowingRow(spacing: 6) {
        posterLabel
      } trailing: {
        StatusPillView(card.status)
      }
      Spacer(minLength: 8)
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
    // At least 120 pt; taller when the text needs it. fixedSize settles the height
    // first, so the spacer still pushes the figure to the bottom.
    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
    .fixedSize(horizontal: false, vertical: true)
    .background(card.hue.gradient)
  }

  private var posterLabel: some View {
    HStack(spacing: 8) {
      Circle().fill(HColor.posterGlyph).frame(width: 32, height: 32)
        .overlay {
          Image(systemName: card.glyph.symbolName)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(card.hue.ink)
        }
        .accessibilityHidden(true)
      Text(card.label).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .singleLineAtDefaultTextSize()
    }
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
      Text(stat.label).hType(.footnote).foregroundStyle(HColor.textOnWashSecondary)
        .singleLineAtDefaultTextSize()
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
/// At the accessibility text sizes the amount moves under the detail (spec 04 §17).
public struct TxnRow: View {
  let row: MiniTxnRow
  let hidden: Bool
  let compact: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  /// `compact` is the 48 pt widget row (32 pt disc, 15/20 type); otherwise the 64 pt list row.
  public init(_ row: MiniTxnRow, hidden: Bool, compact: Bool = false) {
    self.row = row
    self.hidden = hidden
    self.compact = compact
  }

  public var body: some View {
    HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: HSpacing.listRowGap) {
      if let monogram = row.monogram {
        MonogramDisc(monogram, size: compact ? 32 : HSpacing.listRowLeadingDisc)
      } else {
        HueDisc(hue: row.hue, glyph: row.glyph, size: compact ? 32 : HSpacing.listRowLeadingDisc,
                iconSize: compact ? 16 : 20)
      }
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 6) {
          if row.toReview {
            Circle().fill(HColor.actionAccent).frame(width: 8, height: 8).accessibilityHidden(true)
          }
          Text(row.merchant).hType(compact ? .subheadline.weight(.semibold) : .rowTitle)
            .foregroundStyle(HColor.listRowTitle).singleLineAtDefaultTextSize()
        }
        Text(row.detail).font(.custom(HWeight.regular.interFace, size: 13, relativeTo: .footnote))
          .foregroundStyle(HColor.listRowSupporting).singleLineAtDefaultTextSize()
        if typeSize.isAccessibilitySize { amount }
      }
      if !typeSize.isAccessibilitySize {
        Spacer(minLength: 8)
        amount.fixedSize()
      }
    }
    .frame(maxWidth: .infinity, minHeight: compact ? 48 : HSpacing.listRowMinHeightTwoLine, alignment: .leading)
    // One element with one label: a nested amount element would be its own tiny target.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spokenLabel)
  }

  private var spokenLabel: String {
    let amount = hidden
      ? "Amount hidden"
      : (row.isIncome ? "plus " : "") + "\(row.amount.currency) \(MoneyFormat.string(row.amount.minor))"
    return [row.toReview ? "To review" : nil, row.merchant, row.detail, amount].compactMap { $0 }
      .joined(separator: ", ")
  }

  private var amount: some View {
    MoneyText(row.amount, figure: compact ? .compact : .row, hidden: hidden, hiddenGlyphs: 3,
              color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
  }
}

/// A grey disc with a merchant's first letter, for a merchant not sorted yet (Paper "L" for Lulu;
/// spec 04 §14.6 `MonogramDisc`).
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
      .frame(width: size, height: size)
      .overlay {
        Text(letter)
          .font(.custom(HWeight.semibold.interFace, size: size * 0.42))
          .foregroundStyle(HColor.textPrimary)
      }
      .accessibilityHidden(true)
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
