import HasalaDesign
import HasalaModels
import SwiftUI

enum BankTextsGuide {
  static let shortSteps = [
    "In the Shortcuts app, open the Automation tab, tap +, then Message.",
    "Leave Sender as Any and add no Message Contains filter.",
    "Choose Run Immediately, then tap Next.",
    "Tap New Blank Automation, then Add Action.",
    "Search \u{201C}Hasala\u{201D}, pick Add bank text, then tap Done.",
  ]

  static let checklist: [(title: String, detail: String)] = [
    ("Run Immediately is chosen", "If it asks first, the text waits for your tap."),
    ("Sender is Any, with no filter", "A Message Contains filter can leave your test out."),
    ("Add bank text gets the message", "The action should show Message in blue."),
    ("The test went to your own number", "Or ask someone to text you \u{201C}\(BankTexts.testPhrase)\u{201D}."),
    ("Hasala action not in the list?", "Open Hasala once, then search again in the Shortcuts app."),
  ]
}

struct NumberedStepsCard: View {
  let steps: [String]
  var identifier = "texts.steps"

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
        if i > 0 { HDivider(inset: .disc68) }
        HStack(alignment: .firstTextBaseline, spacing: 14) {
          StepBadge(number: i + 1)
          Text(step)
            .hType(.subheadline)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(i + 1). \(step)")
      }
    }
    .padding(.vertical, 4)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }
}

struct StepBadge: View {
  let number: Int
  @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 24

  var body: some View {
    Text(verbatim: "\(number)")
      .hType(HType.footnote.weight(.bold))
      .foregroundStyle(HColor.textLink)
      .frame(minWidth: side, minHeight: side)
      .background(HColor.actionAccentSubtle, in: Circle())
      .accessibilityHidden(true)
  }
}

struct TextsNote: View {
  var icon: HIcon = .info
  let text: String
  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      HIconView(icon, size: 16, color: HColor.textSecondary, strokeWidth: 1.8).frame(height: lane)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
  }
}

struct TextsLinkRow: View {
  let title: String
  var icon: HIcon = .help
  let identifier: String
  let action: () -> Void
  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        HIconView(icon, size: 16, color: HColor.actionAccent, strokeWidth: 1.6).frame(height: lane)
        Text(title)
          .hType(HType.subheadline.weight(.medium))
          .foregroundStyle(HColor.textLink)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 4)
      .frame(minHeight: HSpacing.targetMinimum)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}

struct TextsActionRow: View {
  let title: String
  var detail: String?
  let icon: HIcon
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: HSpacing.listRowGap) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(HColor.actionAccentSubtle)
          .frame(width: 40, height: 40)
          .overlay { HIconView(icon, size: 18, color: HColor.textLink, strokeWidth: 2) }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.rowTitle).foregroundStyle(HColor.textLink)
          if let detail {
            Text(detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, HSpacing.listRowInsetInline)
      .padding(.vertical, 8)
      .frame(minHeight: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier(identifier)
  }
}

struct TextsCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}
