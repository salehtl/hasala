import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

struct SourceStep: View {
  @Bindable var model: SetupModel
  @State private var picked: PaymentSource?

  var body: some View {
    AccountScreen(
      title: "How do your banks reach you?",
      subtitle: "Pick one. Hasala reads it on this iPhone, and reads only one at a time.",
      trailing: ("Skip", model.skipSource)
    ) {
      VStack(alignment: .leading, spacing: 12) {
        SourceCard(source: .texts, picked: picked == .texts) { picked = .texts }
        SourceCard(source: .email, picked: picked == .email) { picked = .email }
        SetupFailureBanner(failure: model.failure)
        DockNote(text: "Skip to add spending by hand and set this up later in Profile. Either way, payments are read on this iPhone.")
          .padding(.top, 4)
      }
      .padding(.top, -8)
    } footer: {
      BusyButton(
        title: picked == nil ? "Choose one" : "Continue", busy: model.busy, enabled: picked != nil,
        identifier: "source.continue"
      ) {
        guard let picked else { return }
        model.chooseSource(picked)
      }
      .dockPill()
    }
    .onAppear { if picked == nil { picked = model.source ?? model.lastPickedSource } }
  }
}

private struct SourceCard: View {
  let source: PaymentSource
  let picked: Bool
  var pick: () -> Void

  private var title: String { source == .texts ? "Bank texts" : "Bank email" }
  private var subtitle: String {
    source == .texts ? "Through one automation in the Shortcuts app" : "Gmail or Outlook, read-only"
  }
  private var upsides: [String] {
    source == .texts
      ? ["No inbox access, no Google warning", "Works when your bank only texts"]
      : ["Can find your older payments too", "Reads only your banks' alert emails"]
  }
  private var downside: String {
    source == .texts
      ? "Only from your next payment on, and you set it up in the Shortcuts app"
      : "Gmail shows an unverified-app warning in the beta"
  }

  var body: some View {
    Button(action: pick) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(source == .texts ? HColor.actionAccentSubtle : HColor.neutral100)
            .frame(width: 40, height: 40)
            .overlay {
              HIconView(source == .texts ? .chat : .envelope, size: 22,
                        color: source == .texts ? HColor.actionAccent : HColor.textPrimary, strokeWidth: 1.6)
            }
          VStack(alignment: .leading, spacing: 1) {
            Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
            Text(subtitle).hType(.footnote).foregroundStyle(HColor.textSecondary)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          CheckCircle(on: picked)
        }
        VStack(alignment: .leading, spacing: 6) {
          ForEach(upsides, id: \.self) { line in
            bullet(line, upside: true)
          }
          bullet(downside, upside: false)
        }
        .padding(.leading, 52)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous)
          .strokeBorder(HColor.actionAccent, lineWidth: 2)
          .opacity(picked ? 1 : 0)
      }
      .contentShape(RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(([title, subtitle] + upsides + [downside]).joined(separator: ". "))
    .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
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
  @Environment(\.openURL) private var openURL

  var body: some View {
    AccountScreen(
      title: "Make the automation",
      subtitle: "One automation in the Shortcuts app hands Hasala your texts, for all your banks. Apple doesn't let apps make it for you.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 16) {
        NumberedStepsCard(steps: BankTextsGuide.shortSteps)
        TextsLinkRow(title: "Show me how, step by step", identifier: "texts.showMeHow") { guiding = true }
        TextsNote(icon: .privacy, text: BankTexts.keepsPayments)
          .accessibilityIdentifier("texts.keepsOnly")
        TextsNote(icon: .bank, text: BankTexts.anyBankLine)
          .accessibilityIdentifier("texts.anyBank")
        SetupFailureBanner(failure: model.failure)
      }
      .padding(.top, -8)
    } footer: {
      Button { openURL(BankTexts.shortcutsURL) } label: {
        Text("Open Shortcuts").fixedSize(horizontal: false, vertical: true)
      }
      .buttonStyle(.pill(.primary, fill: true))
      .dockPill()
      .accessibilityIdentifier("texts.openShortcuts")
      Button { model.sendTestText() } label: {
        Text("I made it, send a test").fixedSize(horizontal: false, vertical: true)
      }
      .buttonStyle(.pill(.tertiary, size: .medium, fill: true))
      .dockPill()
      .accessibilityIdentifier("texts.toTest")
      SkipToNextTextLink(identifier: "texts.skip") { Task { await model.finishTexts() } }
    }
    .sheet(isPresented: $guiding) { ShortcutsGuideSheet() }
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
          TextsNote(text: "Texts from before now don't come in. Paste one from Review if you need it.")
          if inSetup {
            TextsNote(icon: .history, text: "Change it any time in Profile \u{203A} Bank alerts.")
          }
        case .nothingYet:
          checklist
          TextsNote(text: "Hasala is still watching for the test text.")
        case .idle, .waiting:
          waitingCard
          TextsNote(text: "Hasala adds nothing for this text. It only checks that the automation runs.")
          TextsNote(icon: .chat, text: "If nothing arrives in a minute, Hasala shows what to check.")
        }
        SetupFailureBanner(failure: failure)
      }
      .padding(.top, -8)
      .hAnimation(.stateSwap, value: test)
    } footer: {
      footer(test)
    }
    .onAppear { if test == .idle { lane.startTest() } }
    .onChange(of: test) { _, now in
      if case .received = now { AccessibilityNotification.Announcement("Test text received").post() }
      if now == .nothingYet { AccessibilityNotification.Announcement("Nothing arrived yet").post() }
    }
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
    case .idle, .waiting: "In Messages, send this to your own number, full stop included. Hasala is watching for it."
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
      skipLink
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
        Button {
          UIPasteboard.general.string = BankTexts.testPhrase
          copied = true
        } label: {
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
        Text(BankTexts.testPhrase)
          .hType(.body)
          .foregroundStyle(HColor.textOnAccent)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(HColor.actionAccent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
          .accessibilityLabel("The test text: \(BankTexts.testPhrase)")
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

  private var checklist: some View {
    HListCard(alignment: .leading) {
      ForEach(Array(BankTextsGuide.checklist.enumerated()), id: \.offset) { i, item in
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
