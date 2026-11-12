import HasalaDesign
import HasalaModels
import SwiftUI

struct SalaryEditSheet: View {
  struct Fields: Equatable {
    var amountText: String
    var payday: Int
    var active: Bool

    static func opened(_ terms: SalaryTerms?) -> Fields {
      Fields(amountText: terms.map { MoneyFormat.draft($0.amount.minor) } ?? "", payday: terms?.payday ?? 1,
             active: terms?.active ?? true)
    }
  }

  let app: AppModel
  let bill: BillID
  private let opened: Fields
  @State private var fields: Fields
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel, bill: BillID) {
    self.app = app
    self.bill = bill
    let fields = Fields.opened(BillsEngine.salary(app.store.state, bill: bill))
    opened = fields
    _fields = State(initialValue: fields)
  }

  private var terms: SalaryTerms? { BillsEngine.salary(app.store.state, bill: bill) }
  private var payday: Int { fields.payday }

  private var minor: Int64? { RecurringCopy.positiveMinor(fields.amountText) }

  var body: some View {
    RecurringForm(title: terms?.name ?? "Salary", closeID: "bills.salary.close", isDirty: fields != opened) {
      RecurringField("Amount", footer: "Applies from this month on. Past months keep their income.") {
        RecurringTextField(placeholder: "0.00", text: $fields.amountText, label: "Amount, in dirhams",
                           id: "bills.salary.amount", amount: true)
      }
      RecurringCard {
        Stepper(value: $fields.payday, in: 1...31) {
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
        Toggle(isOn: $fields.active) {
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
        if app.perform(.editIncome(id: bill, amount: .aed(minor), payday: fields.payday, active: fields.active)) { dismiss() }
      }
      .buttonStyle(.pill(.primary, fill: true))
      .pillHeight()
      .disabled(minor == nil || terms == nil)
      .accessibilityIdentifier("bills.salary.save")
    }
  }
}
