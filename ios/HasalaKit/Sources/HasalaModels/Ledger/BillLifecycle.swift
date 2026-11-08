public enum BillLifecycle {
  @discardableResult
  public static func markPaid(_ b: inout Bill) throws(ActionError) -> LocalDate {
    guard !b.isIncome, b.state != .dismissed else { throw .notFound }
    guard b.state == .tracked else { throw .invalidBill }
    let due = b.nextDue
    b.history.insert(due, at: 0)
    b.payments.removeAll { $0.due == due }
    b.payments.insert(BillPayment(due: due, amount: b.amount, link: .marked), at: 0)
    b.nextDue = BillDueDates.shift(b, from: due, by: 1)
    return due
  }
}
