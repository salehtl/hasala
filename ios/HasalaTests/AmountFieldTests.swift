import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Amount fields")
struct AmountFieldTests {
  @Test func aCommaRegionTypesADecimal() {
    #expect(PlanAmountField.shown("12,", after: "12", decimalSeparator: ",") == "12.")
    #expect(PlanAmountField.shown("12.5", after: "12.", decimalSeparator: ",") == "12.5")
    #expect(PlanAmountField.shown("1,80", after: "1,800", decimalSeparator: ",") == "180")
    #expect(PlanAmountField.shown("18000", after: "1,800", decimalSeparator: ",") == "18,000")
  }

  @Test func arabicIndicDigitsShowAsTheAmount() {
    #expect(PlanAmountField.shown("١٢٫٥", after: "", decimalSeparator: "٫") == "12.5")
    #expect(PlanAmountField.shown("٢٥٠٠٠", after: "", decimalSeparator: ".") == "25,000")
  }

  @Test func theFieldTextStaysInsideTheKeypadCap() {
    let text = PlanAmountField.text(for: 1_000_000_000_00)
    #expect(text == "999,999,999.99")
    #expect(MoneyFormat.parseMinor(text) == AmountEntry.maxMinor)
    #expect(PlanAmountField.text(for: -100_00) == "0")
  }

  @Test func theProjectEditorReadsACommaDecimal() throws {
    let app = AppModel(store: InMemoryLedger())
    let editor = ProjectEditorModel(app: app, project: nil, decimalSeparator: ",")
    editor.name = "Kitchen"
    editor.budgetText = "8000,50"
    editor.save()
    let made = try #require(app.store.state.projects.first { $0.name == "Kitchen" })
    #expect(made.budget == .aed(8_000_50))
  }

  @Test func theProjectEditorReadsArabicIndicDigits() throws {
    let app = AppModel(store: InMemoryLedger())
    let editor = ProjectEditorModel(app: app, project: nil, decimalSeparator: "٫")
    editor.name = "Majlis"
    editor.budgetText = "٨٠٠٠٫٥"
    editor.save()
    let made = try #require(app.store.state.projects.first { $0.name == "Majlis" })
    #expect(made.budget == .aed(8_000_50))
  }

  @Test func theProjectEditorKeepsItsAmountToTheKeypadRules() {
    let app = AppModel(store: InMemoryLedger())
    let editor = ProjectEditorModel(app: app, project: nil)
    #expect(editor.budgetShown("12.345", after: "12.34") == "12.34")
    #expect(editor.budgetShown("8000", after: "800") == "8,000")
    #expect(editor.budgetShown("1.2.", after: "1.2") == "1.2")
    #expect(editor.budgetShown("1234567890", after: "123456789") == "123,456,789")
    let comma = ProjectEditorModel(app: app, project: nil, decimalSeparator: ",")
    #expect(comma.budgetShown("12,", after: "12") == "12.")
  }

  @Test func theProjectEditorAsksBeforeDiscardingOnlyAfterAChange() {
    let app = AppModel(store: InMemoryLedger())
    let fresh = ProjectEditorModel(app: app, project: nil)
    #expect(!fresh.isDirty)
    #expect(fresh.discardTitle == "Discard this project?")
    fresh.name = "Kitchen"
    #expect(fresh.isDirty)
    fresh.name = ""
    #expect(!fresh.isDirty)
    fresh.hasStart = true
    #expect(fresh.isDirty)
    fresh.hasStart = false
    fresh.budgetText = "5"
    #expect(fresh.isDirty)

    let trip = ProjectEditorModel(app: app, project: "japan")
    #expect(!trip.isDirty)
    #expect(trip.discardTitle == "Discard these changes?")
    trip.budgetText = "12,000"
    #expect(!trip.isDirty)
    trip.budgetText = "11,000"
    #expect(trip.isDirty)
    trip.budgetText = "12,000"
    trip.countInPlan.toggle()
    #expect(trip.isDirty)
  }

  @Test func savingTheSameCategoryAuthorsNothing() throws {
    let app = AppModel(store: InMemoryLedger())
    let sorted = try #require(app.store.state.txns.first { !$0.inReview && $0.categoryID != nil })
    let detail = try #require(TransactionEngine.detail(sorted.id, app.store.state, now: app.store.now))
    let current = try #require(detail.category?.id)
    #expect(!CategoryPickerView.changes(detail, to: current, alwaysUse: false))
    let other = try #require(app.store.state.categories.first { $0.id != current })
    #expect(CategoryPickerView.changes(detail, to: other.id, alwaysUse: false))
    var inReview = detail
    inReview.needsReview = true
    #expect(CategoryPickerView.changes(inReview, to: current, alwaysUse: false))
    var byHand = detail
    byHand.sortedByRule = false
    #expect(CategoryPickerView.changes(byHand, to: current, alwaysUse: true))
    var byRule = detail
    byRule.sortedByRule = true
    #expect(!CategoryPickerView.changes(byRule, to: current, alwaysUse: true))
  }
}
