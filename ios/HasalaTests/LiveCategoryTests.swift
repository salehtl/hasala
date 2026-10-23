import CoreCategorize
import CoreDomain
import CoreOutbox
import CoreProjection
import CoreTime
import Foundation
import HasalaMocks
import HasalaModels
import Synchronization
import Testing

@testable import Hasala

@MainActor
@Suite("Live categories")
struct LiveCategoryTests {
  typealias Mapper = LiveLedgerMapperTests

  static func custom(_ a: Mapper.Account, _ name: String) throws -> CategoryInfo? {
    try a.projection.reader.taxonomy().ordered.first { !$0.builtin && $0.name == name }
  }

  @Test func createEditArchiveAndRestoreAreAuthored() async throws {
    let a = try Mapper.account()
    let store = try await LiveUndoTests.store(a, suite: "categories.live.tests")
    var failed = false
    store.onWriteFailed = { failed = true }

    #expect(try store.apply(.addCategory(CategoryDraft(name: "Coffee", glyph: .dining, parent: "dining"))) == nil)
    let shown = try #require(store.state.categories.first { $0.name == "Coffee" })
    #expect(OpAuthor.isNewCategoryID(shown.id))
    try await Mapper.eventually { try Self.custom(a, "Coffee") != nil }
    let coffee = try #require(try Self.custom(a, "Coffee"))
    #expect(coffee.id == shown.id)
    #expect(store.state.categories.filter { $0.name == "Coffee" }.map(\.id) == [shown.id])
    #expect(coffee.parent == "dining" && coffee.kind == .spending && coffee.bucket == .want && coffee.icon == "fork_knife" && coffee.active)
    let ids = store.state.categories.map(\.id)
    #expect(ids.firstIndex(of: coffee.id) == ids.firstIndex(of: "dining").map { $0 + 1 })
    #expect(store.state.category(coffee.id)?.parent == "dining")
    #expect(store.state.category("dining")?.builtin == true)

    #expect(throws: ActionError.refused("You already have a category named Coffee.")) {
      try store.apply(.addCategory(CategoryDraft(name: "coffee", parent: "travel")))
    }
    #expect(throws: ActionError.refused("This category is needed and cannot be hidden.")) {
      try store.apply(.archiveCategory("transfer", moveTo: nil))
    }

    try store.apply(.editCategory(coffee.id, CategoryDraft(name: "Coffee beans", glyph: .groceries, parent: "groceries")))
    try await Mapper.eventually { try Self.custom(a, "Coffee beans")?.parent == "groceries" }
    let edited = try #require(try Self.custom(a, "Coffee beans"))
    #expect(edited.id == coffee.id && edited.bucket == .need && edited.icon == "basket")

    let row = try #require(store.state.txns.first { !$0.archived && $0.splits.isEmpty && $0.categoryID != nil && !$0.isHeldCopy })
    try store.apply(.categorize(row.id, coffee.id, learnRule: false, project: nil))
    try store.apply(.setBudget(coffee.id, MayaLedger.october, .aed(50_00)))
    try await Mapper.eventually { try a.projection.reader.txn(row.id)?.category == coffee.id }
    try await Mapper.eventually { try LiveUndoTests.assigned(a, coffee.id, LiveUndoTests.october) == 50_00 }
    let groceries = try LiveUndoTests.assigned(a, "groceries", LiveUndoTests.october)

    try store.apply(.archiveCategory(coffee.id, moveTo: "groceries"))
    try await Mapper.eventually { try Self.custom(a, "Coffee beans")?.active == false }
    #expect(try Self.custom(a, "Coffee beans")?.active == false)
    #expect(try a.projection.reader.txn(row.id)?.category == "groceries")
    #expect(try LiveUndoTests.assigned(a, coffee.id, LiveUndoTests.october) == 0)
    #expect(try LiveUndoTests.assigned(a, coffee.id, LiveUndoTests.november) == 0)
    #expect(try LiveUndoTests.assigned(a, "groceries", LiveUndoTests.october) == groceries + 50_00)
    try await Mapper.eventually { store.state.category(coffee.id)?.archived == true }
    #expect(CategoriesEngine.snapshot(store.state).archived.map(\.id) == [coffee.id])

    try store.apply(.restoreCategory(coffee.id))
    try await Mapper.eventually { try Self.custom(a, "Coffee beans")?.active == true }
    #expect(try Self.custom(a, "Coffee beans")?.active == true)
    #expect(!failed)
  }

  @Test func hidingABuiltInMovesItsBudgetToReadyToAssign() async throws {
    let a = try Mapper.account()
    let store = try await LiveUndoTests.store(a, suite: "categories.hide.tests")
    try store.apply(.setBudget("travel", MayaLedger.october, .aed(120_00)))
    try await Mapper.eventually { try LiveUndoTests.assigned(a, "travel", LiveUndoTests.october) == 120_00 }
    try store.apply(.archiveCategory("travel", moveTo: nil))
    try await Mapper.eventually { try a.projection.reader.taxonomy().info("travel")?.active == false }
    #expect(try a.projection.reader.taxonomy().info("travel")?.active == false)
    #expect(try LiveUndoTests.assigned(a, "travel", LiveUndoTests.october) == 0)
    #expect(try a.projection.reader.planState().moves.values.contains { $0.from == "travel" && $0.to == nil })
    try store.apply(.restoreCategory("travel"))
    try await Mapper.eventually { try a.projection.reader.taxonomy().info("travel")?.active == true }
    #expect(try a.projection.reader.taxonomy().info("travel")?.name == "Travel")
  }

  @Test func customCategoriesFollowTheirParent() {
    func info(_ id: String, builtin: Bool, parent: String? = nil) -> CategoryInfo {
      CategoryInfo(id: id, name: id, kind: .spending, bucket: .want, icon: "tag", active: true, builtin: builtin, sortKey: 0, parent: parent)
    }
    let ordered = [
      info("dining", builtin: true), info("travel", builtin: true), info("c_a", builtin: false, parent: "travel"),
      info("c_b", builtin: false, parent: "dining"), info("c_old", builtin: false),
    ]
    #expect(LedgerStateMapper.byParent(ordered).map(\.id) == ["dining", "c_b", "travel", "c_a", "c_old"])
  }

  @Test func liveRulesKeepAParentlessCustomAndRefuseADuplicateRestore() {
    let parentless = CategoryInfo(
      id: "c_fund", name: "House fund", kind: .spending, bucket: .saving, icon: "jar", active: true, builtin: false, sortKey: 100)
    let old = CategoryInfo(
      id: "c_old", name: "Coffee", kind: .spending, bucket: .want, icon: "tag", active: false, builtin: false, sortKey: 101, parent: "dining")
    let new = CategoryInfo(
      id: "c_new", name: "Coffee", kind: .spending, bucket: .want, icon: "tag", active: true, builtin: false, sortKey: 102, parent: "dining")
    let view = TaxonomyView(TaxonomyV1.builtins + [parentless, old, new])
    let state = MayaLedger.state
    #expect(LedgerEditAuthor.categoryRefusal(.editCategory("c_fund", CategoryDraft(name: "Home fund", glyph: .savingsJar)), view: view, state: state) == nil)
    #expect(LedgerEditAuthor.changedParent(CategoryDraft(name: "Home fund"), of: parentless) == nil)
    #expect(
      LedgerEditAuthor.categoryRefusal(.restoreCategory("c_old"), view: view, state: state) == CategoryRefusal.nameTaken("Coffee").message)
  }

  @Test func theAppLimitsMatchTheCore() {
    #expect(CategoryLimits.maxActiveCustom == TaxonomyV1.maxActiveCustom)
    #expect(CategoryLimits.maxName == TaxonomyV1.maxNameScalars)
    #expect(CategoryLimits.systemIDs == Set(TaxonomyV1.systemIDs))
    #expect(CategoryLimits.parentIDs == TaxonomyV1.parentCandidates)
    #expect(CategoryLimits.atCap == CategoryRefusal.atCap(max: TaxonomyV1.maxActiveCustom).message)
    #expect(CategoryLimits.nameEmpty == CategoryRefusal.nameEmpty.message)
    #expect(CategoryLimits.nameTooLong == CategoryRefusal.nameTooLong(max: TaxonomyV1.maxNameScalars).message)
    #expect(CategoryLimits.parentNotAllowed == CategoryRefusal.parentNotAllowed.message)
    #expect(CategoryLimits.unknown == CategoryRefusal.unknownCategory.message)
    #expect(CategoryLimits.builtinLocked == CategoryRefusal.builtinLocked.message)
    #expect(CategoryLimits.systemCannotHide == CategoryRefusal.systemCannotHide.message)
    #expect(CategoryLimits.nameTaken("Coffee") == CategoryRefusal.nameTaken("Coffee").message)
    let ids = [
      "c_", "c_01jc0000000000000000000009", "c_mock1", "c_X", "c-1", "dining", "", "c_caf\u{E9}",
      "c_" + String(repeating: "a", count: 30), "c_" + String(repeating: "a", count: 31),
    ]
    for id in ids { #expect(CategoryLimits.isNewID(id) == OpAuthor.isNewCategoryID(id), "\(id)") }
    #expect((0..<20).allSatisfy { _ in OpAuthor.isNewCategoryID(CategoryDraft.fallbackID()) })
  }

  typealias Sorting = LiveSortingTests

  static func vpn(_ id: String) -> CategoryDraft { CategoryDraft(id: id, name: "VPN", glyph: .subscriptions, parent: "subscriptions") }

  static func newOps(_ a: Mapper.Account, after count: Int) throws -> [String] {
    try a.context.store.pendingOps().dropFirst(count).map(\.opType)
  }

  nonisolated final class Enqueues: CoreTime.Clock, Sendable {
    let ms: Int64
    private let reads = Mutex(0)
    init(ms: Int64) { self.ms = ms }
    var count: Int { reads.withLock { $0 } }
    func nowMs() -> Int64 {
      reads.withLock { $0 += 1 }
      return ms
    }
  }

  static func counted(_ l: Sorting.Ledger) -> (LedgerEditAuthor, Enqueues) {
    let enqueues = Enqueues(ms: Mapper.anchor)
    let outbox = Outbox(store: l.a.context.store, clock: enqueues, debounce: .seconds(3600), onAuthored: {})
    return (LedgerEditAuthor(observer: l.a.observer, outbox: outbox, memory: l.memory, trust: l.trust), enqueues)
  }

  struct Filing: Equatable {
    var category: String?
    var needsReview: Bool
    var source: String
    var ref: String?
  }

  static func filings(_ l: Sorting.Ledger) throws -> [String: Filing] {
    var out: [String: Filing] = [:]
    for id in l.ids.values.joined() {
      let r = try #require(try l.row(id))
      out[id] = Filing(category: r.category, needsReview: r.needsReview, source: r.categorySource, ref: r.categorySourceRef)
    }
    return out
  }

  @Test func theStoreMakesCategoryIDsInTheAuthorsFormat() async throws {
    let store = try await LiveUndoTests.store(try Mapper.account(), suite: "categories.ids.tests")
    let first = store.newCategoryID()
    let second = store.newCategoryID()
    #expect(OpAuthor.isNewCategoryID(first) && OpAuthor.isNewCategoryID(second) && first != second)
    #expect(first.utf8.count == 28)
  }

  @Test func addingAndSortingWritesTheCategoryAndTheSortInOneBlob() async throws {
    let l = try await Sorting.ledger(suite: "categories.sort.one", rows: Sorting.tailscale)
    var failed = false
    l.store.onWriteFailed = { failed = true }
    let txn = try #require(l.ids["com"]?.first)
    let before = try #require(try l.row(txn))
    let pending = try l.a.context.store.pendingCount()
    let id = l.store.newCategoryID()
    let unknown = l.store.newCategoryID()
    let shown = l.store.state
    #expect(throws: ActionError.notFound) {
      try l.store.apply(.addCategoryAndSort(Self.vpn(unknown), txn, alwaysUse: false, project: "no-such-project"))
    }
    #expect(l.store.state == shown)
    let token = try #require(try l.store.apply(.addCategoryAndSort(Self.vpn(id), txn, alwaysUse: false, project: nil)))
    #expect(token.title == "Sorted into VPN")
    #expect(l.store.state.category(id)?.name == "VPN" && l.store.state.txn(txn)?.categoryID == id)
    try await Mapper.eventually { try l.row(txn)?.category == id }
    #expect(try Self.newOps(l.a, after: pending) == ["category_defined", "txn_categorized"])
    let c = try #require(try l.reader.taxonomy().info(id))
    #expect(c.name == "VPN" && c.parent == "subscriptions" && c.active && !c.builtin)
    let row = try #require(try l.row(txn))
    #expect(row.categorySource == "user" && !row.needsReview)
    #expect(try l.reader.rules().isEmpty)
    #expect(try (l.ids["inc"] ?? []).allSatisfy { try l.row($0)?.category == nil })
    try await Mapper.eventually { l.store.state.category(id) != nil && l.store.state.txn(txn)?.categoryID == id }

    l.store.undo(token)
    try await Mapper.eventually { try l.row(txn)?.category == before.category }
    let back = try #require(try l.row(txn))
    #expect(back.category == before.category && back.needsReview == before.needsReview && back.categorySource == before.categorySource)
    #expect(try l.reader.taxonomy().info(id)?.active == true)
    #expect(!failed)
  }

  @Test func alwaysUseFilesWhatAddingThenSortingWould() async throws {
    let combined = try await Sorting.ledger(suite: "categories.sort.always", rows: Sorting.tailscale)
    let steps = try await Sorting.ledger(suite: "categories.sort.steps", rows: Sorting.tailscale)
    var failed = false
    combined.store.onWriteFailed = { failed = true }
    steps.store.onWriteFailed = { failed = true }
    let pending = try combined.a.context.store.pendingCount()
    let id = combined.store.newCategoryID()
    let txn = try #require(combined.ids["com"]?.first)
    let token = try #require(try combined.store.apply(.addCategoryAndSort(Self.vpn(id), txn, alwaysUse: true, project: nil)))
    let other = steps.store.newCategoryID()
    let twinTxn = try #require(steps.ids["com"]?.first)
    try steps.store.apply(.addCategory(Self.vpn(other)))
    let expected = try #require(try steps.store.apply(.categorize(twinTxn, other, learnRule: true, project: nil)))
    #expect(token.title == expected.title)

    try await Mapper.eventually { try !combined.reader.rules().isEmpty }
    try await Mapper.eventually { try !steps.reader.rules().isEmpty }
    try await Mapper.eventually { !combined.a.observer.writes.isBusy && !steps.a.observer.writes.isBusy }
    #expect(try Array(Self.newOps(combined.a, after: pending).prefix(2)) == ["category_defined", "txn_categorized"])
    func filed(_ l: Sorting.Ledger, _ category: String) throws -> [String: [Bool]] {
      try l.ids.mapValues { ids in try ids.map { try l.row($0)?.category == category } }
    }
    #expect(try filed(combined, id) == filed(steps, other))
    let rule = try #require(try combined.reader.rules().first)
    let twin = try #require(try steps.reader.rules().first)
    #expect(rule.category == id && twin.category == other && rule.patterns == twin.patterns && rule.match == twin.match)
    #expect(try filed(combined, id).values.flatMap { $0 }.filter { $0 }.count > 1)

    combined.store.undo(token)
    try await Mapper.eventually { try combined.reader.rules().isEmpty }
    try await Mapper.eventually { try combined.ids.values.joined().allSatisfy { try combined.row($0)?.category != id } }
    #expect(try combined.reader.rules().isEmpty)
    #expect(try combined.ids.values.joined().allSatisfy { try combined.row($0)?.category != id })
    #expect(try combined.reader.taxonomy().info(id)?.active == true)
    #expect(!failed)
  }

  @Test func aRefusedAddAndSortWritesNothing() async throws {
    let a = try Mapper.account()
    let store = try await LiveUndoTests.store(a, suite: "categories.sort.refused")
    let full = try a.observer.stamps.build(try await a.observer.authorContext()) { o throws(AuthorError) in
      for i in 0..<CategoryLimits.maxActiveCustom {
        o.defineCategory(
          id: "c_cap\(i)", name: "Cap \(i)", kind: .spending, bucket: .want, icon: "tag", active: true, parent: "dining")
      }
    }
    try await a.outbox.enqueue(try #require(full).ops)
    try await a.observer.reproject()
    await store.reload()
    var failed = false
    store.onWriteFailed = { failed = true }
    let row = try #require(store.state.txns.first { !$0.archived && $0.splits.isEmpty && !$0.isHeldCopy })
    let before = try #require(try a.projection.reader.txn(row.id))
    let pending = try a.context.store.pendingCount()
    let taxonomy = try a.projection.reader.taxonomy().ordered.map(\.id)
    func add(_ name: String, txn: String = row.id) throws {
      try store.apply(.addCategoryAndSort(CategoryDraft(name: name, parent: "dining"), txn, alwaysUse: true, project: nil))
    }
    #expect(throws: ActionError.refused(CategoryRefusal.nameTaken("Dining").message)) { try add(" dining") }
    #expect(throws: ActionError.refused(CategoryRefusal.nameTaken("Cap 1").message)) { try add("cap 1") }
    #expect(throws: ActionError.refused(CategoryRefusal.nameInvalid.message)) { try add("Tea\u{202E}") }
    #expect(throws: ActionError.refused(CategoryRefusal.nameTooLong(max: 24).message)) { try add(String(repeating: "a", count: 25)) }
    #expect(throws: ActionError.refused(CategoryRefusal.atCap(max: 20).message)) { try add("Tea") }
    for id in ["c_cap0", "dining", "c_Tea"] {
      #expect(throws: ActionError.refused(CategoryLimits.cannotAdd)) {
        try store.apply(.addCategoryAndSort(CategoryDraft(id: id, name: "Tea", parent: "dining"), row.id, alwaysUse: false, project: nil))
      }
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(try a.context.store.pendingCount() == pending)
    #expect(try a.projection.reader.taxonomy().ordered.map(\.id) == taxonomy)
    #expect(try a.projection.reader.txn(row.id) == before)
    #expect(store.state.txn(row.id)?.categoryID == row.categoryID)
    #expect(!failed)
  }

  @Test func aCategoryStillBeingWrittenCountsForTheNameAndTheCap() async throws {
    let a = try Mapper.account()
    let store = try await LiveUndoTests.store(a, suite: "categories.sort.queued")
    let room = CategoryLimits.maxActiveCustom - CategoriesEngine.activeCustomCount(store.state)
    let filled = try a.observer.stamps.build(try await a.observer.authorContext()) { o throws(AuthorError) in
      for i in 0..<(room - 1) {
        o.defineCategory(
          id: "c_fill\(i)", name: "Fill \(i)", kind: .spending, bucket: .want, icon: "tag", active: true, parent: "dining")
      }
    }
    try await a.outbox.enqueue(try #require(filled).ops)
    try await a.observer.reproject()
    await store.reload()
    var failed = false
    store.onWriteFailed = { failed = true }
    let row = try #require(store.state.txns.first { !$0.archived && $0.splits.isEmpty && !$0.isHeldCopy })
    let before = try #require(try a.projection.reader.txn(row.id))
    func add(_ name: String) throws {
      try store.apply(.addCategoryAndSort(CategoryDraft(name: name, parent: "dining"), row.id, alwaysUse: false, project: nil))
    }

    try store.apply(.addCategory(CategoryDraft(name: "Juice", parent: "dining")))
    #expect(throws: ActionError.refused(CategoryLimits.nameTaken("Juice"))) { try add(" juice") }
    #expect(throws: ActionError.refused(CategoryLimits.atCap)) { try add("Tea") }
    try await Mapper.eventually { try Self.custom(a, "Juice") != nil }
    try await Mapper.eventually { !a.observer.writes.isBusy }
    #expect(try a.projection.reader.taxonomy().ordered.filter { CategoryRules.nameKey($0.name) == "juice" }.count == 1)
    #expect(try Self.custom(a, "Tea") == nil)
    #expect(try a.projection.reader.txn(row.id) == before)
    #expect(!failed)
  }

  @Test func aNameTakenThroughSyncBeforeTheWriteLandsWritesNothing() async throws {
    let l = try await Sorting.ledger(suite: "categories.sort.late", rows: Sorting.tailscale)
    let txn = try #require(l.ids["com"]?.first)
    let before = try #require(try l.row(txn))
    let id = l.store.newCategoryID()
    #expect(try l.store.categoryRefusal(.addCategoryAndSort(Self.vpn(id), txn, alwaysUse: true, project: nil)) == nil)
    let synced = try l.a.observer.stamps.build(try await l.a.observer.authorContext()) { o throws(AuthorError) in
      o.defineCategory(
        id: "c_01jc0000000000000000000077", name: "vpn", kind: .spending, bucket: .want, icon: "tag", active: true,
        parent: "subscriptions")
    }
    try await l.a.outbox.enqueue(try #require(synced).ops)
    try await l.a.observer.reproject()
    let pending = try l.a.context.store.pendingCount()
    await #expect(throws: AuthorError.refused(CategoryRefusal.nameTaken("vpn").message)) {
      try await l.author.author(
        .addCategoryAndSort(Self.vpn(id), txn, alwaysUse: true, project: nil), before: l.store.state, today: MayaLedger.now.date)
    }
    #expect(try l.a.context.store.pendingCount() == pending)
    #expect(try l.reader.taxonomy().info(id) == nil)
    #expect(try l.row(txn) == before)
    #expect(try l.reader.rules().isEmpty)
  }

  @Test func alwaysUseWritesTheCategoryTheSortTheRuleAndTheReachInOneEnqueue() async throws {
    let l = try await Sorting.ledger(suite: "categories.sort.once", rows: Sorting.tailscale)
    let (author, enqueues) = Self.counted(l)
    let txn = try #require(l.ids["com"]?.first)
    let before = try Self.filings(l)
    let pending = try l.a.context.store.pendingCount()
    let id = l.store.newCategoryID()
    let inverses = try await author.author(
      .addCategoryAndSort(Self.vpn(id), txn, alwaysUse: true, project: nil), before: l.store.state, today: MayaLedger.now.date)
    #expect(enqueues.count == 1)
    let added = try l.a.context.store.pendingOps().dropFirst(pending)
    let filed = try l.ids.values.joined().filter { try l.row($0)?.category == id }
    #expect(filed.count > 1 && filed.contains(txn))
    #expect(
      added.map(\.opType)
        == ["category_defined", "txn_categorized", "rule_added"] + Array(repeating: "txn_categorized", count: filed.count - 1))
    #expect(added.filter { $0.entityID == txn }.count == 1)
    #expect(Set(added.filter { $0.opType == "txn_categorized" }.compactMap(\.entityID)) == Set(filed))
    let rule = try #require(try l.reader.rules().first)
    #expect(rule.category == id)
    let receipt = try #require(l.memory.value.receipt)
    #expect(receipt.txnIDs.first == txn && Set(receipt.txnIDs) == Set(filed) && receipt.ruleID == rule.id)
    #expect(try l.row(txn)?.categorySource == "user")

    try await author.undo(inverses)
    #expect(try Self.filings(l) == before)
    #expect(try l.reader.rules().isEmpty)
    #expect(try l.reader.taxonomy().info(id)?.active == true)
  }

  @Test func aRefusedAlwaysUseWriteEnqueuesNothing() async throws {
    let l = try await Sorting.ledger(suite: "categories.sort.refused.once", rows: Sorting.tailscale)
    let (author, enqueues) = Self.counted(l)
    let suite = "categories.sort.refused.once.store"
    let store = LiveLedgerStore(
      reader: l.reader, author: author, profile: Mapper.context().profile,
      prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: suite)!), clock: { MayaLedger.now })
    await store.reload()
    var failed = false
    store.onWriteFailed = { failed = true }
    let txn = try #require(l.ids["com"]?.first)
    let before = try Self.filings(l)
    let shown = store.state
    #expect(throws: ActionError.refused(CategoryLimits.nameTaken("Subscriptions"))) {
      try store.apply(.addCategoryAndSort(CategoryDraft(name: " subscriptions", parent: "subscriptions"), txn, alwaysUse: true, project: nil))
    }
    #expect(throws: ActionError.refused(CategoryLimits.cannotAdd)) {
      try store.apply(.addCategoryAndSort(CategoryDraft(id: "subscriptions", name: "VPN", parent: "subscriptions"), txn, alwaysUse: true, project: nil))
    }
    #expect(throws: ActionError.notFound) {
      try store.apply(.addCategoryAndSort(Self.vpn(store.newCategoryID()), txn, alwaysUse: true, project: "no-such-project"))
    }
    #expect(store.state == shown)

    let id = store.newCategoryID()
    let synced = try l.a.observer.stamps.build(try await l.a.observer.authorContext()) { o throws(AuthorError) in
      o.defineCategory(
        id: "c_01jc0000000000000000000078", name: "vpn", kind: .spending, bucket: .want, icon: "tag", active: true,
        parent: "subscriptions")
    }
    try await l.a.outbox.enqueue(try #require(synced).ops)
    try await l.a.observer.reproject()
    let pending = try l.a.context.store.pendingCount()
    await #expect(throws: AuthorError.refused(CategoryRefusal.nameTaken("vpn").message)) {
      try await author.author(
        .addCategoryAndSort(Self.vpn(id), txn, alwaysUse: true, project: nil), before: store.state, today: MayaLedger.now.date)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(enqueues.count == 0)
    #expect(try l.a.context.store.pendingCount() == pending)
    #expect(try l.reader.taxonomy().info(id) == nil)
    #expect(try Self.filings(l) == before)
    #expect(try l.reader.rules().isEmpty)
    #expect(l.memory.value.batches.isEmpty && l.memory.value.receipt == nil)
    #expect(!failed)
  }
}
