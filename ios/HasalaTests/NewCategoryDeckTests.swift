import CoreCategorize
import CoreDomain
import CoreOutbox
import CoreProjection
import CoreTime
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Deck: a new category while sorting")
struct NewCategoryDeckTests {
  typealias Mapper = LiveLedgerMapperTests
  typealias Sorting = LiveSortingTests

  static func deck(at card: TxnID, _ state: LedgerState = Scenario.mayaBacklog.state) -> (AppModel, ReviewViewModel) {
    LastPickDeckTests.deck(at: card, state)
  }

  @Test func theRowIsOfferedForNeedWantAndSaveOnMoneyOutOnly() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2")
    let s = app.store.state
    for choice in [ReviewChoice.need, .want, .save] {
      let offer = try #require(deck.newCategory(for: choice, card: "bl-alnoor-t-2"))
      #expect(offer.bucket == choice.bucket)
      #expect(offer == CategoriesEngine.countsAsOptions(s, keeping: []).first { $0.bucket == choice.bucket })
      #expect(CategoriesEngine.isOfferedParent(offer.parent, in: s))
    }
    #expect(deck.newCategory(for: .transfer, card: "bl-alnoor-t-2") == nil)
    #expect(s.txn("bl-ts-refund")?.direction == .in)
    for choice in ReviewChoice.allCases { #expect(deck.newCategory(for: choice, card: "bl-ts-refund") == nil) }
    #expect(deck.newCategory(for: .need, card: "no-such-card") == nil)
  }

  @Test func theRowIsHiddenAtTwentyCustomCategoriesAndSaveIsRefused() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaBacklog.state)
    for i in CategoriesEngine.activeCustomCount(ledger.state)..<CategoryLimits.maxActiveCustom {
      try ledger.apply(.addCategory(CategoryDraft(name: "Cap \(i)", parent: "dining")))
    }
    let app = AppModel(store: ledger)
    ReviewEntry.request(app, at: "bl-alnoor-t-2")
    let deck = ReviewViewModel(app: app)
    #expect(deck.newCategory(for: .need, card: "bl-alnoor-t-2") == nil)
    let before = ledger.state
    #expect(deck.newCategoryRefusal("bl-alnoor-t-2", .need, name: "Corner shop", glyph: .groceries) == CategoryLimits.atCap)
    #expect(ledger.state == before && app.toast == nil)
    #expect(!deck.createAndSort("bl-alnoor-t-2", .need, name: "Corner shop", glyph: .groceries, alwaysUse: false, project: nil))
    #expect(ledger.state == before)
    #expect(app.toast?.title == CategoryLimits.atCap && app.toast?.undo == nil)
  }

  @Test func aRefusedNameShowsWhyAndWritesNothing() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2")
    let before = app.store.state
    let revision = app.store.revision
    func save(_ name: String, _ choice: ReviewChoice = .need) -> String? {
      deck.newCategoryRefusal("bl-alnoor-t-2", choice, name: name, glyph: .groceries)
    }
    #expect(save(" groceries") == CategoryLimits.nameTaken("Groceries"))
    #expect(save("DINING", .want) == CategoryLimits.nameTaken("Dining"))
    #expect(save("  ") == CategoryLimits.nameEmpty)
    #expect(save(String(repeating: "a", count: CategoryLimits.maxName + 1)) == CategoryLimits.nameTooLong)
    #expect(save("Corner shop", .transfer) == CategoryLimits.cannotAdd)
    #expect(app.store.state == before && app.store.revision == revision)
    #expect(app.toast == nil)
    #expect(deck.cards.first?.id == "bl-alnoor-t-2" && deck.position == 1 && deck.sorted.isEmpty)

    #expect(!deck.createAndSort("bl-alnoor-t-2", .need, name: "groceries", glyph: .groceries, alwaysUse: true, project: nil))
    #expect(app.store.state == before && app.store.revision == revision)
    #expect(app.toast?.title == CategoryLimits.nameTaken("Groceries") && app.toast?.undo == nil)
    #expect(deck.cards.first?.id == "bl-alnoor-t-2" && deck.sorted.isEmpty)
  }

  @Test func saveAddsTheCategoryInTheSwipesBucketAndSortsTheCardIntoIt() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2")
    let offer = try #require(deck.newCategory(for: .need, card: "bl-alnoor-t-2"))
    let custom = CategoriesEngine.activeCustomCount(app.store.state)
    let rules = app.store.state.rules
    #expect(
      deck.createAndSort("bl-alnoor-t-2", .need, name: " Corner shop ", glyph: .groceries, alwaysUse: false, project: nil))
    let s = app.store.state
    let c = try #require(s.categories.first { $0.name == "Corner shop" })
    #expect(!c.builtin && c.parent == offer.parent && c.bucket == .needs && c.glyph == .groceries)
    #expect(CategoriesEngine.activeCustomCount(s) == custom + 1)
    let t = try #require(s.txn("bl-alnoor-t-2"))
    #expect(t.categoryID == c.id && t.categorySource == .user && !t.inReview)
    #expect(s.rules == rules)
    #expect(app.toast?.title == "Sorted into Corner shop" && app.toast?.actionTitle == "Undo")
    let next = try #require(deck.cards.first)
    #expect(next.id == "bl-alnoor-t-3" && deck.position == 2)
    #expect(next.suggestion?.id == c.id && next.suggestedBy == "Your last pick")
    #expect(deck.options(for: .need, card: next.id).map(\.id) == ReviewEngine.options(for: .need, s).map(\.id))
    #expect(deck.options(for: .need, card: next.id).first?.id != c.id)
    #expect(deck.sorted.map(\.id) == ["bl-alnoor-t-2"] && deck.sorted.first?.detail == "Corner shop")

    app.toastAction()
    #expect(app.store.state.txn("bl-alnoor-t-2")?.inReview == true)
    #expect(app.store.state.category(c.id)?.archived == false)
  }

  @Test func theSheetChecksTheNameAndTheCardIsSortedOnceTheSheetHasGone() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2")
    let before = app.store.state
    #expect(deck.cards.first?.id == "bl-alnoor-t-2")
    deck.holding = "bl-alnoor-t-2"
    deck.pick("bl-alnoor-t-2", .need)
    #expect(deck.newCategoryRefusal("bl-alnoor-t-2", .need, name: "Corner shop", glyph: .groceries) == nil)
    #expect(app.store.state == before && app.toast == nil)
    deck.picking = nil
    #expect(deck.cards.first?.id == "bl-alnoor-t-2")
    #expect(deck.createAndSort("bl-alnoor-t-2", .need, name: "Corner shop", glyph: .groceries, alwaysUse: false, project: nil))
    deck.holding = nil
    #expect(deck.cards.first?.id == "bl-alnoor-t-3" && deck.position == 2)
    #expect(app.toast?.title == "Sorted into Corner shop")
  }

  @Test func alwaysUseAndTheProjectComeWithTheNewCategory() throws {
    let (app, deck) = Self.deck(at: "bl-qasr-4")
    let project = try #require(deck.projects(for: "bl-qasr-4").first?.id)
    #expect(deck.createAndSort("bl-qasr-4", .need, name: "Corner shop", glyph: .groceries, alwaysUse: true, project: project))
    let s = app.store.state
    let c = try #require(s.categories.first { $0.name == "Corner shop" })
    #expect(s.txn("bl-qasr-4")?.categoryID == c.id && s.txn("bl-qasr-4")?.projectID == project)
    #expect(s.rules.contains { $0.categoryID == c.id && $0.enabled })
    for id in ["bl-qasr-5", "bl-qasr-6"] { #expect(s.txn(id)?.categoryID == c.id && s.txn(id)?.inReview == false) }
    let line = try #require(app.toast)
    #expect(line.title.hasPrefix("Corner shop for all ") && line.title.hasSuffix(" Qasr Corner Store payments"), "\(line.title)")
    #expect(line.actionTitle == "Undo")
    #expect(deck.sorted.first?.learnedRule == true)

    app.toastAction()
    let back = app.store.state
    for id in ["bl-qasr-4", "bl-qasr-5", "bl-qasr-6"] { #expect(back.txn(id)?.inReview == true, "\(id)") }
    #expect(!back.rules.contains { $0.categoryID == c.id })
    #expect(back.category(c.id) != nil)
  }

  @Test func liveSaveWritesTheCategoryAndTheSortTogetherAndARefusalWritesNothing() async throws {
    let l = try await Sorting.ledger(suite: "newcategory.deck.live", rows: Sorting.tailscale)
    var failed = false
    l.store.onWriteFailed = { failed = true }
    let txn = try #require(l.ids["com"]?.first)
    let refund = try #require(l.ids["refund"]?.first)
    let app = AppModel(store: l.store)
    ReviewEntry.request(app, at: txn)
    let deck = ReviewViewModel(app: app)
    let offer = try #require(deck.newCategory(for: .want, card: txn))
    #expect(offer.bucket == .wants)
    #expect(deck.newCategory(for: .want, card: refund) == nil)
    #expect(deck.newCategory(for: .transfer, card: txn) == nil)

    let pending = try l.a.context.store.pendingCount()
    let shown = l.store.state
    func check(_ name: String) -> String? { deck.newCategoryRefusal(txn, .want, name: name, glyph: .subscriptions) }
    func save(_ name: String) -> Bool {
      deck.createAndSort(txn, .want, name: name, glyph: .subscriptions, alwaysUse: false, project: nil)
    }
    #expect(check("dining") == CategoryRefusal.nameTaken("Dining").message)
    #expect(check("VPN\u{202E}") == CategoryRefusal.nameInvalid.message)
    #expect(app.toast == nil && l.store.state == shown)
    #expect(!save("VPN\u{202E}"))
    #expect(app.toast?.title == CategoryRefusal.nameInvalid.message && app.toast?.undo == nil)
    #expect(l.store.state == shown)
    try await Task.sleep(for: .milliseconds(200))
    #expect(try l.a.context.store.pendingCount() == pending)
    #expect(try l.row(txn)?.needsReview == true)

    #expect(save("VPN"))
    #expect(app.toast?.title == "Sorted into VPN" && app.toast?.actionTitle == "Undo")
    let id = try #require(l.store.state.categories.first { $0.name == "VPN" }?.id)
    #expect(OpAuthor.isNewCategoryID(id))
    #expect(l.store.state.txn(txn)?.categoryID == id)
    try await Mapper.eventually { try l.row(txn)?.category == id }
    #expect(try LiveCategoryTests.newOps(l.a, after: pending) == ["category_defined", "txn_categorized"])
    let c = try #require(try l.reader.taxonomy().info(id))
    #expect(c.name == "VPN" && c.parent == offer.parent && c.icon == LedgerEditAuthor.icon(.subscriptions) && c.active && !c.builtin)
    let row = try #require(try l.row(txn))
    #expect(row.categorySource == "user" && !row.needsReview)
    #expect(deck.sorted.map(\.id) == [txn])
    #expect(!failed)
  }

  @Test func liveARefusedNameOnAHeldCopyWritesNothingAtAll() async throws {
    let a = try Mapper.account()
    var copy = ""
    var blobs: [AuthoredBlob] = []
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      try o.ingest(
        payload: LiveUndoTests.alert(grant: "u/mbx-a", message: "m1", at: "08:00:00"), ingestID: String(repeating: "c", count: 64))
      copy = try o.ingest(
        payload: LiveUndoTests.alert(grant: "u/mbx-b", message: "m2", at: "08:05:00"), ingestID: String(repeating: "d", count: 64))
    }) { blobs.append(b) }
    let store = try await LiveUndoTests.store(a, suite: "newcategory.deck.heldcopy", extra: blobs)
    var failed = false
    store.onWriteFailed = { failed = true }
    #expect(store.state.txn(copy)?.isHeldCopy == true)
    let app = AppModel(store: store)
    ReviewEntry.request(app, at: copy)
    let deck = ReviewViewModel(app: app)
    #expect(deck.newCategory(for: .want, card: copy) != nil)
    let pending = try a.context.store.pendingCount()
    let shown = store.state
    let bidi = "VPN\u{202E}"
    #expect(deck.newCategoryRefusal(copy, .want, name: bidi, glyph: .subscriptions) == CategoryRefusal.nameInvalid.message)
    #expect(!deck.createAndSort(copy, .want, name: bidi, glyph: .subscriptions, alwaysUse: false, project: nil))
    #expect(app.toast?.title == CategoryRefusal.nameInvalid.message && app.toast?.undo == nil)
    #expect(store.state == shown)
    try await Task.sleep(for: .milliseconds(200))
    #expect(try a.context.store.pendingCount() == pending)
    #expect(try a.projection.reader.txn(copy)?.heldCopy == true)
    #expect(store.state.txn(copy)?.isHeldCopy == true)
    #expect(!failed)
  }
}
