import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

struct SourceStep: View {
  @Bindable var model: SetupModel
  @State private var tapped: PaymentSource?

  var body: some View {
    let busy = model.busy || model.connectBusy
    AccountScreen(
      title: "How do your banks reach you?",
      subtitle: "Pick one. Hasala reads it on this iPhone, and reads only one at a time.",
      trailing: ("Skip", model.skipSource)
    ) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach([PaymentSource.texts, .email], id: \.self) { source in
          SourceCard(source: source, busy: busy && tapped == source) {
            tapped = source
            model.chooseSource(source)
          }
          .disabled(busy)
        }
        SetupFailureBanner(failure: model.failure)
        DockNote(text: "Skip to add spending by hand and set this up later in Profile. Either way, payments are read on this iPhone.")
          .padding(.top, 4)
      }
      .padding(.top, -8)
    }
  }
}

enum SourceCardCopy {
  static func title(_ source: PaymentSource) -> String { source == .texts ? "Bank texts" : "Bank email" }

  static func subtitle(_ source: PaymentSource) -> String {
    source == .texts ? "Through one automation in the Shortcuts app" : "Gmail or personal Outlook, read-only"
  }

  static var emailBanks: String {
    let names = SupportedBank.allCases.map(\.shortName)
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
  }

  static func upsides(_ source: PaymentSource) -> [String] {
    source == .texts
      ? ["No mailbox access, no Google warning", "Any bank that texts you", "Works when your bank only texts"]
      : [emailBanks, "Can find your older payments too", "Reads only your banks' alert emails"]
  }

  static func downsides(_ source: PaymentSource) -> [String] {
    source == .texts
      ? [
        "Hasala sees each text with a full stop, from anyone, and drops all but payments",
        "Only from your next payment on, and you set it up in the Shortcuts app",
      ]
      : ["Gmail shows an unverified-app warning in the beta"]
  }
}

private struct SourceCard: View {
  let source: PaymentSource
  let busy: Bool
  var pick: () -> Void

  var body: some View {
    let title = SourceCardCopy.title(source)
    let subtitle = SourceCardCopy.subtitle(source)
    let upsides = SourceCardCopy.upsides(source)
    let downsides = SourceCardCopy.downsides(source)
    Button(action: pick) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(HColor.neutral100)
            .frame(width: 40, height: 40)
            .overlay {
              HIconView(source == .texts ? .chat : .envelope, size: 22, color: HColor.textPrimary, strokeWidth: 1.6)
            }
          VStack(alignment: .leading, spacing: 1) {
            Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
            Text(subtitle).hType(.footnote).foregroundStyle(HColor.textSecondary)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          Group {
            if busy {
              Spinner(size: HSpacing.iconSmall, track: HColor.feedbackProgressTrack)
            } else {
              HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
            }
          }
          .frame(width: 24, height: 40)
          .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 6) {
          ForEach(upsides, id: \.self) { line in
            bullet(line, upside: true)
          }
          ForEach(downsides, id: \.self) { line in
            bullet(line, upside: false)
          }
        }
        .padding(.leading, 52)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(([title, subtitle] + upsides + downsides).joined(separator: ". "))
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("source.\(source.rawValue)")
  }

  private func bullet(_ text: String, upside: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if upside {
        HIconView(.check, size: 14, color: HColor.statusSuccessForeground, strokeWidth: 2.4)
      } else {
        Text(verbatim: "\u{2022}").hType(.subheadline).foregroundStyle(HColor.textSecondary).frame(width: 14)
      }
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(upside ? HColor.textPrimary : HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct TextsSetUpStep: View {
  @Bindable var model: SetupModel
  @State private var guiding = false
  @State private var opened = false
  @Environment(\.openURL) private var openURL
  private var install: URL? { BankTexts.offeredInstall(model.bankTexts) }

  var body: some View {
    let copy = TextsSetUpCopy(install: install)
    let returned = copy.returned(opened: opened)
    AccountScreen(title: copy.title, subtitle: copy.subtitle, back: .system) {
      VStack(alignment: .leading, spacing: 16) {
        TextsNote(icon: .privacy, text: BankTexts.keepsPayments)
          .accessibilityIdentifier("texts.keepsOnly")
        NumberedStepsCard(steps: copy.steps)
        TextsLinkRow(title: copy.guideTitle, identifier: "texts.showMeHow") { guiding = true }
        TextsNote(icon: .privacy, text: BankTexts.fakedTextNote)
          .accessibilityIdentifier("texts.fakedText")
        TextsNote(icon: .bank, text: BankTexts.anyBankLine)
          .accessibilityIdentifier("texts.anyBank")
        SetupFailureBanner(failure: model.failure)
        SkipToNextTextLink(identifier: "texts.skip") { Task { await model.finishTexts() } }
      }
      .padding(.top, -8)
    } footer: {
      if returned {
        testButton(copy, primary: true)
        openButton(copy, title: copy.againTitle, primary: false)
        Text(copy.againNote)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("texts.addAgainNote")
      } else {
        openButton(copy, title: copy.openTitle, primary: true)
        testButton(copy, primary: false)
      }
    }
    .sheet(isPresented: $guiding) { ShortcutsGuideSheet(install: install) }
  }

  private func openButton(_ copy: TextsSetUpCopy, title: String, primary: Bool) -> some View {
    Button {
      openURL(copy.openURL)
      opened = true
    } label: {
      Text(title).fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.pill(primary ? .primary : .tertiary, size: primary ? .large : .medium, fill: true))
    .dockPill()
    .accessibilityIdentifier(primary ? copy.openIdentifier : "texts.addAgain")
  }

  private func testButton(_ copy: TextsSetUpCopy, primary: Bool) -> some View {
    Button { model.sendTestText() } label: {
      Text(copy.testTitle).fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.pill(primary ? .primary : .tertiary, size: primary ? .large : .medium, fill: true))
    .dockPill()
    .accessibilityIdentifier("texts.toTest")
  }
}

struct TextsTestStep: View {
  @Bindable var model: SetupModel

  var body: some View {
    if let lane = model.bankTexts {
      BankTextsTestScreen(
        lane: lane, back: .system, inSetup: true, doneTitle: "Go to Home", done: finish, skip: finish,
        failure: model.failure)
    }
  }

  private func finish() { Task { await model.finishTexts() } }
}

struct BankTextsTestScreen: View {
  let lane: any BankTextsConnecting
  var back: AccountBack = .none
  var trailing: (title: String, action: () -> Void)?
  var inSetup = false
  var doneTitle: String
  var done: () -> Void
  var skip: (() -> Void)?
  var failure: SetupFailure?
  @State private var copied = false
  @Environment(\.openURL) private var openURL

  var body: some View {
    let test = lane.test
    AccountScreen(title: Self.title(test), subtitle: Self.subtitle(test), back: back, trailing: trailing) {
      VStack(alignment: .leading, spacing: 16) {
        switch test {
        case .received(let at):
          receivedCard(at)
          TextsNote(text: BankTexts.confirmNote)
            .accessibilityIdentifier("textsTest.confirmNote")
          TextsNote(text: "Texts from before now don't come in. Paste one from Review if you need it.")
          if inSetup {
            TextsNote(icon: .history, text: "Change it any time in Profile \u{203A} Bank alerts.")
          }
        case .nothingYet:
          checklist
          TextsNote(text: Self.nothingYetNote(windowOpen: lane.testWindowOpen))
            .accessibilityIdentifier("textsTest.watching")
        case .idle, .waiting:
          waitingCard
          TextsNote(text: "Hasala adds nothing for this text. It only checks that the automation runs.")
          TextsNote(icon: .chat, text: "If nothing arrives in a minute, Hasala shows what to check.")
        }
        SetupFailureBanner(failure: failure)
        if test == .nothingYet { skipLink }
      }
      .padding(.top, -8)
      .hAnimation(.stateSwap, value: test)
    } footer: {
      footer(test)
    }
    .onAppear { if test == .idle { lane.startTest() } }
    .task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: Self.copiedFor)
      if !Task.isCancelled { copied = false }
    }
    .onChange(of: test) { _, now in
      if case .received = now { AccessibilityNotification.Announcement("Test text received").post() }
      if now == .nothingYet { AccessibilityNotification.Announcement("Nothing arrived yet").post() }
    }
  }

  static let copiedFor: Duration = .seconds(2)

  static func nothingYetNote(windowOpen: Bool) -> String {
    windowOpen ? "Hasala is still watching for the test text." : "Hasala stopped watching. Tap Send the test again."
  }

  static let worksLine =
    "From now on, each bank payment text comes in as it arrives, filed or to Review for you to check."

  static func title(_ test: BankTextsTest) -> String {
    switch test {
    case .received: "Your automation works"
    case .nothingYet: "Nothing arrived yet"
    case .idle, .waiting: "Send yourself a test"
    }
  }

  static func subtitle(_ test: BankTextsTest) -> String {
    switch test {
    case .received: Self.worksLine
    case .nothingYet: "Check these in the Shortcuts app, then send the test again."
    case .idle, .waiting: "Messages opens with the test written. Send it to your own number. Hasala is watching for it."
    }
  }

  @ViewBuilder private func footer(_ test: BankTextsTest) -> some View {
    switch test {
    case .received:
      Button { done() } label: { Text(doneTitle).fixedSize(horizontal: false, vertical: true) }
        .buttonStyle(.pill(.primary, fill: true))
        .dockPill()
        .accessibilityIdentifier("textsTest.done")
    case .nothingYet:
      Button { openURL(BankTexts.shortcutsURL) } label: {
        Text("Open Shortcuts").fixedSize(horizontal: false, vertical: true)
      }
      .buttonStyle(.pill(.primary, fill: true))
      .dockPill()
      .accessibilityIdentifier("textsTest.openShortcuts")
      Button { lane.startTest() } label: { Text("Send the test again").fixedSize(horizontal: false, vertical: true) }
        .buttonStyle(.pill(.tertiary, size: .medium, fill: true))
        .dockPill()
        .accessibilityIdentifier("textsTest.again")
    case .idle, .waiting:
      Button { openURL(BankTexts.messagesURL) } label: {
        Text("Open Messages").fixedSize(horizontal: false, vertical: true)
      }
      .buttonStyle(.pill(.primary, fill: true))
      .dockPill()
      .accessibilityIdentifier("textsTest.openMessages")
      skipLink
    }
  }

  @ViewBuilder private var skipLink: some View {
    if let skip { SkipToNextTextLink(identifier: "textsTest.skip", action: skip) }
  }

  private var waitingCard: some View {
    HListCard(alignment: .leading) {
      ReflowingRow(spacing: 12) {
        Button(action: copyPhrase) {
          Text(copied ? "Copied" : "Copy")
            .hType(HType.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textLink)
            .padding(.horizontal, 14)
            .frame(minWidth: HSpacing.targetMinimum, minHeight: HSpacing.targetMinimum)
            .background(HColor.actionAccentSubtle, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy \(BankTexts.testPhrase)")
        .accessibilityIdentifier("textsTest.copy")
      } trailing: {
        Button(action: copyPhrase) {
          Text(BankTexts.testPhrase)
            .hType(.body)
            .foregroundStyle(HColor.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(HColor.neutral100, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("The test text: \(BankTexts.testPhrase)")
        .accessibilityHint("Copies it")
        .accessibilityIdentifier("textsTest.phrase")
      }
      .padding(16)
      HDivider(inset: .none)
        .padding(.horizontal, 16)
      HStack(spacing: 12) {
        Spinner(size: 20, track: HColor.feedbackProgressTrack)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text("Waiting for the test text").hType(.headline).foregroundStyle(HColor.textPrimary)
          Text("Usually a few seconds after it arrives").hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(16)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.updatesFrequently)
      .accessibilityIdentifier("textsTest.waiting")
    }
  }

  private func copyPhrase() {
    UIPasteboard.general.string = BankTexts.testPhrase
    copied = true
  }

  private func receivedCard(_ at: Date) -> some View {
    HListCard(alignment: .leading) {
      HStack(spacing: 14) {
        Circle().fill(HColor.statusSuccessSurface).frame(width: 48, height: 48)
          .overlay { HIconView(.check, size: 22, color: HColor.statusSuccessForeground, strokeWidth: 2.4) }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text("Test text received").hType(.headline).foregroundStyle(HColor.textPrimary)
          Text("At \(BankTexts.time(at))").hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(16)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("textsTest.received")
    }
  }

  static func checklistItems(offersInstall: Bool) -> [(title: String, detail: String)] {
    (offersInstall ? [BankTextsGuide.turnedOn] : []) + BankTextsGuide.checklist
  }

  private var checklist: some View {
    HListCard(alignment: .leading) {
      ForEach(Array(Self.checklistItems(offersInstall: BankTexts.automationInstall != nil).enumerated()), id: \.offset) { i, item in
        if i > 0 { HDivider(inset: .disc68) }
        HStack(alignment: .firstTextBaseline, spacing: 14) {
          StepBadge(number: i + 1)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).hType(.headline).foregroundStyle(HColor.textPrimary)
            Text(item.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("textsTest.checklist")
  }
}

struct SkipToNextTextLink: View {
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("Skip, confirm with my next bank text")
        .hType(HType.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textLink)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}
