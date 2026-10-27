import Foundation
import HasalaDesign
import HasalaModels
import Observation

@MainActor
@Observable
final class AddTransactionModel {
  private let app: AppModel
  var entry = AmountEntry()
  var direction: Direction = .out
  var merchant = ""
  var categoryID: CategoryID?
  var postedAt: Date
  var accountID: AccountID?
  let resolvedMail: TxnID?

  init(app: AppModel, resolving mail: TxnID? = nil) {
    self.app = app
    let unread = mail.flatMap { id in app.store.state.unreadMail.first { $0.id == id } }
    let text = mail.flatMap { id in app.store.state.unreadTexts.first { $0.id == id } }
    resolvedMail = unread?.id ?? text?.id
    postedAt = AddTransactionDates.date(
      unread.map { LocalDateTime(date: $0.receivedOn, hour: 0, minute: 0) } ?? text?.receivedAt ?? app.store.now)
    let accounts = app.store.state.accounts
    let named = unread?.accountID ?? text?.accountID
    accountID = named.flatMap { id in accounts.first { $0.id == id }?.id } ?? accounts.first { $0.inPlan }?.id
  }

  var latest: Date { AddTransactionDates.date(app.store.now) }
  var categoryGroups: [CategoryGroup] { CategoryGroup.all(app.store.state) }
  var accounts: [Account] { app.store.state.accounts }

  var category: CategoryOption? {
    categoryID.flatMap { id in app.store.state.category(id) }.map(CategoryOption.init)
  }

  var account: Account? { accountID.flatMap { id in accounts.first { $0.id == id } } }

  var draft: ManualEntryDraft? {
    guard let minor = entry.minor, minor > 0, categoryID != nil else { return nil }
    let d = ManualEntryDraft(
      amount: .aed(minor), direction: direction, merchant: merchant, categoryID: categoryID,
      postedAt: min(AddTransactionDates.local(postedAt), app.store.now), accountID: accountID)
    return d.refusal == nil ? d : nil
  }

  var canSave: Bool { draft != nil }

  var saveTitle: String {
    guard let minor = entry.minor, minor > 0 else { return "Enter an amount" }
    return "Add AED \(MoneyFormat.string(minor))"
  }

  var missing: String? {
    guard let minor = entry.minor, minor > 0 else { return nil }
    if merchant.trimmedSpaces.isEmpty { return "Add who it was with" }
    if merchant.trimmedSpaces.count > ManualEntryDraft.maxMerchantLength {
      return "Keep the name to \(ManualEntryDraft.maxMerchantLength) characters"
    }
    if categoryID == nil { return "Choose a category" }
    return nil
  }

  @discardableResult
  func save() -> Bool {
    guard let d = draft else { return false }
    var edits: [LedgerEdit] = []
    if let resolvedMail { edits.append(.archive(resolvedMail, true)) }
    edits.append(.addTransaction(d))
    guard app.perform(edits) else { return false }
    app.sheet = nil
    app.say("Added \(d.trimmedMerchant)")
    return true
  }

  func cancel() { app.sheet = nil }
}

enum AddTransactionDates {
  static func date(_ t: LocalDateTime) -> Date {
    ProjectDates.calendar.date(
      from: DateComponents(year: t.date.year, month: t.date.month, day: t.date.day, hour: t.hour, minute: t.minute)) ?? Date()
  }

  static func local(_ d: Date) -> LocalDateTime {
    let c = ProjectDates.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: d)
    return LocalDateTime(c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
  }
}
