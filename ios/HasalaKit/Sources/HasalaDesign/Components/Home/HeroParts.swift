import HasalaModels
import SwiftUI

// The Home hero's own parts (Paper "Hero · Spent on needs + wants" 14SX-0, page 16 §01–02):
// the period pill and the verdict line with its words in the verdict's colour. The bar is
// `MonthPaceBar`; the tiles are `StatTile`.

/// The period pill over the hero (Paper "Period pill · hit area 44"): white, 36 tall, the near
/// shadow, "October 2026" 15/20 600 and a 14 pt chevron (2.6) when it opens the period picker.
/// Without an action it is not a control: it names the month the figures are for.
public struct PeriodPill: View {
  let title: String
  let action: (() -> Void)?

  public init(_ title: String, action: (() -> Void)? = nil) {
    self.title = title
    self.action = action
  }

  public var body: some View {
    if let action {
      Button(action: action) { pill }
        .buttonStyle(RowTargetPressStyle())
        .accessibilityLabel("Period, \(title)")
        .accessibilityHint("Double-tap to change.")
    } else {
      // The pill sits in a 44 row, so the hero's rhythm is the same with or without a control.
      pill
        .frame(minHeight: HSpacing.targetMinimum, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Period, \(title)")
    }
  }

  private var pill: some View {
    HStack(spacing: 6) {
      Text(title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
      if action != nil {
        HIconView(.chevronDown, size: 14, color: HColor.textPrimary, strokeWidth: 2.6)
      }
    }
    .padding(.leading, 14)
    .padding(.trailing, action == nil ? 14 : 12)
    .padding(.vertical, 8)
    .frame(minHeight: 36)
    .background(HColor.surfacePrimary, in: Capsule())
    .hElevation(.near)
  }
}

/// The pill's press (darken and 0.97, `HPressStyle`) on the pill alone, with the 44 row
/// around it as the button's target (Paper "Period pill · hit area 44").
private struct RowTargetPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HPressStyle().makeBody(configuration: configuration)
      .frame(minHeight: HSpacing.targetMinimum)
      .contentShape(Rectangle())
  }
}

/// The hero's verdict line (page 06 §6.4, page 16 §01): an 8 dot and the verdict word 15/20 600
/// in the verdict's colour, then "· AED 8,711.66 left" in the wash's secondary ink, and a link
/// on the right ("See month", "Set your plan"). The word may carry an amount ("Over by AED
/// 1,240.00"), so both parts are phrases that Hide amounts reaches; VoiceOver reads "Amount
/// hidden", never the dots. With no plan the dot is grey and the word ink. At the accessibility
/// sizes, or when it doesn't fit, the link moves under the line.
public struct HeroVerdictLine: View {
  let verdict: Verdict?
  let word: MoneyPhrase
  let fact: MoneyPhrase?
  let hidden: Bool
  let link: Link?

  /// A link at the end of the line.
  public struct Link {
    public var title: String
    public var identifier: String
    public var action: () -> Void

    public init(_ title: String, identifier: String, action: @escaping () -> Void) {
      self.title = title
      self.identifier = identifier
      self.action = action
    }
  }

  public init(verdict: Verdict?, word: MoneyPhrase, fact: MoneyPhrase?, hidden: Bool, link: Link? = nil) {
    self.verdict = verdict
    self.word = word
    self.fact = fact
    self.hidden = hidden
    self.link = link
  }

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  public var body: some View {
    ReflowingRow(spacing: 12) {
      // The dot sits centred in a lane one line tall, so it stays on the first line when the
      // words wrap.
      // The words are the element (static text, read as "On track, AED 8,711.66 left"); the
      // dot only repeats them in colour.
      HStack(alignment: .top, spacing: 6) {
        Circle().fill(dotColor).frame(width: 8, height: 8).frame(height: lane)
          .accessibilityHidden(true)
        Text("\(Text(word.rendered(hidden: hidden)).font(wordFont).foregroundStyle(wordColor))\(factText)")
          .hType(.subheadline)
          .foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(spoken)
      }
    } trailing: {
      if let link {
        // A 20 pt line with a 44 pt target: the padding is inside the button and taken back
        // outside it, so the hero's rhythm doesn't move.
        Button(action: link.action) {
          Text(link.title)
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textOnWashLink)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -12)
        .accessibilityIdentifier(link.identifier)
      }
    }
  }

  private var wordFont: Font { HType.subheadline.weight(.semibold).font }

  private var factText: Text {
    Text(verbatim: fact.map { " · " + $0.rendered(hidden: hidden) } ?? "")
  }

  /// "On track, AED 8,711.66 left"; hidden: "On track, AED Amount hidden left".
  private var spoken: String {
    [word.spoken(hidden: hidden), fact?.spoken(hidden: hidden)].compactMap { $0 }.joined(separator: ", ")
  }

  private var dotColor: Color { verdict?.foreground ?? HColor.textOnWashSecondary }
  private var wordColor: Color { verdict?.foreground ?? HColor.textPrimary }
}
