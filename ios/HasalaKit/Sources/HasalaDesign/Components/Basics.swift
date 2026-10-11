import HasalaModels
import SwiftUI

// Small parts of the core kit (Paper "Core kit"): figures, discs, pills, badges,
// section headings and bars. Content parts only; nothing here is glass.

public extension Glyph {
  /// The SF Symbol drawn for this glyph. Paper's line icons are close to these;
  /// the custom set replaces them when the kit's icons are exported (spec 04 §1.1).
  var symbolName: String {
    switch self {
    case .review: "display"
    case .insurance: "shield"
    case .utilities: "bolt"
    case .travel: "airplane"
    case .savingsJar: "lock"
    case .dining: "fork.knife"
    case .budgetPie: "chart.pie.fill"
    case .trendUp: "chart.line.uptrend.xyaxis"
    case .add: "plus"
    case .rent: "house"
    case .groceries: "basket"
    case .transport: "car"
    case .shopping: "bag"
    case .salary: "briefcase"
    case .transfer: "arrow.left.arrow.right"
    case .flag: "flag"
    }
  }
}

/// An amount in the rounded figure face, optionally with its "AED" unit before it.
///
/// Hidden amounts become bullets (Paper "Home · Amounts hidden") and read as "Amount hidden".
public struct MoneyText: View {
  public enum Sign: Sendable { case none, plusForIncome, minusForDebt }

  let money: Money
  let figure: HFigure
  let unit: HFigure?
  let style: MoneyStyle
  let hidden: Bool
  let hiddenGlyphs: Int
  let color: Color
  let unitColor: Color?
  let unitGap: CGFloat

  public init(
    _ money: Money, figure: HFigure, unit: HFigure? = nil, style: MoneyStyle = .exact, hidden: Bool = false,
    hiddenGlyphs: Int = 4, color: Color = HColor.moneyOut, unitColor: Color? = nil, unitGap: CGFloat = 8
  ) {
    self.money = money
    self.figure = figure
    self.unit = unit
    self.style = style
    self.hidden = hidden
    self.hiddenGlyphs = hiddenGlyphs
    self.color = color
    self.unitColor = unitColor
    self.unitGap = unitGap
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: unitGap) {
      if let unit {
        Text(money.currency).hFigure(unit).foregroundStyle(unitColor ?? color)
      }
      Text(hidden ? MoneyFormat.hidden(count: hiddenGlyphs) : MoneyFormat.string(money.minor, style: style))
        .hFigure(hidden ? figure.forHiddenGlyphs : figure)
        .tracking(hidden ? 2 : figure.tracking)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .foregroundStyle(color)
        .contentTransition(.numericText())
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(hidden ? "Amount hidden" : "\(money.currency) \(MoneyFormat.string(money.minor, style: style))")
  }
}

extension HFigure {
  /// Bullets at a large figure's full size read far heavier than the digits they
  /// replace; Paper draws them at about half size on the same baseline.
  var forHiddenGlyphs: HFigure {
    guard size >= 28 else { return self }
    var f = self
    f.size = (size * 0.55).rounded()
    f.leading = leading
    return f
  }
}

/// A gradient disc with a glyph in the hue's ink (Paper "kit Category discs"; 32/34/40/56 pt).
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
      .fill(hue.gradient)
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: glyph.symbolName)
          .font(.system(size: iconSize * 0.8, weight: .semibold))
          .foregroundStyle(hue.ink)
      }
      .accessibilityHidden(true)
  }
}

/// A white status pill on a poster ("● 2 new today"), or a tinted chip on a card ("In 4 days").
public struct StatusPillView: View {
  public enum Surface: Sendable { case white, tinted }

  let pill: StatusPill
  let surface: Surface

  public init(_ pill: StatusPill, surface: Surface = .white) {
    self.pill = pill
    self.surface = surface
  }

  public var body: some View {
    HStack(spacing: 5) {
      if pill.showsDot {
        Circle().fill(pill.tone.foreground).frame(width: 7, height: 7)
      }
      Text(pill.text).hType(.footnote.weight(.semibold)).foregroundStyle(pill.tone.foreground)
    }
    .padding(.horizontal, 10)
    .frame(height: 26)
    .background(surface == .white ? HColor.white : pill.tone.surface, in: Capsule())
    .accessibilityElement(children: .combine)
  }
}

/// A count in a capsule: ink for section counts, red for unread notifications.
public struct CountBadge: View {
  public enum Tone: Sendable { case ink, alert, accent }

  let count: Int
  let tone: Tone

  public init(_ count: Int, tone: Tone = .ink) {
    self.count = count
    self.tone = tone
  }

  public var body: some View {
    let height: CGFloat = tone == .ink ? 24 : 20
    Text("\(count)")
      .font(.system(size: tone == .ink ? 13 : 12, weight: .bold, design: .rounded))
      .foregroundStyle(HColor.white)
      .padding(.horizontal, tone == .ink ? 7 : 6)
      .frame(minWidth: height, minHeight: height, maxHeight: height)
      .background(background, in: Capsule())
  }

  private var background: Color {
    switch tone {
    case .ink: HColor.textPrimary
    case .alert: HColor.actionDestructive
    case .accent: HColor.actionAccent
    }
  }
}

/// "Needs you ④ / 1 bill looks late ……… See all" (Paper section heading, "kit Lists and cards").
public struct SectionHeader: View {
  let title: String
  let count: Int?
  let subtitle: String?
  let actionTitle: String?
  let action: (() -> Void)?

  public init(
    _ title: String, count: Int? = nil, subtitle: String? = nil, actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.count = count
    self.subtitle = subtitle
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    HStack(alignment: subtitle == nil ? .firstTextBaseline : .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(title).hType(.section).foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          if let count { CountBadge(count).accessibilityLabel("\(count) items") }
        }
        if let subtitle {
          Text(subtitle).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
      }
      Spacer(minLength: 8)
      if let actionTitle {
        Button(actionTitle) { action?() }
          .buttonStyle(.plain)
          .hType(.body.weight(.medium))
          .foregroundStyle(HColor.textLink)
      }
    }
  }
}

/// The pace bar (Paper "kit Money and pace"): an 8 pt bar on a 16 pt lane, the ink tick is today.
/// No tick for bills (`today == nil`). Colour carries the verdict; the sentence says it.
public struct PaceBar: View {
  let spent: Permille
  let today: Permille?
  let verdict: Verdict
  let onWash: Bool

  public init(spent: Permille, today: Permille?, verdict: Verdict, onWash: Bool = false) {
    self.spent = spent
    self.today = today
    self.verdict = verdict
    self.onWash = onWash
  }

  public var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(onWash ? HColor.progressTrackOnHue : HColor.paceTrack)
          .frame(height: HSpacing.paceBarHeight)
        Capsule()
          .fill(verdict.fill)
          .frame(width: max(HSpacing.paceBarHeight, w * min(1, spent.fraction)), height: HSpacing.paceBarHeight)
          .opacity(spent.value == 0 ? 0 : 1)
        if let today {
          RoundedRectangle(cornerRadius: 1)
            .fill(HColor.paceMarker)
            .frame(width: 2, height: HSpacing.paceMarkerHeight)
            .background {
              if !onWash {
                RoundedRectangle(cornerRadius: 1.75)
                  .fill(HColor.surfacePrimary)
                  .frame(width: 5, height: HSpacing.paceMarkerHeight + 3)
              }
            }
            .offset(x: w * min(1, today.fraction) - 1)
        }
      }
      .frame(height: HSpacing.paceMarkerHeight)
    }
    .frame(height: HSpacing.paceMarkerHeight)
    .accessibilityElement()
    .accessibilityLabel("Pace")
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    var s = "\(spent.value / 10) percent used"
    if let today { s += " at \(today.value / 10) percent of the month" }
    return s + ", " + verdict.label.lowercased()
  }
}

/// A thin 6 pt progress line (widget rows, projects, goals).
public struct ProgressLine: View {
  let progress: Permille
  let fill: Color
  let track: Color

  public init(_ progress: Permille, fill: Color = HColor.paceFill, track: Color = HColor.paceTrack) {
    self.progress = progress
    self.fill = fill
    self.track = track
  }

  public var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(track)
        Capsule().fill(fill).frame(width: geo.size.width * min(1, progress.fraction))
      }
    }
    .frame(height: HSpacing.progressHeight)
    .accessibilityHidden(true)
  }
}

/// The 36 pt gradient avatar with the person's initial (Paper header, profile glass).
public struct AvatarDisc: View {
  let initial: String
  let size: CGFloat

  public init(initial: String, size: CGFloat = 36) {
    self.initial = initial
    self.size = size
  }

  public var body: some View {
    Circle()
      .fill(
        LinearGradient(
          stops: [
            .init(color: Color(HRGBA(246, 182, 107, 1)), location: 0),
            .init(color: Color(HRGBA(232, 152, 138, 1)), location: 0.55),
            .init(color: Color(HRGBA(140, 107, 184, 1)), location: 1),
          ],
          startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)
        )
      )
      .frame(width: size, height: size)
      .overlay {
        Text(initial)
          .font(.custom(HWeight.bold.interFace, size: size * 16 / 36))
          .foregroundStyle(Color(HRGBA(42, 31, 61, 1)))
      }
      .accessibilityHidden(true)
  }
}
