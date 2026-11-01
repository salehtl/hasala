import HasalaDesign
import HasalaModels
import SwiftUI

struct ShortcutsGuideSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  private struct Step: Identifiable {
    let id: Int
    let text: String
    let sketch: Sketch
  }

  private enum Sketch {
    case tabs, trigger, when, run, blank, action
  }

  private let steps = zip(BankTextsGuide.fullSteps, [Sketch.tabs, .trigger, .when, .run, .blank, .action])
    .enumerated().map { i, pair in Step(id: i + 1, text: pair.0, sketch: pair.1) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(BankTextsGuide.intro)
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
          if let install = BankTexts.automationInstall {
            TextsLinkRow(title: "Add it ready-made instead", icon: .add, identifier: "textsGuide.addAutomation") {
              openURL(install)
            }
          }
          ForEach(steps) { step in
            VStack(alignment: .leading, spacing: 10) {
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                StepBadge(number: step.id)
                Text(step.text)
                  .hType(.subheadline)
                  .foregroundStyle(HColor.textPrimary)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel("Step \(step.id). \(step.text)")
              sketch(step.sketch)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("textsGuide.step\(step.id)")
          }
          TextsNote(text: "\(BankTextsGuide.actionMissing.title) \(BankTextsGuide.actionMissing.detail)")
          TextsNote(icon: .chat, text: "Then send yourself \u{201C}\(BankTexts.testPhrase)\u{201D}, full stop included, to check that it runs.")
          Button { openURL(BankTexts.shortcutsURL) } label: {
            Text("Open Shortcuts").fixedSize(horizontal: false, vertical: true)
          }
          .buttonStyle(.pill(.primary, fill: true))
          .dockPill()
          .padding(.top, 4)
          .accessibilityIdentifier("textsGuide.openShortcuts")
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 32)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Make the automation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("textsGuide.done")
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("textsGuide")
  }

  @ViewBuilder private func sketch(_ kind: Sketch) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Sketch of the Shortcuts app")
        .hType(.overline)
        .foregroundStyle(HColor.statusWarningForeground)
      switch kind {
      case .tabs:
        HStack(spacing: 8) {
          sketchTab("Shortcuts", on: false)
          sketchTab("Automation", on: true)
          sketchTab("Gallery", on: false)
          Spacer(minLength: 0)
          Circle().fill(HColor.actionAccentSubtle).frame(width: 32, height: 32)
            .overlay { HIconView(.add, size: 14, color: HColor.actionAccent) }
        }
      case .trigger:
        sketchGroup {
          sketchRow(icon: .chat, "Message")
        }
      case .when:
        sketchGroup {
          sketchRow(icon: .chat, "When I get a message")
          HDivider(inset: .text16)
          sketchRow("Sender", value: "Leave empty")
          HDivider(inset: .text16)
          sketchRow("Message Contains", value: "\u{201C}.\u{201D}")
        }
      case .run:
        sketchGroup {
          sketchRow("Run After Confirmation")
          HDivider(inset: .text16)
          sketchRow("Run Immediately", checked: true)
        }
      case .blank:
        sketchGroup {
          sketchRow("New Blank Automation", checked: true)
          HDivider(inset: .text16)
          sketchRow("Add Action", link: true)
        }
      case .action:
        sketchGroup {
          HStack(spacing: 10) {
            Text("Add bank text").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
            Text("Message")
              .hType(.subheadline)
              .foregroundStyle(HColor.textLink)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(HColor.actionAccentSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.statusWarningSurface.opacity(0.45), in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }

  private func sketchTab(_ title: String, on: Bool) -> some View {
    Text(title)
      .hType(on ? HType.footnote.weight(.semibold) : HType.footnote)
      .foregroundStyle(on ? HColor.actionAccent : HColor.textSecondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(on ? HColor.actionAccentSubtle : Color.clear, in: Capsule())
  }

  private func sketchGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) { content() }
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func sketchRow(
    icon: HIcon? = nil, _ title: String, value: String? = nil, checked: Bool = false, link: Bool = false
  ) -> some View {
    HStack(spacing: 10) {
      if let icon { HIconView(icon, size: 18, color: HColor.statusSuccessForeground, strokeWidth: 1.8) }
      Text(title)
        .hType(.subheadline)
        .foregroundStyle(link ? HColor.textLink : HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if let value { Text(value).hType(.subheadline).foregroundStyle(HColor.textSecondary) }
      if checked { HIconView(.check, size: 14, color: HColor.actionAccent, strokeWidth: 2.4) }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }
}
