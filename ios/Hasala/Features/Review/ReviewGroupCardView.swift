import HasalaDesign
import HasalaModels
import SwiftUI

struct ReviewGroupCardView<Actions: View>: View {
  let group: ReviewGroupCardModel
  let hidden: Bool
  let lean: ReviewChoice?
  let leanEdge: SwipeEdge?
  let strength: Double
  var note: RejectedNote? = nil
  var useAll: () -> Void = {}
  var notThis: () -> Void = {}
  var undoNote: () -> Void = {}
  @ViewBuilder let actions: () -> Actions
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        identity
        Spacer(minLength: 24)
        amount
      }
      .padding(.top, 24)
      .padding(.horizontal, 24)
      .padding(.bottom, 22)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(group.spoken(hidden: hidden))
      .accessibilityActions { actions() }
      .accessibilityIdentifier("review.card.group.\(group.id)")
      if let line = group.leftOutLine { leftOut(line) }
      if let note {
        ReviewNoteStrip(note: note, undo: undoNote)
      } else if let s = group.suggestion {
        strip(s)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(HColor.surfacePrimary)
    .overlay { ReviewGlow(lean: lean, edge: leanEdge, strength: strength) }
    .clipShape(RoundedRectangle(cornerRadius: HRadius.reviewCard, style: .continuous))
    .background {
      RoundedRectangle(cornerRadius: HRadius.reviewCard, style: .continuous)
        .fill(HColor.surfacePrimary)
        .shadow(color: .black.opacity(0.04), radius: 2, y: 2)
        .shadow(color: .black.opacity(0.11), radius: 22, y: 18)
        .shadow(color: (lean?.pillHue.end ?? .clear).opacity(0.9 * strength), radius: 20,
                x: ReviewGlow.shift(leanEdge).width, y: ReviewGlow.shift(leanEdge).height)
    }
  }

  private var identity: some View {
    VStack(alignment: .leading, spacing: 0) {
      let chipRow = Group {
        if group.repeatsMonthly {
          InfoChip("Repeats monthly", style: .suggested)
            .accessibilityIdentifier("review.repeatsMonthly")
        } else if group.isNewMerchant {
          InfoChip("New merchant", style: .reason)
        }
      }
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) {
          MerchantMonogram(letter: group.monogram, size: 56)
          chipRow
        }
      } else {
        HStack(alignment: .top) {
          MerchantMonogram(letter: group.monogram, size: 56)
          Spacer(minLength: 8)
          chipRow
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(group.merchant)
          .hType(.section)
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        if let chip = group.spellingChip {
          InfoChip(chip, style: .rawText)
        }
      }
      .padding(.top, 16)
    }
  }

  private var amount: some View {
    VStack(alignment: .leading, spacing: 4) {
      if group.totals.count >= 2, let estimate = group.estimate {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(Money.home).hFigure(.unit).foregroundStyle(HColor.textPrimary)
          Text("≈").hFigure(.hero).foregroundStyle(HColor.moneyOut)
          MoneyText(estimate.money, figure: .hero, hidden: hidden, color: group.isIncome ? HColor.moneyIn : HColor.moneyOut)
        }
        .accessibilityElement(children: .combine)
      } else if let m = group.totals.first {
        MoneyText(m, figure: .hero, unit: .unit, hidden: hidden,
                  color: group.isIncome ? HColor.moneyIn : HColor.moneyOut,
                  unitColor: group.isIncome ? HColor.moneyIn : HColor.textPrimary, unitGap: 6,
                  sign: group.isIncome ? .income : .none)
      }
      Text(group.fullMetaLine).hType(.footnote).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if let breakdown = group.estimateBreakdown {
        PhraseText(breakdown, hidden: hidden)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func leftOut(_ line: String) -> some View {
    let text = Text(line)
      .hType(.footnote.weight(.medium))
      .foregroundStyle(HColor.statusWarningForeground)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    let shield = HIconView(.shield, size: 16, color: HColor.statusWarningForeground, strokeWidth: 2)
    return Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          shield
          text
        }
      } else {
        HStack(alignment: .top, spacing: 10) {
          shield
          text
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.leading, 24)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.statusWarningSurface)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("review.card.leftOut")
  }

  private func strip(_ s: CategoryOption) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        CategoryDisc(hue: s.hue, icon: s.glyph.icon, size: .s32)
        VStack(alignment: .leading, spacing: 2) {
          Text("Looks like \(s.name)")
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
          if let by = group.suggestedBy {
            Text(by)
              .hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("review.suggestedBy")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)
      let notThisButton = Button("Not this", action: notThis)
        .buttonStyle(.pill(.secondary, size: .small, fill: true))
        .accessibilityLabel("Not this")
        .accessibilityIdentifier("review.strip.notThis")
      let useButton = Button(group.useAllLabel, action: useAll)
        .buttonStyle(.pill(.primary, size: .small, fill: true))
        .accessibilityLabel(group.useAllSpoken(s.name))
        .accessibilityIdentifier("review.strip.use")
      if typeSize.isAccessibilitySize {
        VStack(spacing: 10) {
          useButton
          notThisButton
        }
      } else {
        HStack(spacing: 10) {
          notThisButton
          useButton
        }
      }
    }
    .padding(.top, 14)
    .padding(.bottom, 14)
    .padding(.leading, 24)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.reviewSuggestionSurface)
    .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
  }
}

extension ReviewGroupCardView where Actions == EmptyView {
  init(group: ReviewGroupCardModel, hidden: Bool) {
    self.init(group: group, hidden: hidden, lean: nil, leanEdge: nil, strength: 0, actions: { EmptyView() })
  }
}

struct ReviewNoteStrip: View {
  let note: RejectedNote
  let undo: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Circle().fill(HColor.surfacePrimary).frame(width: 32, height: 32)
        .overlay { HIconView(.minus, size: 16, color: HColor.iconSecondary, strokeWidth: 2) }
        .accessibilityHidden(true)
      Text(note.line)
        .hType(.subheadline)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("review.notThis.note")
      if note.undo != nil {
        Button(action: undo) {
          Text("Undo")
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review.notThis.undo")
      }
    }
    .padding(.vertical, 10)
    .padding(.leading, 24)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.reviewSuggestionSurface)
    .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
  }
}

struct ReviewGlow: View {
  let lean: ReviewChoice?
  let edge: SwipeEdge?
  let strength: Double

  var body: some View {
    if let lean, let edge, strength > 0 {
      let hue = lean.pillHue
      let stops = Gradient(stops: [
        .init(color: hue.end.opacity(0.58), location: 0),
        .init(color: hue.start.opacity(0.26), location: 0.5),
        .init(color: hue.start.opacity(0), location: 1),
      ])
      let (from, to, alignment): (UnitPoint, UnitPoint, Alignment) = switch edge {
      case .right: (.trailing, .leading, .trailing)
      case .left: (.leading, .trailing, .leading)
      case .up: (.top, .bottom, .top)
      case .down: (.bottom, .top, .bottom)
      }
      let horizontal = edge == .left || edge == .right
      Rectangle().fill(.linearGradient(stops.colorSpace(.perceptual), startPoint: from, endPoint: to))
        .frame(width: horizontal ? 170 : nil, height: horizontal ? nil : 170)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .opacity(strength)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  static func shift(_ edge: SwipeEdge?) -> CGSize {
    switch edge {
    case .right: CGSize(width: 18, height: 4)
    case .left: CGSize(width: -18, height: 4)
    case .up: CGSize(width: 0, height: -14)
    case .down: CGSize(width: 0, height: 22)
    case nil: .zero
    }
  }
}

struct SortResultRowView: View {
  let row: SortResultRow
  let undo: () -> Void
  let stopRule: () -> Void
  let dismiss: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Circle().fill(HColor.statusSuccessSurface).frame(width: 32, height: 32)
        .overlay { HIconView(.check, size: 16, color: HColor.statusSuccessForeground, strokeWidth: 2.2) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.line)
          .hType(.subheadline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        if let detail = row.detail {
          Text(detail)
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        let links = Group {
          if row.undo != nil { link("Undo", id: "review.result.undo", action: undo) }
          if row.canStopRule { link("Stop this rule", id: "review.result.stopRule", action: stopRule) }
        }
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 0) { links }
        } else {
          HStack(spacing: 16) { links }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: dismiss) {
        HIconView(.close, size: 14, color: HColor.iconSecondary, strokeWidth: 2)
          .frame(width: 36, height: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
      .accessibilityIdentifier("review.result.dismiss")
    }
    .padding(.vertical, 12)
    .padding(.leading, 16)
    .padding(.trailing, 8)
    .background {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(HColor.widgetSurface)
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(row.spoken)
    .accessibilityIdentifier("review.result")
  }

  private func link(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textLink)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }
}
