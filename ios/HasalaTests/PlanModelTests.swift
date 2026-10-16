import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// Plan, its details and its sheets over the Maya ledger.
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
    // Each source carries the disc it is drawn with; Ready to assign is the mint wallet.
    #expect(sources.first?.glyph == .wallet && sources.first?.hue == .mint)
    let travel = sources.first { $0.id == "travel" }
    #expect(travel?.glyph == .travel && travel?.hue == .lilac)
    // Hidden, the sources' figures go and their words stay.
    #expect(sources[1].detail.rendered(hidden: true) == "••• left · nothing spent yet")
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

  /// The sheets say no before anything is sent, so no refusal toast lands under a sheet.
  @Test func aSourceWithoutEnoughIsRefusedOnTheSheet() {
    let app = AppModel(store: InMemoryLedger())
    let sheet = BudgetSheetViewModel(app: app, category: "groceries")
    #expect(sheet.refusal(moving: .aed(318_00), from: nil) == nil)
    #expect(sheet.refusal(moving: .aed(1_000_01), from: nil) == "Ready to assign doesn't have that much")
    #expect(sheet.refusal(moving: .aed(2_500_00), from: "travel") == nil)
    #expect(sheet.refusal(moving: .aed(2_500_01), from: "travel") == "Travel doesn't have that much left")
    #expect(app.toast == nil)
  }

  /// A rise from Ready to assign sets the budget; a rise from a category moves money from it;
  /// a cut gives the money back to Ready to assign. Each closes the sheet with its toast.
  @Test func aBudgetComesFromWhereThePersonSays() {
    let october = YearMonth(2026, 10)
    let app = AppModel(store: InMemoryLedger())
    app.router.sheet = .budget("dining")
    let sheet = BudgetSheetViewModel(app: app, category: "dining")
    #expect(sheet.setBudget(.aed(1_800_00), takingFrom: nil))
    #expect(app.toast?.title == "Dining budget changed")
    #expect(app.router.sheet == nil)
    #expect(sheet.plan.readyToAssign == .aed(800_00))

    let fromTravel = BudgetSheetViewModel(app: app, category: "dining")
    #expect(fromTravel.setBudget(.aed(2_000_00), takingFrom: "travel"))
    #expect(app.toast?.title == "Moved to Dining")
    #expect(app.store.state.plan.budget("dining", october) == .aed(2_000_00))
    #expect(app.store.state.plan.budget("travel", october) == .aed(2_300_00))
    #expect(fromTravel.plan.readyToAssign == .aed(800_00))

    // A cut ignores the source: the money goes back to Ready to assign.
    let cut = BudgetSheetViewModel(app: app, category: "dining")
    #expect(cut.setBudget(.aed(1_500_00), takingFrom: "travel"))
    #expect(app.store.state.plan.budget("travel", october) == .aed(2_300_00))
    #expect(cut.plan.readyToAssign == .aed(1_300_00))
  }

  /// "Match September" reads what the category spent last month (Debug only on screen).
  @Test func lastMonthIsWhatTheCategorySpent() {
    let app = AppModel(store: InMemoryLedger())
    let groceries = BudgetSheetViewModel(app: app, category: "groceries")
    #expect(groceries.lastMonth?.name == "September")
    #expect(groceries.lastMonth?.spent == .aed(689_80))
    // Nothing went to Dining in September: no chip.
    #expect(BudgetSheetViewModel(app: app, category: "dining").lastMonth == nil)
  }

  /// Plan's rows and project cards push their screens on the Plan tab's stack; Assign opens
  /// Move money with no category.
  @Test func planOpensItsScreens() {
    let app = AppModel(store: InMemoryLedger())
    let plan = PlanViewModel(app: app)
    plan.open("dining")
    plan.open(project: "japan")
    #expect(app.router.plan == [.category("dining"), .project("japan")])
    plan.moveMoney(to: nil)
    #expect(app.router.sheet == .moveMoney(to: nil))
  }

  /// Plan · Dining's actions: the budget sheet and Move money over the tab, a row's
  /// transaction sheet, and a rule's Categories and rules in Your profile.
  @Test func diningOpensWhatItNames() {
    let app = AppModel(store: InMemoryLedger())
    let dining = CategoryDetailViewModel(app: app, category: "dining")
    #expect(dining.detail?.left == .aed(957_25))
    #expect(dining.detail?.transactions.count == 5)
    dining.changeBudget()
    #expect(app.router.sheet == .budget("dining"))
    app.router.sheet = nil
    app.router.sheetDismissed()
    dining.moveMoneyIn()
    #expect(app.router.sheet == .moveMoney(to: "dining"))
    app.router.sheet = nil
    app.router.sheetDismissed()
    dining.open("zuma")
    #expect(app.router.sheet == .transaction("zuma"))
    app.router.sheet = nil
    app.router.sheetDismissed()
    dining.openRules()
    #expect(app.router.sheet == .profile)
    #expect(app.router.profile == [.rules])
  }

  /// The details follow the ledger: a budget change reaches the hero at once.
  @Test func detailsFollowTheLedger() {
    let app = AppModel(store: InMemoryLedger())
    let dining = CategoryDetailViewModel(app: app, category: "dining")
    #expect(dining.detail?.verdict == .overPace)
    #expect(app.perform(.setBudget("dining", YearMonth(2026, 10), .aed(2_500_00))))
    #expect(dining.detail?.left == .aed(1_857_25))
    #expect(dining.detail?.verdict == .onTrack)

    let japan = ProjectDetailViewModel(app: app, project: "japan")
    #expect(japan.detail?.left == .aed(7_140_00))
    #expect(ProjectDetailViewModel(app: app, project: "gone").detail == nil)
    #expect(CategoryDetailViewModel(app: app, category: "gone").detail == nil)
  }
}
