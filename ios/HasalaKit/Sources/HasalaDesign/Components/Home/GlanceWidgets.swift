import HasalaModels
import SwiftUI

extension HFigure {
  static let widgetRowTotal = HFigure(size: 17, leading: 22, weight: .bold, textStyle: .body)
  static let widgetRowUnit = HFigure(size: 13, leading: 18, weight: .semibold, textStyle: .footnote)
}

private struct InkDisc: View {
  let icon: HIcon
  var body: some View {
    Circle().fill(Color(HRGBA(255, 255, 255, 0.12))).frame(width: 34, height: 34)
      .overlay { HIconView(icon, size: 18, color: HColor.widgetOnInverse, strokeWidth: 2) }
      .accessibilityHidden(true)
  }
}

public extension Verdict? {
  var onInkColor: Color {
    switch self {
    case .onTrack?, .done?: HColor.green300
    case .overPace?: HColor.amber300
    case .overBudget?: HColor.red300
    case nil: HColor.widgetOnInverseSecondary
    }
  }
}

public struct SpentSoFarWidgetView: View {
  let model: SpentSoFarWidget
  let hidden: Bool

  public init(_ model: SpentSoFarWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack(spacing: 8) {
        InkDisc(icon: .gauge)
        Text("Spent so far").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.widgetOnInverseSecondary)
          .singleLineAtDefaultTextSize()
      }
      .frame(minHeight: 34)
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          MoneyText(model.spent, figure: .widget, style: .rounded, hidden: hidden, hiddenGlyphs: 6, hiddenDots: 24,
                    color: HColor.widgetOnInverse, sign: model.spent.isNegative ? .debt : .none)
          HStack(spacing: 6) {
            Circle().fill(model.verdict.onInkColor).frame(width: 7, height: 7)
            Text(model.caption.rendered(hidden: hidden)).privacySensitive()
              .hType(.footnote.weight(.semibold)).foregroundStyle(model.verdict.onInkColor)
              .singleLineAtDefaultTextSize()
              .accessibilityLabel(model.caption.spoken(hidden: hidden))
          }
        }
        WidgetPaceBar(spent: model.progress, tick: model.tick, verdict: model.verdict ?? .onTrack, inverse: true)
      }
    }
    .smallWidget()
    .smallWidgetChrome(HColor.widgetSurfaceInverse, trailing: 14)
    .accessibilityElement(children: .combine)
  }
}

public struct CategoryWatchWidgetView: View {
  let model: CategoryWatchWidget
  let hidden: Bool

  public init(_ model: CategoryWatchWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  private var figureColor: Color { model.isOver ? HColor.paceOverBudget : HColor.textPrimary }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack {
        HueDisc(hue: model.hue, glyph: model.glyph, size: 34, iconSize: 18)
        Spacer(minLength: 4)
        StatusPillView(StatusPill(model.verdict.label, tone: model.verdict.tone, showsDot: false), surface: .tinted)
      }
      .frame(minHeight: 34)
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            MoneyText(Money(minor: abs(model.left.minor), currency: model.left.currency),
                      figure: .widget, style: .rounded, hidden: hidden, hiddenGlyphs: 4, hiddenDots: 24,
                      color: figureColor)
            Text(model.isOver ? "over" : "left").hFigure(.widgetUnit).foregroundStyle(figureColor)
          }
          Text(model.caption.rendered(hidden: hidden)).privacySensitive()
            .hType(.footnote).foregroundStyle(HColor.textSecondary)
            .lineLimitAtDefaultTextSize(2)
            .accessibilityLabel(model.caption.spoken(hidden: hidden))
        }
        WidgetPaceBar(spent: model.progress, tick: model.tick, verdict: model.verdict)
      }
    }
    .smallWidget()
    .smallWidgetChrome(HColor.widgetSurface, trailing: 14)
    .accessibilityElement(children: .combine)
  }
}

public struct ComingUpWidgetView: View {
  let model: ComingUpWidget
  let hidden: Bool

  public init(_ model: ComingUpWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline) {
        Text(model.title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .singleLineAtDefaultTextSize()
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        MoneyText(model.total, figure: .widgetRowTotal, unit: .widgetRowUnit, style: .rounded, hidden: hidden,
                  hiddenGlyphs: 6, color: HColor.textPrimary, unitColor: HColor.textSecondary, unitGap: 4)
          .fixedSize()
      }
      .padding(.bottom, model.mark?.caption == nil ? 6 : 0)
      if let caption = model.mark?.caption {
        Text(caption).hType(.footnote).foregroundStyle(HColor.textSecondary).lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.bottom, 6)
      }
      ForEach(model.rows) { row in
        ComingUpRowView(row: row, hidden: hidden)
      }
      Spacer(minLength: 0)
    }
    .widgetChrome(HColor.widgetSurface, padding: EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16),
                  minHeight: HContainer.widgetUnit)
    .accessibilityElement(children: .contain)
  }
}

struct ComingUpRowView: View {
  let row: ComingUpRow
  let hidden: Bool

  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(row.hue.perceptualGradient).frame(width: 28, height: 28)
        .overlay { HIconView(row.glyph.icon, size: 14, color: row.hue.ink, strokeWidth: 2.2) }
        .accessibilityHidden(true)
      Text(row.name).privacySensitive().hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      if row.late {
        HStack(spacing: 5) {
          Circle().fill(HColor.statusErrorForeground).frame(width: 6, height: 6)
          Text(row.note).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.statusErrorForeground)
            .lineLimit(2)
        }
      } else {
        Text(row.note).hType(.footnote).foregroundStyle(HColor.textSecondary).lineLimit(1)
      }
      MoneyText(row.amount, figure: .compact, style: .rounded, hidden: hidden, hiddenGlyphs: 3,
                color: row.isIncome ? HColor.moneyIn : HColor.textPrimary, sign: row.isIncome ? .income : .none)
        .frame(width: 76, alignment: .trailing)
    }
    .frame(minHeight: 36, maxHeight: 42)
    .accessibilityElement(children: .combine)
  }
}

public struct ToReviewWidgetView: View {
  let model: ToReviewWidget
  let hidden: Bool

  public init(_ model: ToReviewWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack(spacing: 8) {
        Circle().fill(HColor.posterGlyph).frame(width: 34, height: 34)
          .overlay { HIconView(.reviewSheet, size: 18, color: Hue.sky.ink, strokeWidth: 2) }
          .accessibilityHidden(true)
        Text("To review").hType(.footnote.weight(.semibold)).foregroundStyle(Hue.sky.ink)
          .singleLineAtDefaultTextSize()
      }
      .frame(minHeight: 34)
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(model.count)").hFigure(.hero).foregroundStyle(Hue.sky.ink)
            Text("to sort").hFigure(.widgetUnit).foregroundStyle(Hue.sky.ink)
          }
          Text(model.caption.rendered(hidden: hidden)).privacySensitive()
            .hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
            .singleLineAtDefaultTextSize()
            .accessibilityLabel(model.caption.spoken(hidden: hidden))
        }
        if model.count > 0 {
          Text("Start").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textOnAccent)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(HColor.actionAccent, in: Capsule())
            .accessibilityAddTraits(.isButton)
        }
      }
    }
    .smallWidget()
    .widgetChrome(Hue.sky.perceptualGradient, padding: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 12),
                  minHeight: HContainer.widgetUnit)
    .accessibilityElement(children: .combine)
  }
}

public struct WaitingWidgetView: View {
  let title: String
  let sentence: String

  public init(title: String, sentence: String = "Your first bank alert will fill this in.") {
    self.title = title
    self.sentence = sentence
  }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack(spacing: 8) {
        Circle().fill(HColor.white).frame(width: 34, height: 34)
          .overlay { HIconView(.envelope, size: 18, color: HColor.iconSecondary, strokeWidth: 2) }
          .accessibilityHidden(true)
        Text(title).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textSecondary)
          .singleLineAtDefaultTextSize()
      }
      .frame(minHeight: 34)
      Spacer(minLength: 0)
      Text(sentence).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .smallWidget()
    .smallWidgetChrome(HColor.widgetSurfaceWaiting, trailing: 14)
    .accessibilityElement(children: .combine)
  }
}
