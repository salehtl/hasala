import HasalaMocks
import HasalaModels
import Testing

@Suite("Projects · engine")
struct ProjectsEngineTests {
  let now = MayaLedger.now

  func state(_ extra: [Project]) -> LedgerState {
    var s = MayaLedger.state
    s.projects += extra
    return s
  }

  @Test func theListPutsOpenProjectsFirstAndFinishedOnesLatestFirst() {
    let s = state([
      Project(id: "eid", name: "Eid gifts", glyph: .shopping, budget: .aed(1_500_00), starts: nil, ends: nil,
              complete: true, completedOn: LocalDate(2026, 4, 12)),
      Project(id: "kitchen", name: "Kitchen refresh", glyph: .rent, budget: nil, starts: nil, ends: nil,
              complete: true, completedOn: LocalDate(2026, 8, 30)),
    ])
    let list = PlanEngine.projects(s, now: now)
    #expect(list.active.map(\.id) == ["japan"])
    #expect(list.completed.map(\.id) == ["kitchen", "eid"])
    #expect(list.completed[0].when == "finished 30 Aug")
    #expect(PlanEngine.snapshot(s, now: now).projects.map(\.id) == ["japan"])
  }

  @Test func aProjectWithNoBudgetOrDatesShowsWhatItSpent() throws {
    var s = state([Project(id: "move", name: "Moving", glyph: .flag, budget: nil, starts: nil, ends: nil)])
    let carrefour = try #require(s.txns.firstIndex { $0.merchant.hasPrefix("Carrefour") && !$0.needsReview })
    s.txns[carrefour].projectID = "move"
    let p = try #require(PlanEngine.project("move", s, now: now))
    #expect(p.budget == nil && p.left == nil)
    #expect(p.spent == s.txns[carrefour].amount)
    #expect(p.range == nil && p.when == nil)
    #expect(p.explainer.rendered(hidden: false) == "Project spending stays out of October's budgets.")
    let card = try #require(PlanEngine.snapshot(s, now: now).projects.first { $0.id == "move" })
    #expect(card.dates == "" && card.progress == Permille(0))
  }

  @Test func reviewSpendingIsPendingNotSpent() throws {
    var s = MayaLedger.state
    let review = try #require(s.txns.firstIndex { $0.needsReview && $0.direction == .out })
    s.txns[review].projectID = "japan"
    let p = try #require(PlanEngine.project("japan", s, now: now))
    #expect(p.spent == .aed(4_860_00))
    #expect(p.pending == s.txns[review].amount)
    #expect(p.transactions.contains { $0.id == s.txns[review].id && $0.toReview })
  }

  @Test func openEndedDatesReadOnTheirOwn() {
    let s = state([
      Project(id: "a", name: "A", glyph: .flag, budget: nil, starts: LocalDate(2026, 10, 1), ends: nil),
      Project(id: "b", name: "B", glyph: .flag, budget: nil, starts: nil, ends: LocalDate(2026, 10, 1)),
    ])
    let cards = PlanEngine.snapshot(s, now: now).projects
    #expect(cards.first { $0.id == "a" }?.dates == "From 1 Oct · under way")
    #expect(cards.first { $0.id == "b" }?.dates == "Until 1 Oct · ended")
  }

  @Test func candidatesLeaveOutTheProjectsOwnAndNarrowByFilter() {
    let s = MayaLedger.state
    let all = PlanEngine.projectCandidates("japan", s, filter: ProjectCandidateFilter())
    #expect(!all.contains { $0.id == "emirates" || $0.id == "jr-pass" })
    #expect(!ProjectCandidateFilter().narrowed)
    let carrefour = PlanEngine.projectCandidates("japan", s, filter: ProjectCandidateFilter(merchant: "carre"))
    #expect(!carrefour.isEmpty && carrefour.allSatisfy { $0.merchant.lowercased().contains("carre") })
    let october = PlanEngine.projectCandidates(
      "japan", s, filter: ProjectCandidateFilter(from: LocalDate(2026, 10, 1), category: "groceries"))
    #expect(!october.isEmpty)
    #expect(october.allSatisfy { row in
      let t = s.txn(row.id)!
      return t.postedAt.date >= LocalDate(2026, 10, 1) && t.categoryID == "groceries"
    })
  }

  @Test func aDraftExplainsWhyItCantBeSaved() {
    #expect(ProjectDraft(name: "  ").refusal == "Give the project a name")
    #expect(ProjectDraft(name: "Trip", budget: .aed(0)).refusal == "The money set aside must be more than 0")
    #expect(ProjectDraft(name: "Trip", starts: LocalDate(2026, 12, 2), ends: LocalDate(2026, 12, 1)).refusal
      == "The end date is before the start date")
    #expect(ProjectDraft(name: "Trip").refusal == nil)
  }

  @Test func theProfileLineCountsActiveProjects() {
    #expect(ProfileEngine.snapshot(MayaLedger.state, now: now).projects.rendered(hidden: false) == "1 active")
    var s = MayaLedger.state
    s.projects.append(Project(id: "second", name: "Second", glyph: .flag, budget: nil, starts: nil, ends: nil))
    #expect(ProfileEngine.snapshot(s, now: now).projects.rendered(hidden: false) == "2 active")
    s.projects[0].complete = true
    #expect(ProfileEngine.snapshot(s, now: now).projects.rendered(hidden: false) == "1 active")
    s.projects = []
    #expect(ProfileEngine.snapshot(s, now: now).projects.rendered(hidden: false) == "None active")
  }
}

@MainActor
@Suite("Projects · in-memory edits")
struct ProjectsLedgerTests {
  @Test func makeAssignCompleteAndRemove() throws {
    let ledger = InMemoryLedger()
    let id = ledger.newProjectID()
    try ledger.apply(.saveProject(id, ProjectDraft(name: " Kitchen ", glyph: .rent, budget: .aed(8_000_00))))
    let made = try #require(ledger.state.project(id))
    #expect(made.name == "Kitchen" && !made.complete && made.budget == .aed(8_000_00))

    let carrefour = try #require(ledger.state.txns.first { $0.merchant.hasPrefix("Carrefour") && !$0.needsReview })
    let groceries = ledger.state.spent("groceries", in: MayaLedger.october)
    let token = try #require(try ledger.apply(.assignProject([carrefour.id], id)))
    #expect(token.title == "Added to Kitchen")
    #expect(ledger.state.txn(carrefour.id)?.projectID == id)
    if carrefour.postedAt.date.yearMonth == MayaLedger.october {
      #expect(ledger.state.spent("groceries", in: MayaLedger.october).minor
        == groceries.minor - carrefour.amount.minor)
    }
    #expect(PlanEngine.project(id, ledger.state, now: MayaLedger.now)?.transactions.map(\.id) == [carrefour.id])
    ledger.undo(token)
    #expect(ledger.state.txn(carrefour.id)?.projectID == nil)
    try ledger.apply(.assignProject([carrefour.id], id))

    try ledger.apply(.setProjectCountInPlan(id, true))
    #expect(ledger.state.spent("groceries", in: MayaLedger.october) == groceries)

    let done = try #require(try ledger.apply(.completeProject(id, true)))
    #expect(ledger.state.project(id)?.complete == true)
    #expect(ledger.state.project(id)?.completedOn == MayaLedger.now.date)
    #expect(PlanEngine.projects(ledger.state, now: MayaLedger.now).completed.map(\.id) == [id])
    ledger.undo(done)
    #expect(ledger.state.project(id)?.complete == false)

    try ledger.apply(.saveProject(id, ProjectDraft(name: "Kitchen refresh", glyph: .rent)))
    #expect(ledger.state.project(id)?.budget == nil && ledger.state.project(id)?.name == "Kitchen refresh")

    try ledger.apply(.removeProject(id))
    #expect(ledger.state.project(id) == nil)
    #expect(ledger.state.spent("groceries", in: MayaLedger.october) == groceries)
  }

  @Test func removingAProjectTakesItsTransactionsOut() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.assignProject(["carrefour"], "japan"))
    #expect(ledger.state.txn("carrefour")?.projectID == "japan")
    try ledger.apply(.removeProject("japan"))
    #expect(ledger.state.project("japan") == nil)
    #expect(ledger.state.txns.allSatisfy { $0.projectID != "japan" })
    #expect(ledger.state.txn("carrefour")?.projectID == nil)
    #expect(ledger.state.txn("emirates")?.projectID == nil)
  }

  @Test func candidatesIncludeMoneyInButNotTransfersOrArchived() throws {
    var s = MayaLedger.state
    let refund = try #require(s.txns.firstIndex { $0.direction == .in && !$0.isTransfer && !$0.archived })
    let refundID = s.txns[refund].id
    s.txns[refund].projectID = nil
    let rows = PlanEngine.projectCandidates("japan", s, filter: ProjectCandidateFilter())
    #expect(rows.contains { $0.id == refundID })
    #expect(rows.allSatisfy { row in
      let t = s.txn(row.id)!
      return !t.isTransfer && !t.archived && !t.isHeldCopy
    })
  }

  @Test func refusals() {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.invalidProject) { try ledger.apply(.saveProject("x", ProjectDraft(name: ""))) }
    #expect(throws: ActionError.invalidProject) {
      try ledger.apply(.saveProject("x", ProjectDraft(name: "Trip", budget: .aed(0))))
    }
    #expect(throws: ActionError.self) { try ledger.apply(.assignProject(["carrefour"], "no-such-project")) }
    #expect(throws: ActionError.self) { try ledger.apply(.completeProject("no-such-project", true)) }
  }
}
