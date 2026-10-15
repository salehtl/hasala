import HasalaDesign
import HasalaModels
import SwiftUI

// Parts only the join screens draw (Paper P2.1, spec 07 §3.2): the status line under a
// code, the email chip, a note with a bare glyph, a numbered step and a card of reasons.
// Everything else comes from the account templates (`AccountUI`, `AccountFieldsUI`).

/// One line that says where a code came from or what is wrong with it (Paper "StatusLine"
/// under the invite field): a 7 pt dot centred on the first line, then 15/20 medium in the
/// tone's ink. Colour never works alone: the words say it.
struct JoinStatusLine: View {
  enum Tone { case success, error, warning }

  var text: String
  var tone: Tone

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle().fill(ink).frame(width: 7, height: 7).frame(height: lane)
      Text(text)
        .hType(.subheadline.weight(.medium))
        .foregroundStyle(ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("status.\(tone)")
  }

  private var ink: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .error: HColor.statusErrorForeground
    case .warning: HColor.statusWarningForeground
    }
  }
}

/// The chip inside the email box once the address is confirmed (Paper "Chip · Confirmed by
/// invite", E7J): 28 tall, the success surface, a dot and "Confirmed".
struct ConfirmedChip: View {
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7)
      Text("Confirmed")
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.statusSuccessForeground)
        .lineLimit(1)
    }
    .padding(.leading, 10)
    .padding(.trailing, 12)
    .frame(minHeight: 28)
    .background(HColor.statusSuccessSurface, in: Capsule())
    .fixedSize()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("about.confirmed")
  }
}

/// A plain note on a white card with a bare glyph (Paper "InfoCard · What email is for"):
/// a 22 line glyph in the icon colour, then 15/20 secondary text; radius 20, 16 in.
struct GlyphNote: View {
  var icon: HIcon
  var text: String

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      HIconView(icon, size: 22, color: HColor.iconPrimary, strokeWidth: 1.8)
        .frame(height: max(22, lane))
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// A step in "What happens next" (Paper "NumberedChecklist"): a 26 white badge ringed in
/// neutral 300 with its number, then 15/20 text.
struct NumberedStep: View {
  var number: Int
  var text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .hFigure(HFigure(size: 14, leading: 18, weight: .bold, textStyle: .subheadline))
        .foregroundStyle(HColor.textPrimary)
        .frame(minWidth: 26, minHeight: 26)
        .background(Circle().fill(HColor.surfacePrimary))
        .overlay { Circle().strokeBorder(HColor.neutral300, lineWidth: 1.5) }
        .accessibilityHidden(true)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(number). \(text)")
  }
}

/// A white list card of short reasons (Paper "ListCard · Other reasons", E6F): 16/22 titles,
/// 15/20 lines, 14 / 16 in, dividers inset 16.
struct ReasonsCard: View {
  var reasons: [(title: String, detail: String)]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(reasons.enumerated()), id: \.offset) { i, reason in
        if i > 0 {
          Rectangle().fill(HColor.borderSubtle).frame(height: 1).padding(.leading, 16)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(reason.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          Text(reason.detail)
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
      }
    }
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

/// A full-width text button in the dock (Paper "TextButton": 54 tall, no fill, 17/24
/// semibold in the link colour), for a second action that is not a link away.
struct DockTextButton: View {
  var title: String
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(title, action: action)
      .buttonStyle(.pill(.tertiary, fill: true))
      .accessibilityIdentifier(identifier)
  }
}
