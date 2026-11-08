import Foundation
import HasalaMocks
import HasalaModels
import Testing
import UIKit

@testable import Hasala

@MainActor
@Suite("Recurring screens")
struct BillsScreenTests {
  @Test func theFourteenDayFigureSaysHowManyEstimatesItHolds() {
    let state = MayaLedger.state
    #expect(BillsViewModel.estimatesDue(state, now: MayaLedger.now) == 1)
    #expect(BillsViewModel.estimatesCaption(1) == "Includes 1 estimate")
    #expect(BillsViewModel.estimatesCaption(2) == "Includes 2 estimates")
    #expect(BillsViewModel.estimatesCaption(0) == nil)
  }

  @Test func salaryShowsUnderTheHeadOnlyInsideFourteenDays() {
    let state = MayaLedger.state
    #expect(!BillsViewModel.incomeDue(state, now: MayaLedger.now))
    #expect(BillsViewModel.incomeDue(state, now: LocalDateTime(2026, 10, 20, 9, 0)))
  }

  @Test func foundItemsUseTheRecurringWords() {
    #expect(BillsView.foundPill == "Looks recurring")
    #expect(BillsView.trackTitle == "Track it")
  }

  @Test func anEstimateIsSpokenAsAbout() throws {
    let app = AppModel(store: InMemoryLedger())
    let dewa = try #require(BillsViewModel(app: app).detail("dewa"))
    #expect(dewa.approximate)
    #expect(BillDetailView.heroSpoken(dewa, hidden: false).contains("about AED 489.15"))
    #expect(!BillDetailView.heroSpoken(dewa, hidden: false).contains("~"))
    #expect(BillDetailView.heroSpoken(dewa, hidden: true).contains("Amount hidden"))
    let expected = try #require(dewa.history.first { if case .expected = $0.kind { true } else { false } })
    #expect(TimelineStep.isEstimate(expected, approximate: true))
    #expect(TimelineStep.spoken(expected, approximate: true, hidden: false).contains("about AED"))
    #expect(!TimelineStep.isEstimate(expected, approximate: false))
  }

  @Test func aNewPriceIsOneSentence() {
    let line = BillDetailView.priceSentence(charged: .aed(427_90), usual: .aed(389_00), from: LocalDate(2026, 10, 5))
    #expect(line.rendered(hidden: false) == "Charged 38.90 more than usual on Mon 5 Oct.")
  }

  @Test func recurringAmountsFollowTheKeypadRules() {
    #expect(RecurringTextField.filtered("12.345", after: "12.34", decimalSeparator: ".") == "12.34")
    #expect(RecurringTextField.filtered("1234567890", after: "123456789", decimalSeparator: ".") == "123,456,789")
    #expect(RecurringTextField.filtered("", after: "1", decimalSeparator: ".") == "")
  }

  @Test func addRecurringIsDirtyOnlyOnceSomethingIsTyped() {
    let model = AddRecurringModel(app: AppModel(store: InMemoryLedger()))
    #expect(!model.isDirty)
    model.name = "Gym"
    #expect(model.isDirty)
  }

  private func appleModel(_ app: AppModel) -> AddRecurringModel {
    let model = AddRecurringModel(app: app, decimalSeparator: ".")
    model.name = "Apple"
    model.keys = ["apple.com"]
    model.amountText = "14.99"
    return model
  }

  @Test func theLinkCountIsWhatWillBeLinked() throws {
    let app = AppModel(store: InMemoryLedger())
    let model = appleModel(app)
    #expect(model.suggestions.map(\.id) == ["apple"])
    #expect(model.linkTitle == "Add without them")
    model.ticked = ["apple"]
    #expect(model.linkTitle == "Add and link 1 payment")
    model.ticked = ["apple", "not-suggested"]
    #expect(model.linkable == ["apple"] && model.linkTitle == "Add and link 1 payment")
    model.amountText = "15.50"
    #expect(model.suggestions.isEmpty && model.linkable.isEmpty && model.linkTitle == "Add without them")
    model.amountText = "14.99"
    #expect(model.linkTitle == "Add and link 1 payment")
    #expect(model.save())
    let added = try #require(app.store.state.bills.last { $0.name == "Apple" })
    #expect(added.payments.compactMap(\.txnID) == ["apple"])
  }

  @Test func aSecondAddDoesNotAddItAgain() {
    let app = AppModel(store: InMemoryLedger())
    let model = appleModel(app)
    let before = app.store.state.bills.count
    #expect(model.save())
    #expect(!model.save())
    #expect(app.store.state.bills.count == before + 1)
  }

  @Test func anAddThatCouldNotStartCanBeTriedAgain() {
    let app = AppModel(store: InMemoryLedger())
    let model = AddRecurringModel(app: app, decimalSeparator: ".")
    let before = app.store.state.bills.count
    #expect(!model.save())
    model.name = "Gym"
    model.amountText = "200"
    #expect(model.save())
    #expect(app.store.state.bills.count == before + 1)
  }

  @Test func editFormsCompareWithWhatTheyOpenedWith() throws {
    let state = MayaLedger.state
    let dewa = try #require(state.bill("dewa"))
    let opened = EditAmountSheet.Fields.opened(dewa, today: MayaLedger.now.date)
    var edited = opened
    #expect(edited == opened)
    edited.varies.toggle()
    #expect(edited != opened)
    let pause = PauseBillSheet.Fields.opened(today: MayaLedger.now.date)
    var until = pause
    until.untilDate = true
    #expect(until != pause)
    let salary = SalaryEditSheet.Fields.opened(BillsEngine.salary(state, bill: "salary"))
    var later = salary
    later.payday = salary.payday == 1 ? 2 : 1
    #expect(later != salary)
  }

  private final class SheetDelegate: NSObject, UIAdaptivePresentationControllerDelegate {}

  private func sheet(_ delegate: SheetDelegate) -> UIPresentationController {
    let controller = UIPresentationController(presentedViewController: UIViewController(), presenting: nil)
    controller.delegate = delegate
    return controller
  }

  @Test func aGuardWithNothingToGuardLeavesTheSheetAlone() {
    let delegate = SheetDelegate()
    let presentation = sheet(delegate)
    let attempt = DismissAttempt.Controller()
    attempt.setEnabled(false, on: presentation)
    #expect(presentation.delegate === delegate)
  }

  @Test func aGuardHandsTheSheetBackWhenItStopsGuarding() {
    let delegate = SheetDelegate()
    let presentation = sheet(delegate)
    let attempt = DismissAttempt.Controller()
    attempt.setEnabled(true, on: presentation)
    #expect(presentation.delegate === attempt.proxy && attempt.proxy.original === delegate)
    attempt.setEnabled(false)
    #expect(presentation.delegate === delegate && attempt.proxy.original == nil)
    attempt.setEnabled(true, on: presentation)
    #expect(presentation.delegate === attempt.proxy && attempt.proxy.original === delegate)
  }

  @Test func aGuardRemovedWhileGuardingHandsTheSheetBack() {
    let delegate = SheetDelegate()
    let presentation = sheet(delegate)
    do {
      let attempt = DismissAttempt.Controller()
      attempt.setEnabled(true, on: presentation)
      DismissAttempt.dismantleUIViewController(attempt, coordinator: ())
    }
    #expect(presentation.delegate === delegate)
  }

  @Test func aGuardLeavesASheetAnotherGuardHasTaken() {
    let delegate = SheetDelegate()
    let presentation = sheet(delegate)
    let attempt = DismissAttempt.Controller()
    attempt.setEnabled(true, on: presentation)
    let later = SheetDelegate()
    presentation.delegate = later
    attempt.setEnabled(false)
    #expect(presentation.delegate === later)
  }

  @Test func pauseAndEndAreFittedSheets() {
    #expect(RecurringSheet.pause("netflix").fitted && RecurringSheet.end("netflix").fitted)
    #expect(!RecurringSheet.add.fitted && !RecurringSheet.salary("salary").fitted)
  }
}
