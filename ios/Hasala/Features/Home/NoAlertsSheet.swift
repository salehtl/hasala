import HasalaDesign
import HasalaModels
import SwiftUI

struct NoAlertsSheet: View {
  @Bindable var model: FinishSetupModel
  @Environment(\.dismiss) private var dismiss
  @State private var helping: SupportedBank?

  static let windowDays = 90

  private var bankList: String { model.noAlertsBanks.map(\.shortName).formatted(.list(type: .and)) }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 20) {
          Circle()
            .fill(HColor.statusWarningSurface)
            .frame(width: 72, height: 72)
            .overlay { HIconView(.envelope, size: 32, color: HColor.statusWarningForeground, strokeWidth: 1.8) }
            .accessibilityHidden(true)
          VStack(spacing: 8) {
            Text("No bank alerts yet.")
              .hType(.largeTitle)
              .foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            Text("Hasala looked back \(Self.windowDays) days in \(model.noAlertsMailbox.appName) for \(bankList). Your bank may send alerts only by SMS.")
              .hType(.body)
              .foregroundStyle(HColor.textOnWashSecondary)
              .frame(maxWidth: 320)
          }
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 52)
        VStack(spacing: 12) {
          card
          SetupFailureBanner(failure: model.checkFailure)
          if let note = model.checkNote ?? (model.alreadyChecking ? FinishSetupModel.alreadyCheckingLine(model.noAlertsMailbox) : nil) {
            Text(note)
              .hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 4)
              .accessibilityIdentifier("noAlerts.alreadyChecking")
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 28)
      }
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaBar(edge: .bottom) {
      ActionDock(keyboardUp: false) {
        Button("Check for new alerts") { Task { await model.checkAgain() } }
          .buttonStyle(.pill(.primary, fill: true, loading: model.checkingAgain || model.alreadyChecking))
          .dockPill()
          .accessibilityIdentifier("noAlerts.checkAgain")
        Button("Go to Home") { dismiss() }
          .buttonStyle(.pill(.onGrouped, fill: true))
          .disabled(model.checkingAgain)
          .dockPill()
          .accessibilityIdentifier("noAlerts.close")
      }
    }
    .background(alignment: .top) {
      AmbientWash(.itWorks).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .sheet(item: $helping) { bank in
      EmailAlertsHelpSheet(banks: [bank])
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("noAlerts")
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Turn on email alerts")
        .hType(.overline)
        .foregroundStyle(HColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, 4)
      ForEach(Array(model.noAlertsBanks.enumerated()), id: \.element) { i, bank in
        if i > 0 { HColor.borderSubtle.frame(height: 1).accessibilityHidden(true) }
        HStack(spacing: 12) {
          Text(bank.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("How to") { helping = bank }
            .buttonStyle(.plain)
            .hType(HType.subheadline.weight(.medium))
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
            .accessibilityLabel("How to turn on email alerts, \(bank.name)")
            .accessibilityIdentifier("noAlerts.howTo.\(bank.rawValue)")
        }
      }
      Text("Check for new alerts reads what reached \(model.noAlertsMailbox.appName) since Hasala looked. Alerts go to another address? Use that mailbox instead.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
      Button("Use a different email") { model.useDifferentEmail() }
        .buttonStyle(.plain)
        .hType(HType.subheadline.weight(.medium))
        .foregroundStyle(HColor.textLink)
        .disabled(model.checkingAgain)
        .frame(minHeight: HSpacing.targetMinimum)
        .contentShape(Rectangle())
        .accessibilityIdentifier("noAlerts.differentEmail")
    }
    .padding(.top, 18)
    .padding(.horizontal, 16)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}
