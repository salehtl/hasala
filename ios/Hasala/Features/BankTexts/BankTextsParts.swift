import HasalaDesign
import HasalaModels
import SwiftUI

enum BankTextsGuide {
  static let intro =
    "One automation hands Hasala each text you get that has a full stop. \(BankTexts.keepsPayments) \(BankTexts.anyBankLine)"

  static let runImmediately = "Choose Run Immediately, then tap Next."
  static let newBlank = "Tap New Blank Automation, then Add Action."
  static let actionMissing = (title: "Hasala action not in the list?", detail: "Open Hasala once, then search again in the Shortcuts app.")

  static let installTitle = "Add the automation"
  static let installSubtitle =
    "One automation in the Shortcuts app hands Hasala your texts, for all your banks. Hasala has it ready. You add it and turn it on."
  static let installSteps = [
    "Tap Add to Shortcuts. The Shortcuts app opens with the automation ready.",
    "Tap Add Shortcut. If nothing happens, tap Skip Setup.",
    "Turn on its automation switch. It stays off until you do, and Hasala can\u{2019}t turn it on for you.",
    "Check that it\u{2019}s set to Run Immediately. If it asks first, each text waits for your tap.",
    "Come back here and send a test.",
  ]
  static let alreadyMade = "Already made one? Skip this. Two automations bring in each text twice."
  static let newShortcuts =
    "On iOS 27, Shortcuts looks different. Start a new shortcut and add Message from its automation actions first. The settings below stay the same."
  static let turnedOn = (title: "The automation is on", detail: "In the Shortcuts app, open Hasala\u{2019}s automation and turn on the switch at the top.")

  static let shortSteps = [
    "In the Shortcuts app, open the Automation tab, tap +, then Message.",
    "Leave Sender empty. Tap Message Contains and type a full stop (.).",
    runImmediately,
    newBlank,
    "Search \u{201C}Hasala\u{201D} and pick Add bank text. Check that it shows Message in blue, then tap Done.",
  ]

  static let fullSteps = [
    "Open the Shortcuts app and tap Automation at the bottom. Then tap + at the top.",
    "Choose Message as what starts it.",
    "Leave Sender empty. Tap Message Contains and type just a full stop (.). Bank payment texts usually have one in their amount. A text with no full stop doesn\u{2019}t reach Hasala, so paste it instead.",
    runImmediately,
    newBlank,
    "Search \u{201C}Hasala\u{201D} and pick Add bank text. Check that it shows Message in blue. If it doesn\u{2019}t, tap the blue word and pick Message. Tap Done.",
  ]

  static let checklist: [(title: String, detail: String)] = [
    ("Run Immediately is chosen", "If it asks first, the text waits for your tap."),
    ("Message Contains is a full stop", "Leave Sender empty and type only a full stop (.) in Message Contains. Any other word can leave payments out."),
    ("Add bank text gets the message", "The action should show Message in blue."),
    ("The test had its full stop", "Send \u{201C}\(BankTexts.testPhrase)\u{201D} to your own number, or ask someone to text it to you. Without the full stop the automation doesn\u{2019}t run."),
    actionMissing,
  ]
}

struct TextsSetUpCopy: Equatable {
  let title: String
  let subtitle: String
  let steps: [String]
  let guideTitle: String
  let openTitle: String
  let openIdentifier: String
  let openURL: URL
  let testTitle: String

  init(install: URL?) {
    if let install {
      title = BankTextsGuide.installTitle
      subtitle = BankTextsGuide.installSubtitle
      steps = BankTextsGuide.installSteps
      guideTitle = "Make it by hand instead"
      openTitle = "Add to Shortcuts"
      openIdentifier = "texts.addAutomation"
      openURL = install
      testTitle = "I turned it on, send a test"
    } else {
      title = "Make the automation"
      subtitle = "One automation in the Shortcuts app hands Hasala your texts, for all your banks. Apple doesn't let apps make it for you."
      steps = BankTextsGuide.shortSteps
      guideTitle = "Show me how, step by step"
      openTitle = "Open Shortcuts"
      openIdentifier = "texts.openShortcuts"
      openURL = BankTexts.shortcutsURL
      testTitle = "I made it, send a test"
    }
  }
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
