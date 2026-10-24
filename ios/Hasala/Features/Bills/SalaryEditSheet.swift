import HasalaDesign
import HasalaModels
import SwiftUI

struct SalaryEditSheet: View {
  let app: AppModel
  let bill: BillID
  @State private var amountText: String
  @State private var payday: Int
  @State private var active: Bool
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel, bill: BillID) {
    self.app = app
    self.bill = bill
    let terms = BillsEngine.salary(app.store.state, bill: bill)
    _amountText = State(initialValue: terms.map { MoneyFormat.draft($0.amount.minor) } ?? "")
    _payday = State(initialValue: terms?.payday ?? 1)
    _active = State(initialValue: terms?.active ?? true)
  }

  private var terms: SalaryTerms? { BillsEngine.salary(app.store.state, bill: bill) }

  private var minor: Int64? { RecurringCopy.positiveMinor(amountText) }

  var body: some View {
    RecurringForm(title: terms?.name ?? "Salary", closeID: "bills.salary.close") {
      RecurringField("Amount", footer: "Past months keep the income you received. This applies from this month on.") {
        RecurringTextField(placeholder: "0.00", text: $amountText, label: "Amount, in dirhams",
                           id: "bills.salary.amount", amount: true)
      }
      RecurringCard {
        Stepper(value: $payday, in: 1...31) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Payday").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            Text("The \(PlanEngine.ordinal(payday)) of each month").hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
          }
          .padding(.vertical, 8)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityValue("the \(PlanEngine.ordinal(payday))")
        .accessibilityIdentifier("bills.salary.payday")
        HDivider(inset: .text16)
        Toggle(isOn: $active) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Expect this income").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            Text("Off when it has stopped, like after a job change.").hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 8)
        }
        .tint(HColor.controlSwitchTrackOn)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityIdentifier("bills.salary.active")
      }
    } dock: {
      Button("Save") {
        guard let minor else { return }
        if app.perform(.editIncome(id: bill, amount: .aed(minor), payday: payday, active: active)) { dismiss() }
      }
      .buttonStyle(.pill(.primary, fill: true))
      .pillHeight()
      .disabled(minor == nil || terms == nil)
      .accessibilityIdentifier("bills.salary.save")
    }
  }
}
