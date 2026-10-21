import HasalaDesign
import HasalaModels
import Observation
import SwiftUI

enum FinishSetupItem: String, CaseIterable, Identifiable {
  case plan
  case notifications

  var id: String { rawValue }
}

@MainActor
@Observable
final class FinishSetupModel {
  @ObservationIgnored private let services: AccountServices
  private(set) var planDone = false
  private(set) var notificationsDone = false
  var planFlow: MonthlyPlanModel?
  @ObservationIgnored private var draft: MonthlyPlanModel?
  var askingNotifications = false
  var showDetails = false

  init(services: AccountServices) {
    self.services = services
    refresh()
  }

  func refresh() {
    let saved = services.setup.readBack()
    if !planDone, saved.incomeMinor != nil || saved.split != nil { planDone = true }
    if !notificationsDone, services.notifications.answered { notificationsDone = true }
  }

  func isDone(_ item: FinishSetupItem) -> Bool {
    switch item {
    case .plan: planDone
    case .notifications: notificationsDone
    }
  }

  var today: LocalDate { (services.setup as? SetupClock)?.today() ?? LedgerToday.device() }

  func setPlan() {
    let flow = draft ?? MonthlyPlanModel(setup: services.setup) { [weak self] saved in
      if saved {
        self?.planDone = true
        self?.draft = nil
      }
      self?.planFlow = nil
    }
    flow.path = []
    draft = flow
    planFlow = flow
  }

  func askNotifications() {
    showDetails = services.notifications.showsDetails
    askingNotifications = true
  }

  func allowNotifications() async {
    services.notifications.showsDetails = showDetails
    _ = await services.notifications.requestAuthorization()
    notificationsDone = true
    askingNotifications = false
  }

  func notificationsNotNow() {
    services.notifications.decline()
    notificationsDone = true
    askingNotifications = false
  }
}

struct FinishSetupSection: View {
  let model: FinishSetupModel
  let items: [FinishSetupItem]
  let importing: Bool

  var body: some View {
    let open = items.filter { !model.isDone($0) }
    if !open.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Finish setting up", trailing: .fact("\(items.count - open.count) of \(items.count)"))
        ForEach(open) { item in
          switch item {
          case .plan:
            FinishSetupRow(
              icon: .clock, title: "Set your monthly plan",
              detail: "Your salary and a split, so Hasala can say what's left.",
              enabled: true, identifier: "home.finish.plan", action: model.setPlan)
          case .notifications:
            FinishSetupRow(
              icon: .bell, title: "A note when money moves",
              detail: importing
                ? "Offered once your alerts are read."
                : "Choose whether Hasala can send you a short note.",
              enabled: !importing, identifier: "home.finish.notifications", action: model.askNotifications)
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("home.finish")
    }
  }
}

private struct FinishSetupRow: View {
  let icon: HIcon
  let title: String
  let detail: String
  let enabled: Bool
  let identifier: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(enabled ? HColor.blue50 : HColor.neutral100)
          .frame(width: 44, height: 44)
          .overlay {
            HIconView(icon, size: 22, color: enabled ? HColor.actionAccent : HColor.neutral600, strokeWidth: 1.6)
          }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
            .foregroundStyle(HColor.textPrimary)
          Text(detail)
            .hType(HType(size: 14, leading: 19, weight: .regular, textStyle: .subheadline))
            .foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        if enabled {
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.neutral400)
        }
      }
      .padding(16)
      .background(HColor.widgetSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
      .opacity(enabled ? 1 : 0.6)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .disabled(!enabled)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier(identifier)
  }
}

struct MonthlyPlanSheet: View {
  @Bindable var model: MonthlyPlanModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack(path: $model.path) {
      IncomeStep(model: model)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) { dismiss() }
              .tint(HColor.iconGlass)
              .accessibilityIdentifier("plan.setup.close")
          }
        }
        .navigationDestination(for: MonthlyPlanModel.Route.self) { _ in
          PlanStep(model: model)
        }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("plan.setup")
  }
}

struct NotificationsAskSheet: View {
  @Bindable var model: FinishSetupModel

  var body: some View {
    NotificationsStep(
      today: model.today, showDetails: $model.showDetails,
      allow: { await model.allowNotifications() }, notNow: model.notificationsNotNow)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("notifications.ask")
  }
}
