import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("Check suggestions")
struct SuggestionsEngineTests {
  @Test func groupsTheModelSuggestionsByCategory() {
    let snap = SuggestionsEngine.snapshot(Scenario.mayaSuggestions.state)
    #expect(snap.groups.map(\.title) == [
      "Dining · 3 payments · 2 merchants",
      "Groceries · 2 payments · 2 merchants",
      "Subscriptions · 1 payment · 1 merchant",
      "Transport · 1 payment · 1 merchant",
    ])
    #expect(snap.count == 7)
    #expect(SuggestionsEngine.count(Scenario.mayaSuggestions.state) == 7)
    #expect(snap.groups[0].rows.map(\.id) == ["sug-shake-9", "sug-tim-8", "sug-shake-4"])
    #expect(snap.groups[1].rows.map(\.id) == ["lulu", "sug-almaya-7"])
    #expect(snap.groups[0].rows[0].detail == "Fri 9 Oct · Suggested by Cloudflare AI")
    #expect(snap.allFromCloudflare)
    #expect(snap.lead == "Cloudflare's AI suggested these. Untick any that are wrong, then use the rest.")
  }

  @Test func theDefaultScenarioHasOnlyLulu() {
    let snap = SuggestionsEngine.snapshot(Scenario.maya.state)
    #expect(snap.rows.map(\.id) == ["lulu"])
    #expect(snap.count == 1)
  }

  @Test func onlyRowsInReviewWithAModelSuggestionCount() {
    var s = MayaLedger.state
    let base = Txn(id: "x", merchant: "Test Cafe", amount: .aed(10_00), postedAt: LocalDateTime(2026, 10, 9, 10, 0))
    var live = base
    live.id = "live"
    live.categoryID = "dining"
    live.categorySource = .model(tag: "cf-clef/1")
    live.needsReview = true
    var apple = base
    apple.id = "apple-fm"
    apple.categoryID = "dining"
    apple.categorySource = .model(tag: "apple-fm/1")
    apple.needsReview = true
    var filed = live
    filed.id = "filed"
    filed.needsReview = false
    var unverified = live
    unverified.id = "unverified"
    unverified.reviewReason = .senderUnverified
    var dictionary = base
    dictionary.id = "dictionary"
    dictionary.needsReview = true
    dictionary.suggestion = "dining"
    var archived = live
    archived.id = "archived"
    archived.archived = true
    s.txns = [live, apple, filed, unverified, dictionary, archived]
    let snap = SuggestionsEngine.snapshot(s)
    #expect(snap.rows.map(\.id).sorted() == ["apple-fm", "live"])
    #expect(snap.rows.first { $0.id == "apple-fm" }?.source == "Suggested on this iPhone")
    #expect(!snap.allFromCloudflare)
    #expect(snap.lead == "These are suggestions. Untick any that are wrong, then use the rest.")
    s.skippedReview = ["live"]
    #expect(SuggestionsEngine.snapshot(s).rows.map(\.id) == ["apple-fm"])
  }

  @Test func untickedRowsAreLeftOut() {
    let snap = SuggestionsEngine.snapshot(Scenario.mayaSuggestions.state)
    let uses = SuggestionsEngine.uses(snap, unticked: ["sug-tim-8", "apple"])
    #expect(uses.count == 5)
    #expect(!uses.contains { $0.txn == "sug-tim-8" || $0.txn == "apple" })
    #expect(uses.first == SuggestionUse(txn: "sug-shake-9", category: "dining"))
    #expect(SuggestionsEngine.useLabel(5) == "Use 5 suggestions")
    #expect(SuggestionsEngine.useLabel(1) == "Use 1 suggestion")
  }

  @Test func usingThemIsOneEditAndOneUndo() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaSuggestions.state)
    let before = ReviewEngine.queue(ledger.state).count
    let uses = SuggestionsEngine.uses(SuggestionsEngine.snapshot(ledger.state), unticked: ["apple"])
    let token = try #require(try ledger.apply(.useSuggestions(uses)))
    #expect(token.title == "Used 6 suggestions")
    #expect(ReviewEngine.queue(ledger.state).count == before - 6)
    #expect(ledger.state.txn("sug-shake-9")?.categoryID == "dining")
    #expect(ledger.state.txn("sug-shake-9")?.categorySource == .user)
    #expect(SuggestionsEngine.snapshot(ledger.state).rows.map(\.id) == ["apple"])
    ledger.undo(token)
    #expect(ReviewEngine.queue(ledger.state).count == before)
    #expect(ledger.state.txn("sug-shake-9")?.categorySource == .model(tag: "cf-clef/1"))
    #expect(SuggestionsEngine.snapshot(ledger.state).count == 7)
  }

  @Test func onlyRowsStillSuggestedThatCategoryAreUsed() throws {
    var state = Scenario.mayaSuggestions.state
    let i = try #require(state.txns.firstIndex { $0.id == "sug-tim-8" })
    state.txns[i].categorySource = .rule(pattern: "TIM")
    let ledger = InMemoryLedger(state: state)
    let uses = [
      SuggestionUse(txn: "sug-shake-9", category: "dining"), SuggestionUse(txn: "sug-shake-4", category: "groceries"),
      SuggestionUse(txn: "sug-tim-8", category: "dining"), SuggestionUse(txn: "sug-shake-9", category: "dining"),
    ]
    let token = try #require(try ledger.apply(.useSuggestions(uses)))
    #expect(token.title == "Used 1 suggestion")
    #expect(ledger.state.txn("sug-shake-9")?.categorySource == .user)
    #expect(ledger.state.txn("sug-shake-4")?.categorySource == .model(tag: "cf-clef/1"))
    #expect(ledger.state.txn("sug-tim-8")?.needsReview == true)
  }

  @Test func usingNothingIsRefused() {
    let ledger = InMemoryLedger(state: Scenario.mayaSuggestions.state)
    #expect(throws: ActionError.notFound) { try ledger.apply(.useSuggestions([])) }
    #expect(throws: ActionError.notFound) {
      try ledger.apply(.useSuggestions([SuggestionUse(txn: "carrefour", category: "groceries")]))
    }
  }
}
