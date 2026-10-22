import CoreCategorize
import CoreDomain
import CoreJSON
import CoreProjection
import CoreReplay
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Check suggestions")
struct CheckSuggestionsTests {
  typealias Mapper = LiveLedgerMapperTests

  static func suggested(_ a: Mapper.Account, suite: String) async throws -> (LiveLedgerStore, [String]) {
    var ids: [String] = []
    var blobs: [AuthoredBlob] = []
    let merchants = [("QWERTY BISTRO", "10:00:00", "4100", "3"), ("ASDF GRILL", "12:00:00", "5200", "4"),
                     ("ZXCV NOODLES", "14:00:00", "6300", "5")]
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      for (i, m) in merchants.enumerated() {
        var row = LiveUndoTests.alert(grant: "u/mbx-a", message: "s\(i)", at: m.1, merchant: m.0, minor: m.2)
        row["category"] = .null
        row["category_source"] = nil
        row["needs_review"] = .bool(true)
        ids.append(try o.ingest(payload: row, ingestID: String(repeating: m.3, count: 64)))
      }
    }) { blobs.append(b) }
    let store = try await LiveUndoTests.store(a, suite: suite, extra: blobs)
    let rows = try ids.map { try #require(try a.projection.reader.txn($0)) }
    let suggest = try a.observer.stamps.build(try await a.observer.authorContext()) { o throws(AuthorError) in
      for r in rows {
        o.categorize(
          txnID: r.id, parentVersion: r.version, category: "dining", needsReview: true,
          source: CoreReplay.CategorySource(kind: .model, model: "cf-clef/1"))
      }
    }
    if let suggest { try await a.outbox.enqueue(suggest.ops) }
    try await a.observer.reproject()
    await store.reload()
    return (store, ids)
  }

  @Test func usingSuggestionsIsOneEditWithOneUndo() async throws {
    let a = try Mapper.account()
    let (store, ids) = try await Self.suggested(a, suite: "suggestions.use.tests")
    let app = AppModel(store: store)
    let snap = SuggestionsEngine.snapshot(store.state)
    #expect(Set(snap.rows.map(\.id)).isSuperset(of: ids))
    #expect(snap.rows.first { $0.id == ids[0] }?.source == "Suggested by Cloudflare AI")
    let uses = ids.map { SuggestionUse(txn: $0, category: "dining") }
    #expect(app.perform(.useSuggestions(uses)))
    #expect(app.toast?.title == "Used 3 suggestions")
    #expect(app.toast?.actionTitle == "Undo" && app.toast?.earlier.isEmpty == true)
    #expect(ids.allSatisfy { store.state.txn($0)?.inReview == false })
    func row(_ id: String) throws -> TxnRow? { try a.projection.reader.txn(id) }
    try await Mapper.eventually { try ids.allSatisfy { try row($0)?.categorySource == "user" } }
    for id in ids {
      let r = try #require(try row(id))
      #expect(r.category == "dining" && !r.needsReview && r.categorySource == "user")
    }
    app.toastAction()
    try await Mapper.eventually { try ids.allSatisfy { try row($0)?.needsReview == true } }
    for id in ids {
      let r = try #require(try row(id))
      #expect(r.category == "dining" && r.needsReview && r.categorySource == "model" && r.categorySourceRef == "cf-clef/1")
    }
    try await Mapper.eventually { SuggestionsEngine.count(store.state) == snap.count }
    #expect(SuggestionsEngine.count(store.state) == snap.count)
  }

  @Test func aRowChangedElsewhereIsLeftAlone() async throws {
    let a = try Mapper.account()
    let (store, ids) = try await Self.suggested(a, suite: "suggestions.elsewhere.tests")
    let moved = try #require(try a.projection.reader.txn(ids[2]))
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      o.categorize(txnID: moved.id, parentVersion: moved.version, category: "groceries", needsReview: false)
    }) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    #expect(store.state.txn(ids[2])?.inReview == true)
    try store.apply(.useSuggestions(ids.map { SuggestionUse(txn: $0, category: "dining") }))
    try await Mapper.eventually { try a.projection.reader.txn(ids[0])?.needsReview == false }
    try await Mapper.eventually { store.state.txn(ids[2])?.categoryID == "groceries" }
    #expect(try a.projection.reader.txn(ids[0])?.category == "dining")
    #expect(try a.projection.reader.txn(ids[1])?.category == "dining")
    #expect(try a.projection.reader.txn(ids[2])?.category == "groceries")
    #expect(store.state.txn(ids[2])?.categoryID == "groceries")
  }

  @Test func theToastCountsOnlyTheRowsTheAuthorWrites() async throws {
    let a = try Mapper.account()
    let (store, ids) = try await Self.suggested(a, suite: "suggestions.filter.tests")
    let app = AppModel(store: store)
    let uses = [
      SuggestionUse(txn: ids[0], category: "dining"), SuggestionUse(txn: ids[1], category: "groceries"),
      SuggestionUse(txn: ids[2], category: "dining"), SuggestionUse(txn: ids[0], category: "dining"),
    ]
    #expect(app.perform(.useSuggestions(uses)))
    #expect(app.toast?.title == "Used 2 suggestions")
    #expect(store.state.txn(ids[1])?.inReview == true && store.state.txn(ids[1])?.categorySource == .model(tag: "cf-clef/1"))
    try await Mapper.eventually { try a.projection.reader.txn(ids[2])?.categorySource == "user" }
    let written = try ids.filter { try a.projection.reader.txn($0)?.categorySource == "user" }
    #expect(written == [ids[0], ids[2]])
    #expect(store.state.txn(ids[1])?.inReview == true)
  }

  @Test func aFailedUndoKeepsItsTokenAndARetryFinishesWithoutWritingTwice() async throws {
    let a = try Mapper.account()
    let (_, ids) = try await Self.suggested(a, suite: "suggestions.retry.seed")
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox, undoChunkSize: 2),
      profile: Mapper.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "suggestions.retry.tests")!),
      clock: { MayaLedger.now })
    await store.reload()
    var failed = 0
    store.onWriteFailed = { failed += 1 }
    func row(_ id: String) throws -> TxnRow? { try a.projection.reader.txn(id) }
    let token = try #require(try store.apply(.useSuggestions(ids.map { SuggestionUse(txn: $0, category: "dining") })))
    try await Mapper.eventually { try ids.allSatisfy { try row($0)?.categorySource == "user" } }
    store.undos[token.id]?.append(.category(txn: "no-such-txn", category: nil, needsReview: true))
    store.undo(token)
    try await Mapper.eventually { failed == 1 }
    #expect(failed == 1 && store.canUndo(token))
    #expect(try row(ids[0])?.categorySource == "model" && row(ids[1])?.categorySource == "model")
    #expect(try row(ids[2])?.categorySource == "user")
    let versions = try ids.prefix(2).map { try #require(try row($0)).version }
    store.undos[token.id]?.removeLast()
    store.undo(token)
    try await Mapper.eventually { try row(ids[2])?.categorySource == "model" }
    #expect(try row(ids[2])?.needsReview == true && failed == 1)
    #expect(try ids.prefix(2).map { try #require(try row($0)).version } == versions)
    #expect(!store.canUndo(token))
  }

  @Test func anUndoRunTwiceWritesOnce() async throws {
    let a = try Mapper.account()
    let (_, ids) = try await Self.suggested(a, suite: "suggestions.twice.tests")
    let author = LedgerEditAuthor(observer: a.observer, outbox: a.outbox)
    let before = try #require(try a.projection.reader.txn(ids[0]))
    let inverse = LedgerEditAuthor.Inverse.category(txn: ids[0], category: "groceries", needsReview: false)
    try await author.undo([inverse, .note(txn: ids[0], note: "")])
    let once = try #require(try a.projection.reader.txn(ids[0]))
    #expect(once.category == "groceries" && once.version == before.version + 1)
    try await author.undo([inverse, .note(txn: ids[0], note: "")])
    #expect(try a.projection.reader.txn(ids[0])?.version == once.version)
  }

  @Test func undoWritesBackInBlobsOfAtMostTheSweepSize() {
    #expect(LedgerEditAuthor.undoChunk * 2 <= Sweep.maxOpsPerBlob)
  }

  @Test func theSheetUsesTheTickedOnesAndTheToastTakesThemBack() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaSuggestions.state))
    #expect(app.suggestionCount == 7)
    let model = CheckSuggestionsModel(app: app)
    #expect(model.chosen == 7)
    model.toggle("sug-tim-8")
    #expect(!model.isOn("sug-tim-8") && model.chosen == 6)
    #expect(model.use())
    #expect(app.toast?.title == "Used 6 suggestions" && app.toast?.actionTitle == "Undo")
    #expect(app.suggestionCount == 1)
    #expect(model.snapshot.rows.map(\.id) == ["sug-tim-8"])
    app.toastAction()
    #expect(app.suggestionCount == 7)
    #expect(model.chosen == 7)
  }

  @Test func theEntryOpensTheSheet() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaSuggestions.state))
    app.openCheckSuggestions()
    #expect(app.sheet == .checkSuggestions)
  }

  @Test func usingNoneDoesNothing() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaSuggestions.state))
    let model = CheckSuggestionsModel(app: app)
    for row in model.snapshot.rows { model.toggle(row.id) }
    #expect(model.chosen == 0)
    #expect(!model.use())
    #expect(app.toast == nil)
    #expect(app.suggestionCount == 7)
  }
}
