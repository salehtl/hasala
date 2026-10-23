import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Review deck · one card per merchant")
struct ReviewGroupDeckTests {
  static func app() -> AppModel { AppModel(store: InMemoryLedger(state: Scenario.mayaBacklog.state)) }

  static func group(_ deck: ReviewViewModel, _ ref: MerchantGroupRef) -> ReviewGroupCardModel? {
    for item in deck.items { if case .group(let g) = item, g.group == ref { return g } }
    return nil
  }

  @Test func thePositionCountsCardsAndAGroupSortFilesEveryWaitingPayment() throws {
    let app = Self.app()
    let deck = ReviewViewModel(app: app)
    #expect(deck.total == deck.items.count && deck.position == 1)
    #expect(deck.items.count < app.reviewCount)
    let g = try #require(Self.group(deck, MayaBacklog.tailscale))
    #expect(g.total == 30 && g.sortAllLabel("Subscriptions") == "Sort all 30 as Subscriptions")
    #expect(deck.sortGroup(g, into: "subscriptions", alwaysUse: true, project: nil))
    #expect(Self.group(deck, MayaBacklog.tailscale) == nil)
    #expect(deck.position == 2)
    let row = try #require(app.sortResult)
    #expect(row.count == 30 && row.canStopRule && row.undo != nil)
    #expect(deck.sorted.count == g.txnIDs.count)
    #expect(deck.sorted.filter(\.learnedRule).count == 1)
    #expect(deck.groupFiledAnnouncement(g, as: "Subscriptions") == "Filed 30 Tailscale payments as Subscriptions. \(deck.items.count) left.")
    #expect(app.toast == nil, "a group sort reports in its result row, not a toast")
    app.undoSortResult()
    #expect(Self.group(deck, MayaBacklog.tailscale) != nil)
    #expect(app.sortResult == nil)
  }

  @Test func notThisLeavesANoteAndUndoBringsTheGuessBack() throws {
    let app = Self.app()
    let deck = ReviewViewModel(app: app)
    let g = try #require(Self.group(deck, MayaBacklog.brightwellGroup))
    #expect(g.suggestion?.id == "shopping" && g.useAllLabel == "Use for all 4")
    let item = ReviewItem.group(g)
    #expect(deck.notThis(item))
    #expect(deck.notes[item.id]?.line == "Hasala won't suggest Shopping for Brightwell Academy again.")
    #expect(Self.group(deck, MayaBacklog.brightwellGroup)?.suggestion == nil)
    deck.undoNotThis(item.id)
    #expect(deck.notes[item.id] == nil)
    #expect(Self.group(deck, MayaBacklog.brightwellGroup)?.suggestion?.id == "shopping")
  }

  @Test func aSwipeOnAGroupAsksAndSkipTakesTheWholeCard() throws {
    let app = Self.app()
    let deck = ReviewViewModel(app: app)
    let g = try #require(Self.group(deck, MayaBacklog.qasrGroup))
    deck.pickGroup(g, .need)
    let pick = try #require(deck.picking)
    #expect(pick.group == g && g.txnIDs.contains(pick.card.id))
    #expect(deck.options(for: .need, card: pick.card.id).contains { $0.id == "groceries" })
    deck.picking = nil
    #expect(deck.groupRows(g).count == g.total)
    deck.skipItem(.group(g))
    #expect(Self.group(deck, MayaBacklog.qasrGroup) == nil)
    #expect(g.txnIDs.allSatisfy { app.store.state.skippedReview.contains($0) })
  }

  @Test func theListOpensTheDeckAtAGroupRow() throws {
    let app = Self.app()
    let items = app.reviewItems
    let rows = items.map { ReviewEngine.tabRow($0, app.store.state) }
    let tailscale = try #require(rows.first { $0.identifier == "review.tab.group.out.n:tailscale" })
    #expect(tailscale.detail.hasSuffix(" payments") && tailscale.title == "Tailscale")
    ReviewEntry.request(app, at: tailscale.item)
    let deck = ReviewViewModel(app: app)
    #expect(deck.items.first?.id == tailscale.item)
    let single = try #require(rows.first { $0.identifier == "review.tab.row.bl-ts-unverified" })
    #expect(single.subtitle == "Couldn't verify sender · you decide")
    ReviewEntry.request(app, at: "bl-ts-02")
    #expect(ReviewViewModel(app: app).items.first?.id == tailscale.item)
  }
}
