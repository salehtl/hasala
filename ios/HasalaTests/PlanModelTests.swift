import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// Plan's sheets over the Maya ledger.
@MainActor
@Suite("Plan models")
struct PlanModelTests {
  @Test func moveMoneyOffersTheShortfall() {
    let app = AppModel(store: InMemoryLedger())
    let sheet = BudgetSheetViewModel(app: app, category: "groceries")
    #expect(sheet.shortfall == .aed(318_00))
    // Paper's Move money board, then the needs behind "Show all" (03a §6.13, §7.4):
    // Dining is over pace and Groceries is the destination, so neither is offered.
    let sources = sheet.sources(to: "groceries")
    #expect(sources.prefix(4).map(\.name) == ["Ready to assign", "Travel", "Shopping", "Entertainment"])
    #expect(sources.map { $0.detail.rendered(hidden: false) }.prefix(4)
      == ["1,000.00 not in a budget yet", "2,500.00 left · nothing spent yet", "1,168.20 left", "505.00 left"])
    #expect(sources.dropFirst(4).prefix(2).map(\.name) == ["Transport", "Healthcare"])
    #expect(!sources.contains { $0.id == "dining" || $0.id == "groceries" || $0.id == "rent" })
    #expect(sheet.move(.aed(318_00), from: nil, to: "groceries"))
    #expect(sheet.plan.readyToAssign == .aed(682_00))
  }

  @Test func assignNeverTakesFromTheDestination() {
    let app = AppModel(store: InMemoryLedger())
    let assign = BudgetSheetViewModel(app: app, category: nil)
    #expect(assign.sources(to: nil).contains { $0.id == "shopping" })
    #expect(!assign.sources(to: "shopping").contains { $0.id == "shopping" })
    #expect(!assign.move(.aed(100_00), from: "shopping", to: "shopping"))
    #expect(app.toast == nil)
    #expect(app.store.state.plan.budget("shopping", YearMonth(2026, 10)) == .aed(1_600_00))
  }
}
