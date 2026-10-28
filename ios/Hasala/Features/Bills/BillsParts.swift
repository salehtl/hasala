import HasalaDesign
import HasalaModels
import SwiftUI

// The parts Bills, one bill and Accounts share (Paper row 07 "Bills and accounts"): the pushed
// page with its wash, the bill card with its poster, the bill row with a tag after its title,
// and the line glyphs the kit's icon set doesn't have.

/// A page pushed inside a tab or the profile sheet (Paper "Header · Pushed": Bills, AXA
/// Insurance, Accounts): the system bar with the back button and the title, the wash that
/// scrolls away with the content, the column 20 under the header (or `top`), sections
/// `spacing` apart, 160 above the bottom under the soft scroll edge. In a tab the page hosts
/// the toast 14 above the bar; in the profile sheet the sheet hosts it.
struct PushedPage<Content: View>: View {
  @Bindable var app: AppModel
  let title: String
  var wash: HWash = .onTrack
  var spacing: CGFloat = HSpacing.gapScreenSection
  var top: CGFloat = 20
  @ViewBuilder let content: () -> Content
  @Environment(\.inProfileSheet) private var inProfileSheet

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: spacing) { content() }
        .padding(.top, top)
        .padding(.bottom, HSpacing.scrollContentBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // The wash starts at the top of the screen, behind the bar, and scrolls away with the
    // content (Paper: absolute, 420 tall); a pull or a refresh doesn't carry it down.
    .washBehind(wash)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(inProfileSheet ? HColor.sheetSurfaceLarge : HColor.surfaceSecondary)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .overlay(alignment: .bottom) { if !inProfileSheet { ToastHost(app: app) } }
  }
}

extension AppRouter {
  /// Pushes one bill's page onto the stack its list is in: the profile sheet's, or Home's
  /// (Bills is pushed from Home's widget and from Profile › Bills).
  func openBill(_ id: BillID, inProfileSheet: Bool) {
    if inProfileSheet { profile.append(.bill(id)) } else { home.append(.bill(id)) }
  }
}

/// A card that asks for a decision about a bill (page 16 §12; Bills · Coming up and found):
/// a 104 poster in the bill's hue (rose may be late, sand changed price, sky newly found) with
/// the glyph plate, the name, the status pill and the figure, over a white body: the sentence,
/// what else the card shows, and one or two 44 buttons. At the accessibility sizes the buttons
/// stack, primary on top. VoiceOver reads the card as one sentence, then the buttons.
struct BillCard<Extra: View>: View {
  struct Action {
    let title: String
    let id: String
    let run: () -> Void
  }

  let hue: Hue
  let glyph: PosterGlyph
  let name: String
  let pill: StatusPill
  let amount: Money
  /// After the figure: "every month".
  var caption: String?
  let message: MoneyPhrase?
  let hidden: Bool
  let primary: Action
  var secondary: Action?
  let id: String
  @ViewBuilder var extra: Extra
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        poster
        if let message {
          Text(message.rendered(hidden: hidden))
            .hType(.subheadline)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
      VStack(alignment: .leading, spacing: 12) {
        extra
        buttons
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 14)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .hElevation(.nearFar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(id)
  }

  private var poster: some View {
    // Paper's poster spreads its two rows apart (space-between): 6 at the drawn 104.
    VStack(alignment: .leading, spacing: 0) {
      ReflowingRow(spacing: 6) {
        HStack(spacing: 8) {
          plate
          Text(name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
            .lineLimitAtDefaultTextSize(2)
        }
      } trailing: {
        StatusPillView(pill)
      }
      Spacer(minLength: 6)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        MoneyText(amount, figure: .large, unit: .unit, hidden: hidden, hiddenGlyphs: 3, color: HColor.textPrimary,
                  unitGap: 5)
        if let caption {
          Text(caption).hType(.body).foregroundStyle(HColor.textOnHueSecondary)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    // At least 104; taller when the words need it, the figure still at the bottom.
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
    .fixedSize(horizontal: false, vertical: true)
    .background(hue.perceptualGradient)
  }

  /// The 32 plate in `--color-poster-glyph` with the glyph at 18, stroke 2, in the hue's ink.
  @ViewBuilder private var plate: some View {
    switch glyph {
    case .icon(let icon):
      GlyphPlate(icon: icon, hue: hue, size: 32)
    case .path(let stroke, let fill):
      Circle()
        .fill(HColor.posterGlyph)
        .frame(width: 32, height: 32)
        .overlay { StrokeGlyph(d: stroke, filled: fill, size: 18, color: hue.ink, lineWidth: 2) }
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder private var buttons: some View {
    let layout = typeSize.isAccessibilitySize || secondary == nil
      ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    layout {
      Button(primary.title, action: primary.run)
        .buttonStyle(.pill(.primary, size: .medium, fill: true))
        .pillHeight()
        .layoutPriority(1)
        .accessibilityIdentifier(primary.id)
      if let secondary {
        Button(secondary.title, action: secondary.run)
          .buttonStyle(.pill(.secondary, size: .medium, fill: true))
          .pillHeight()
          .frame(minWidth: typeSize.isAccessibilitySize ? nil : 128)
          .accessibilityIdentifier(secondary.id)
      }
    }
  }

  /// "AXA Insurance, AED 550.00, 3 days past usual. Car insurance usually arrives on the 7th."
  private var spoken: String {
    let figure = hidden ? "Amount hidden" : "\(amount.currency) \(MoneyFormat.string(amount.minor))"
    let head = [name, figure + (caption.map { " \($0)" } ?? ""), pill.text].joined(separator: ", ")
    return message.map { "\(head). \($0.spoken(hidden: hidden))" } ?? head
  }
}

extension BillCard where Extra == EmptyView {
  init(hue: Hue, glyph: PosterGlyph, name: String, pill: StatusPill, amount: Money, message: MoneyPhrase?,
       hidden: Bool, primary: Action, secondary: Action?, id: String)
  {
    self.init(hue: hue, glyph: glyph, name: name, pill: pill, amount: amount, caption: nil, message: message,
              hidden: hidden, primary: primary, secondary: secondary, id: id) { EmptyView() }
  }
}

/// What a bill card's poster plate draws: one of the kit's icons, or a Paper path the kit
/// doesn't carry (du's wifi).
enum PosterGlyph: Equatable {
  case icon(HIcon)
  /// Stroked path data on the 24 grid, and an optional part that is filled.
  case path(stroke: String, fill: String?)

  /// Paper 1K9-0 · BillCard · Price change (du): three arcs and a dot at (12, 19.4), r 1.3.
  static let wifi = PosterGlyph.path(
    stroke: "M2.8 9.2a13.5 13.5 0 0 1 18.4 0M5.9 12.6a9 9 0 0 1 12.2 0M9 16a4.6 4.6 0 0 1 6 0",
    fill: "M13.3 19.4a1.3 1.3 0 1 1-2.6 0a1.3 1.3 0 1 1 2.6 0Z")
}

/// A bill or income line (page 16 §12 BillRow): the 40 disc, the name with an optional tag
/// ("Price change"), the due line (a red dot and words when it may be late), and the amount:
/// "~" when expected, "+" in green for income. Min 64. At the accessibility sizes the parts
/// stack. One VoiceOver stop.
struct BillsListRow: View {
  let row: BillRowModel
  var tag: StatusPill?
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
    layout {
      CategoryDisc(hue: row.hue, glyph: row.glyph)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle).singleLineAtDefaultTextSize()
          if let tag { StatusPillView(tag, size: .s22, surface: .tinted).fixedSize() }
        }
        BillDetailParts(parts: row.detail, hidden: hidden)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 0) {
        if row.approximate && !hidden {
          Text(verbatim: "~").hFigure(.row).foregroundStyle(HColor.moneyOut)
        }
        MoneyText(row.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                  color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
      }
      .fixedSize()
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var spoken: String {
    let amount = hidden
      ? "Amount hidden"
      : (row.approximate ? "about " : "") + (row.isIncome ? "plus " : "")
        + "\(row.amount.currency) \(MoneyFormat.string(row.amount.minor))"
    return [row.name, tag?.text, BillDetailParts.spoken(row.detail, hidden: hidden), amount]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

/// A row's second line from `PlanDetailPart`s joined by " · ": words in 13/18 secondary, a
/// status as a 7 dot and words 13/18 600 in its tone ("● Expected the 7th").
struct BillDetailParts: View {
  let parts: [PlanDetailPart]
  let hidden: Bool

  var body: some View {
    line.hType(.footnote).lineLimitAtDefaultTextSize(1)
  }

  private var line: Text {
    var text = Text(verbatim: "")
    for (index, part) in parts.enumerated() {
      if index > 0 {
        text = Text("\(text)\(Text(verbatim: " · ").foregroundStyle(HColor.listRowSupporting))")
      }
      switch part {
      case .text(let p):
        text = Text("\(text)\(Text(p.rendered(hidden: hidden)).foregroundStyle(HColor.listRowSupporting))")
      case .status(let words, let tone):
        let dot = Text(verbatim: "\u{25CF}\u{2002}").font(.system(size: 9)).foregroundStyle(tone.foreground)
        let said = Text(words).fontWeight(.semibold).foregroundStyle(tone.foreground)
        text = Text("\(text)\(dot)\(said)")
      }
    }
    return text
  }

  static func spoken(_ parts: [PlanDetailPart], hidden: Bool) -> String {
    parts.map { part in
      switch part {
      case .text(let p): p.spoken(hidden: hidden)
      case .status(let words, _): words
      }
    }.joined(separator: ", ")
  }
}

/// A line glyph from Paper path data that the kit's icon set doesn't carry (the net worth
/// arrow, du's wifi), on the 24 grid with round caps and joins, and an optional filled part
/// (the wifi's dot). Decorative.
struct StrokeGlyph: View {
  let d: String
  var filled: String?
  var size: CGFloat = 16
  var color: Color
  var lineWidth: CGFloat = 2.4

  var body: some View {
    Canvas { context, canvas in
      let box = CGRect(origin: .zero, size: canvas)
      if let svg = try? SVGPath(parsing: d) {
        context.stroke(svg.path(in: box), with: .color(color), style: StrokeStyle(
          lineWidth: lineWidth * canvas.width / 24, lineCap: .round, lineJoin: .round))
      }
      if let filled, let svg = try? SVGPath(parsing: filled) {
        context.fill(svg.path(in: box), with: .color(color))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

extension View {
  /// A pill takes the height its label needs at every text size, never a little less than
  /// it (the accessibility audit's "Text clipped" at AX3 on a two-line label, as P3's docks
  /// found).
  func pillHeight() -> some View { fixedSize(horizontal: false, vertical: true) }
}
