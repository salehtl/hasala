import HasalaModels
import SwiftUI

extension HType {
  static let lockLabel = HType(size: 12, leading: 15, weight: .semibold, textStyle: .caption)
  static let lockCaption = HType(size: 12, leading: 15, weight: .regular, textStyle: .caption)
  static let lockRingCaption = HType(size: 10, leading: 12, weight: .semibold, textStyle: .caption2)
}

extension HFigure {
  static let lockValue = HFigure(size: 17, leading: 21, weight: .bold, textStyle: .headline, minimumScale: 0.7)
  static let lockRingValue = HFigure(size: 17, leading: 20, weight: .bold, textStyle: .headline, minimumScale: 0.6)
  static let lockCount = HFigure(size: 24, leading: 26, weight: .bold, textStyle: .title3, minimumScale: 0.6)
}

private let lockSecondary = Color.white.opacity(0.8)

public struct LockRing: View {
  let progress: Permille?

  public init(progress: Permille?) {
    self.progress = progress
  }

  public var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      let line = side * 5 / 72
      ZStack {
        Circle().stroke(Color.white.opacity(0.28), lineWidth: line)
        if let progress, progress.value > 0 {
          Circle().trim(from: 0, to: min(1, progress.fraction))
            .stroke(Color.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
      }
      .padding(side * 6 / 72)
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .accessibilityHidden(true)
  }
}

public struct LockSpentRingView: View {
  let model: SpentSoFarWidget?
  let showsAmounts: Bool

  public init(_ model: SpentSoFarWidget?, showsAmounts: Bool) {
    self.model = model
    self.showsAmounts = showsAmounts
  }

  public var body: some View {
    ZStack {
      LockRing(progress: model?.progress)
      center
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  @ViewBuilder private var center: some View {
    if let model {
      if showsAmounts {
        VStack(spacing: 0) {
          Text(MoneyFormat.short(model.spent.minor)).privacySensitive().hFigure(.lockRingValue)
            .foregroundStyle(Color.white)
          Text("spent").hType(.lockRingCaption).foregroundStyle(lockSecondary)
        }
      } else {
        VStack(spacing: 0) {
          if model.verdict == .onTrack || model.verdict == .done {
            HIconView(.check, size: 22, color: .white, strokeWidth: 3)
          }
          Text(Self.word(model.verdict)).hType(.lockRingCaption).foregroundStyle(lockSecondary)
            .multilineTextAlignment(.center)
        }
      }
    } else {
      HIconView(.envelope, size: 20, color: lockSecondary, strokeWidth: 2)
    }
  }

  static func word(_ verdict: Verdict?) -> String {
    switch verdict {
    case .onTrack?, .done?: "on track"
    case .overPace?: "over pace"
    case .overBudget?: "over plan"
    case nil: "no plan"
    }
  }

  private var spoken: String {
    guard let model else { return "Spent so far, your first bank alert will fill this in" }
    if showsAmounts {
      return "Spent so far, AED \(MoneyFormat.string(model.spent.minor, style: .rounded)), \(model.verdictWord)"
    }
    return "Spent so far, \(model.verdictWord)"
  }
}

public struct LockSpentMark: View {
  public init() {}

  public var body: some View {
    Canvas { context, size in
      let u = size.width / 30
      var dome = Path()
      dome.move(to: CGPoint(x: 6 * u, y: 14 * u))
      dome.addArc(center: CGPoint(x: 15 * u, y: 14 * u), radius: 9 * u, startAngle: .degrees(180),
                  endAngle: .degrees(0), clockwise: false)
      dome.closeSubpath()
      context.fill(dome, with: .color(.white))
      let bar = Path(roundedRect: CGRect(x: 2 * u, y: 15.5 * u, width: 26 * u, height: 5 * u), cornerRadius: 2.5 * u)
      context.fill(bar, with: .color(.white.opacity(0.7)))
    }
    .frame(width: 15, height: 11)
    .accessibilityHidden(true)
  }
}

public struct LockSpentRectView: View {
  let model: SpentSoFarWidget?
  let showsAmounts: Bool

  public init(_ model: SpentSoFarWidget?, showsAmounts: Bool) {
    self.model = model
    self.showsAmounts = showsAmounts
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 5) {
        LockSpentMark()
        Text("Spent so far").hType(.lockLabel).foregroundStyle(lockSecondary).lineLimit(1)
      }
      if let model {
        if showsAmounts {
          Text("\(MoneyFormat.string(model.spent.minor, style: .rounded)) spent").privacySensitive()
            .hFigure(.lockValue).foregroundStyle(Color.white).lineLimit(1)
          Text([model.verdictWord, model.billNamed].compactMap { $0 }.joined(separator: " · ")).privacySensitive()
            .hType(.lockCaption).foregroundStyle(lockSecondary).lineLimit(1)
        } else {
          Text(model.verdictWord).hFigure(.lockValue).foregroundStyle(Color.white).lineLimit(1)
          if let words = model.billWords {
            Text(words).hType(.lockCaption).foregroundStyle(lockSecondary).lineLimit(1)
          }
        }
      } else {
        Text("Your first bank alert will fill this in.").hType(.lockCaption).foregroundStyle(lockSecondary)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

public struct LockReviewCircleView: View {
  let model: ToReviewWidget?

  public init(_ model: ToReviewWidget?) {
    self.model = model
  }

  public var body: some View {
    VStack(spacing: 0) {
      if let model {
        Text("\(model.count)").hFigure(.lockCount).foregroundStyle(Color.white)
        Text("to sort").hType(.lockRingCaption).foregroundStyle(lockSecondary)
      } else {
        HIconView(.reviewSheet, size: 20, color: lockSecondary, strokeWidth: 2)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.map { "To review, \($0.count) to sort" } ?? "To review")
  }
}
