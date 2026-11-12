import HasalaDesign
import HasalaModels
import SwiftUI

enum BankTextsGuide {
  static let intro = "Hasala gets each text with a full stop, from any sender, and keeps only payment details."

  static let runImmediately = "Choose Run Immediately, then tap Next."
  static let newBlank = "Tap New Blank Automation, then Add Action."
  static let actionMissing = (title: "Hasala action not in the list?", detail: "Open Hasala once, then search again.")

  static let installTitle = "Add the automation"
  static let setUpSubtitle = "It hands Hasala almost every text you get."
  static let installSteps = [
    "Tap Add to Shortcuts. Shortcuts opens with the automation ready.",
    "Tap Add Shortcut. If nothing happens, tap Skip Setup.",
    "Turn on its automation switch. It stays off until you do.",
    "Check that it\u{2019}s set to Run Immediately, or each text waits for your tap.",
    "Come back here and send a test.",
  ]
  static let twoAutomations = "Two automations bring in each text twice."
  static let alreadyMade = "Already made one? Skip this. \(twoAutomations)"
  static let addAgainNote = "Only if it didn't add. \(twoAutomations)"
  static let newShortcuts =
    "On iOS 27, start a new shortcut and add Message from its automation actions. Then use the settings below."
  static let turnedOn = (title: "The automation is on", detail: "In Shortcuts, open Hasala\u{2019}s automation and turn on the switch at the top.")

  static let shortSteps = [
    "In the Shortcuts app, tap Automation, then +, then Message.",
    "Leave Sender empty. Tap Message Contains and type a full stop (.).",
    runImmediately,
    newBlank,
    "Search \u{201C}Hasala\u{201D} and pick Add bank text. Check that it shows Message in blue, then tap Done.",
  ]

  static let fullSteps = [
    "Open the Shortcuts app, tap Automation at the bottom, then + at the top.",
    "Choose Message as what starts it.",
    "Leave Sender empty. Tap Message Contains and type a full stop (.), which bank amounts usually have.",
    runImmediately,
    newBlank,
    "Search \u{201C}Hasala\u{201D} and pick Add bank text. If Message isn\u{2019}t in blue, tap the blue word and pick Message. Tap Done.",
  ]

  static let checklist: [(title: String, detail: String)] = [
    ("Run Immediately is chosen", "Otherwise each text waits for your tap."),
    ("Message Contains is a full stop", "Leave Sender empty. Any other word can miss payments."),
    ("Add bank text gets the message", "The action should show Message in blue."),
    ("The test had its full stop", "Send \u{201C}\(BankTexts.testPhrase)\u{201D} to your own number, or have someone text it."),
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
  let offersInstall: Bool
  let againTitle = "Add to Shortcuts again"
  let againNote = BankTextsGuide.addAgainNote

  func returned(opened: Bool) -> Bool { offersInstall && opened }

  init(install: URL?) {
    offersInstall = install != nil
    subtitle = BankTextsGuide.setUpSubtitle
    if let install {
      title = BankTextsGuide.installTitle
      steps = BankTextsGuide.installSteps
      guideTitle = "Make it by hand instead"
      openTitle = "Add to Shortcuts"
      openIdentifier = "texts.addAutomation"
      openURL = install
      testTitle = "I turned it on, send a test"
    } else {
      title = "Make the automation"
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
  var tip: String?
  var tipTopic = BankTexts.keepsTopic
  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      HIconView(icon, size: 16, color: HColor.textSecondary, strokeWidth: 1.8).frame(height: lane)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .infoTip(tip, about: tipTopic)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 4)
    .accessibilityElement(children: tip == nil ? .combine : .contain)
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
