import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// Search's "Try asking" offers only the rows whose word finds something in this iPhone's
/// own ledger (what a query finds is `ActivityReviewModelTests`'s).
@MainActor
@Suite("Search")
struct SearchTests {
  @Test func tryAskingOffersOnlyRowsThatFindSomething() {
    let store = InMemoryLedger()
    let all = SearchView.suggestions(in: store.state, now: store.now).map(\.term)
    #expect(all == ["dining", "rent", "carrefour"])

    var noCarrefour = store.state
    noCarrefour.txns.removeAll { $0.merchant.localizedCaseInsensitiveContains("carrefour") }
    noCarrefour.rules.removeAll { r in r.patterns.contains { $0.localizedCaseInsensitiveContains("carrefour") } }
    #expect(SearchView.suggestions(in: noCarrefour, now: store.now).map(\.term) == ["dining", "rent"])

    var empty = store.state
    empty.txns = []
    empty.rules = []
    empty.categories = []
    #expect(SearchView.suggestions(in: empty, now: store.now).isEmpty)
  }

  @Test func resultsCarryTheirProject() {
    let store = InMemoryLedger()
    let found = SearchResults("Emirates", store.state, now: store.now)
    #expect(found.rows.first { $0.id == "emirates" }?.project == MiniTxnRow.Project(id: "japan", name: "Japan trip"))
    #expect(SearchResults("Carrefour", store.state, now: store.now).rows.allSatisfy { $0.project == nil })
  }
}
